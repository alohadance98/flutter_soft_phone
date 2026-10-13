import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'audio_stream.dart';
import 'models/call_session.dart';
import 'models/sip_account.dart';
import 'models/sip_event.dart';
import 'native/baresip_bindings.dart';
import 'native/baresip_library.dart';
import 'sip_engine.dart';

/// Toàn bộ logic nghiệp vụ của soft phone: danh sách đầu số, đăng ký,
/// gọi ra / nhận cuộc gọi, xử lý sự kiện từ baresip.
///
/// UI chỉ cần `ListenableBuilder(listenable: controller, ...)` và gọi các
/// method public. Mọi thay đổi trạng thái đều đi qua [notifyListeners].
class SoftPhoneController extends ChangeNotifier {
  SoftPhoneController({
    BaresipBindings? bindings,
    Iterable<SipAccount> accounts = const [],
  }) : _accounts = List.of(accounts) {
    final native = bindings ?? BaresipBindings(BaresipLibrary.instance);
    engine = SipEngine(bindings: native);
    audioIn = AudioRxStream(native);
    audioOut = AudioTxStream(native);
    _eventSubscription = engine.events.listen(_handleEvent);
  }

  static const String _recordingsDir = 'recordings';

  late final SipEngine engine;

  /// Âm thanh từ cuộc gọi về (chỉ chạy khi có cuộc gọi).
  late final AudioRxStream audioIn;

  /// Âm thanh từ Dart ra cuộc gọi.
  late final AudioTxStream audioOut;

  late final StreamSubscription<SipEvent> _eventSubscription;

  final List<SipAccount> _accounts;

  /// DLL dùng chung một mã cho "đăng ký xong" và "huỷ đăng ký xong",
  /// nên phải nhớ hành động đang diễn ra để biết sự kiện tiếp theo nghĩa là gì.
  bool _isUnregistering = false;

  SipAccount? _activeAccount;
  CallSession? _currentCall;
  String _message = '';

  // ---- Callback cho app chủ (tuỳ chọn) ----

  /// Gọi khi trạng thái online tổng thể thay đổi.
  ValueChanged<bool>? onConnectionChanged;

  /// `true` khi có cuộc gọi đến, `false` khi cuộc gọi kết thúc.
  ValueChanged<bool>? onIncomingCall;

  // ---- Trạng thái (chỉ đọc từ ngoài) ----

  List<SipAccount> get accounts => List.unmodifiable(_accounts);

  List<SipAccount> get onlineAccounts =>
      _accounts.where((a) => a.isOnline).toList();

  bool get isOnline => _accounts.any((a) => a.isOnline);

  /// Đầu số đang chọn để gọi ra / trả lời. `null` khi chưa có đầu số nào online.
  SipAccount? get activeAccount => _activeAccount;

  set activeAccount(SipAccount? account) {
    if (_activeAccount == account) return;
    _activeAccount = account;
    notifyListeners();
  }

  /// Cuộc gọi đang diễn ra, `null` khi rảnh.
  CallSession? get currentCall => _currentCall;

  bool get hasCall => _currentCall != null;

  /// Thông báo cho người dùng (lỗi nhập số, tên người gọi...). Rỗng = không có gì.
  String get message => _message;

  // ---- Vòng đời ----

  /// Khởi động baresip và tự đăng ký các đầu số có [SipAccount.autoConnect].
  Future<void> init() async {
    await Directory(_recordingsDir).create(recursive: true);
    await engine.start();
    for (final account in _accounts.where((a) => a.autoConnect)) {
      await register(account);
    }
  }

  /// Dừng hẳn baresip, đưa mọi đầu số về offline.
  void shutdown() {
    audioIn.stop();
    engine.stop();
    for (final account in _accounts) {
      account.status = AccountStatus.offline;
    }
    _activeAccount = null;
    _currentCall = null;
    _isUnregistering = false;
    notifyListeners();
    onConnectionChanged?.call(false);
  }

  @override
  void dispose() {
    _eventSubscription.cancel();
    audioIn.dispose();
    engine.dispose();
    super.dispose();
  }

  // ---- Quản lý đầu số ----

  /// Thêm đầu số. Trả `false` nếu đã tồn tại (cùng server + hotline).
  bool addAccount(SipAccount account) {
    if (_accounts.any((a) => a.sameIdentity(account))) return false;
    _accounts.add(account);
    notifyListeners();
    return true;
  }

  void removeAccount(SipAccount account) {
    if (account.isOnline) unregister(account);
    _accounts.remove(account);
    if (_activeAccount == account) _activeAccount = null;
    notifyListeners();
  }

  void setAutoConnect(SipAccount account, bool value) {
    account.autoConnect = value;
    notifyListeners();
  }

  Future<void> register(SipAccount account) async {
    if (account.isOnline || !account.isComplete) return;
    await engine.start(); // không làm gì nếu đã chạy
    engine.register(account);
  }

  void unregister(SipAccount account) {
    if (!account.isOnline) return;
    engine.unregister(account);
  }

  void unregisterAll() {
    for (final account in onlineAccounts) {
      unregister(account);
    }
  }

  // ---- Cuộc gọi ----

  /// Gọi ra [number] bằng [activeAccount]. Trả `false` và set [message] nếu không hợp lệ.
  bool dial(String number) {
    final error = _validateDial(number);
    if (error != null) {
      _setMessage(error);
      return false;
    }
    engine.dial(fromHotline: _activeAccount!.hotline, toNumber: number);
    _currentCall = CallSession(
      direction: CallDirection.outgoing,
      remoteNumber: number,
    );
    _setMessage('');
    return true;
  }

  /// Trả lời cuộc gọi đến đang đổ chuông.
  void answer() {
    final call = _currentCall;
    final account = _activeAccount;
    if (call == null ||
        account == null ||
        !call.isIncoming ||
        !call.isRinging) {
      return;
    }
    engine.answer(account.hotline);
    call.state = CallState.active;
    notifyListeners();
  }

  /// Cúp máy / từ chối cuộc gọi hiện tại.
  void hangup() {
    final account = _activeAccount;
    if (_currentCall == null || account == null) return;
    engine.hangup(account.hotline);
    _endCall();
  }

  String? _validateDial(String number) {
    if (number.isEmpty) return 'Số điện thoại không được để trống !!!';
    if (number.length < 10) return 'Số điện thoại không đúng !!!';
    if (_activeAccount == null) return 'Bạn phải đăng ký hot line !!!';
    if (hasCall) return 'Đang có cuộc gọi khác !!!';
    return null;
  }

  // ---- Sự kiện từ baresip ----

  void _handleEvent(SipEvent event) {
    switch (event.type) {
      case SipEventType.registering:
        _isUnregistering = false;
      case SipEventType.unregistering:
        _isUnregistering = true;
      case SipEventType.registrationChanged:
        _onRegistrationChanged(event);
      case SipEventType.registerFailed:
        log('[SoftPhone] register failed: $event');
      case SipEventType.incomingCall:
        _onIncomingCall(event);
      case SipEventType.callEstablished:
        _onCallEstablished();
      case SipEventType.callClosed:
        _endCall();
      case SipEventType.recordingSaved:
        _onRecordingSaved(event.text);
      case SipEventType.unknown:
        log('[SoftPhone] unknown event: $event');
    }
  }

  void _onRegistrationChanged(SipEvent event) {
    final account = _accounts
        .where((a) => event.text.startsWith(a.hotline))
        .firstOrNull;
    final wasUnregistering = _isUnregistering;
    _isUnregistering = false;
    if (account == null) return;

    if (wasUnregistering) {
      account.status = AccountStatus.offline;
      if (_activeAccount == account) _activeAccount = null;
      // Không còn đầu số nào online thì tắt hẳn baresip để tiết kiệm tài nguyên.
      if (!isOnline) {
        engine.stop();
        onConnectionChanged?.call(false);
      }
    } else {
      if (account.isOnline) return; // DLL có thể báo trùng
      account.status = AccountStatus.online;
      _activeAccount ??= account;
      onConnectionChanged?.call(true);
    }
    notifyListeners();
  }

  void _onIncomingCall(SipEvent event) {
    audioIn.start();
    _currentCall = CallSession(
      direction: CallDirection.incoming,
      remoteNumber: event.callerNumber ?? event.text,
    );
    notifyListeners();
    onIncomingCall?.call(true);
  }

  void _onCallEstablished() {
    audioIn.start();
    _currentCall?.state = CallState.active;
    notifyListeners();
  }

  void _endCall() {
    audioIn.stop();
    _currentCall = null;
    _message = '';
    notifyListeners();
    onConnectionChanged?.call(isOnline);
    onIncomingCall?.call(false);
  }

  /// Hiện tại không giữ file ghi âm: xoá ngay sau khi DLL lưu xong.
  /// Bỏ hàm này (hoặc thêm callback) nếu muốn lưu lại lịch sử ghi âm.
  void _onRecordingSaved(String path) {
    try {
      log("record: $path");
      // File(path).deleteSync();
    } catch (e) {
      log('[SoftPhone] cannot delete recording $path: $e');
    }
  }

  void _setMessage(String value) {
    if (_message == value) return;
    _message = value;
    notifyListeners();
  }
}
