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

  /// Các lời gọi [registerAndWait] đang chờ kết quả từ baresip.
  final Map<SipAccount, Completer<bool>> _pendingRegistrations = {};

  /// Các lời gọi [unregisterAndWait] đang chờ kết quả từ baresip.
  final Map<SipAccount, Completer<bool>> _pendingUnregistrations = {};

  /// DLL dùng chung một mã cho "đăng ký xong" và "huỷ đăng ký xong",
  /// nên phải nhớ hành động đang diễn ra để biết sự kiện tiếp theo nghĩa là gì.
  bool _isUnregistering = false;

  SipAccount? _activeAccount;
  CallSession? _currentCall;
  String _message = '';

  /// Lần cuối đã báo qua [onCallChanged], để không báo trùng
  /// (ví dụ [hangup] rồi DLL lại gửi sự kiện callClosed).
  CallSession? _notifiedCall;
  CallState? _notifiedCallState;

  // ---- Callback cho app chủ (tuỳ chọn) ----

  /// Gọi khi trạng thái online tổng thể thay đổi.
  ValueChanged<bool>? onConnectionChanged;

  /// `true` khi có cuộc gọi đến, `false` khi cuộc gọi kết thúc.
  ValueChanged<bool>? onIncomingCall;

  /// Gọi mỗi khi cuộc gọi hiện tại thay đổi: bắt đầu (gọi ra / gọi đến,
  /// đang đổ chuông), đã nối ([CallState.active]), hoặc kết thúc (`null`).
  ValueChanged<CallSession?>? onCallChanged;

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
    _failAllPendingRegistrations();
    // Mọi đầu số đã về offline nên coi như huỷ đăng ký xong.
    _completeAllPendingUnregistrations(true);
    notifyListeners();
    onConnectionChanged?.call(false);
    _notifyCallChanged();
  }

  @override
  void dispose() {
    _failAllPendingRegistrations();
    _completeAllPendingUnregistrations(false);
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
    _completePendingRegistration(account, false);
    _completePendingUnregistration(account, false);
    _accounts.remove(account);
    if (_activeAccount == account) _activeAccount = null;
    notifyListeners();
  }

  /// Cập nhật account có cùng [SipAccount.uid] với [updated].
  ///
  /// - Chỉ đổi `autoConnect`: sửa trực tiếp trên account hiện có, giữ nguyên
  ///   trạng thái online.
  /// - Đổi server / hotline / password: thay account cũ bằng [updated] tại
  ///   cùng vị trí. Nếu account cũ đang online thì huỷ đăng ký (chờ tối đa
  ///   [timeout]) rồi đăng ký lại bằng thông tin mới.
  ///
  /// Trả `false` khi uid rỗng / không tìm thấy, server + hotline mới trùng với
  /// một account khác, hoặc huỷ đăng ký account cũ thất bại (account cũ được
  /// giữ nguyên). Trả `true` khi đã cập nhật; kết quả đăng ký lại về sau qua
  /// [notifyListeners] / [onConnectionChanged] như [register].
  Future<bool> updateAccount(
    SipAccount updated, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (updated.uid.isEmpty) return false;
    final old = _accounts.where((a) => a.uid == updated.uid).firstOrNull;
    if (old == null) return false;
    if (_accounts.any((a) => a.uid != updated.uid && a.sameIdentity(updated))) {
      return false;
    }

    final credentialsChanged =
        old.server != updated.server ||
        old.hotline != updated.hotline ||
        old.password != updated.password;
    if (!credentialsChanged) {
      setAutoConnect(old, updated.autoConnect);
      return true;
    }

    final wasOnline = old.isOnline;
    if (wasOnline && !await unregisterAndWait(old, timeout: timeout)) {
      return false;
    }

    // Account cũ có thể đã bị xoá trong lúc chờ huỷ đăng ký.
    final index = _accounts.indexOf(old);
    if (index < 0) return false;
    _completePendingRegistration(old, false);
    final replacement = updated.copyWith(status: AccountStatus.offline);
    _accounts[index] = replacement;
    if (_activeAccount == old) _activeAccount = null;
    notifyListeners();

    if (wasOnline) await register(replacement);
    return true;
  }

  void setAutoConnect(SipAccount account, bool value) {
    account.autoConnect = value;
    notifyListeners();
  }

  /// Gửi lệnh đăng ký và trả về ngay, **không chờ** server SIP phản hồi.
  /// Trạng thái [SipAccount.isOnline] chỉ đổi khi baresip báo sự kiện về
  /// (vài trăm ms sau); theo dõi qua [addListener] / [onConnectionChanged],
  /// hoặc dùng [registerAndWait] nếu cần biết kết quả.
  Future<void> register(SipAccount account) async {
    if (account.isOnline || !account.isComplete) return;
    await engine.start(); // không làm gì nếu đã chạy
    engine.register(account);
  }

  /// Đăng ký [account] và chờ tới khi baresip báo kết quả.
  ///
  /// Trả `true` khi đăng ký thành công (account chuyển sang online), `false`
  /// khi server từ chối, thiếu thông tin, account bị xoá / controller bị
  /// [shutdown] trong lúc chờ, hoặc quá [timeout] mà chưa có phản hồi.
  /// [timeout] được tính từ sau khi lệnh đăng ký đã gửi (không bao gồm
  /// thời gian khởi động baresip).
  ///
  /// Nếu [account] chưa có trong [accounts] thì sẽ được thêm vào. Nếu đã có
  /// một account cùng server + hotline, kết quả áp dụng cho account đó.
  Future<bool> registerAndWait(
    SipAccount account, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final target = _accounts.where((a) => a.sameIdentity(account)).firstOrNull;
    if (target == null) {
      _accounts.add(account);
      notifyListeners();
    }
    final tracked = target ?? account;

    if (tracked.isOnline) return true;
    if (!tracked.isComplete) return false;

    // Đang có lời gọi khác chờ cùng account: dùng chung kết quả.
    final pending = _pendingRegistrations[tracked];
    if (pending != null) return pending.future;

    final completer = Completer<bool>();
    _pendingRegistrations[tracked] = completer;
    await register(tracked);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        log('[SoftPhone] register ${tracked.hotline} timed out');
        _pendingRegistrations.remove(tracked);
        return false;
      },
    );
  }

  void _completePendingRegistration(SipAccount account, bool result) {
    final completer = _pendingRegistrations.remove(account);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  void _failAllPendingRegistrations() {
    for (final account in _pendingRegistrations.keys.toList()) {
      _completePendingRegistration(account, false);
    }
  }

  void unregister(SipAccount account) {
    if (!account.isOnline) return;
    engine.unregister(account);
  }

  /// Huỷ đăng ký [account] và chờ tới khi baresip báo kết quả.
  ///
  /// Trả `true` khi huỷ đăng ký xong (account chuyển sang offline) hoặc
  /// account vốn đã offline / không có trong [accounts]. Trả `false` khi
  /// baresip báo lỗi, account bị xoá / controller bị dispose trong lúc chờ,
  /// hoặc quá [timeout] mà chưa có phản hồi.
  ///
  /// Account được tìm theo server + hotline nên có thể truyền một bản copy.
  Future<bool> unregisterAndWait(
    SipAccount account, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final tracked = _accounts.where((a) => a.sameIdentity(account)).firstOrNull;
    if (tracked == null || !tracked.isOnline) return Future.value(true);

    // Đang có lời gọi khác chờ cùng account: dùng chung kết quả.
    final pending = _pendingUnregistrations[tracked];
    if (pending != null) return pending.future;

    final completer = Completer<bool>();
    _pendingUnregistrations[tracked] = completer;
    unregister(tracked);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        log('[SoftPhone] unregister ${tracked.hotline} timed out');
        // Complete luôn completer để các lời gọi dùng chung cũng nhận `false`.
        _completePendingUnregistration(tracked, false);
        return false;
      },
    );
  }

  void _completePendingUnregistration(SipAccount account, bool result) {
    final completer = _pendingUnregistrations.remove(account);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  void _completeAllPendingUnregistrations(bool result) {
    for (final account in _pendingUnregistrations.keys.toList()) {
      _completePendingUnregistration(account, result);
    }
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
    // Không dùng _setMessage('') vì nó bỏ qua notify khi message vốn đã rỗng.
    _message = '';
    notifyListeners();
    _notifyCallChanged();
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
    _notifyCallChanged();
  }

  /// Cúp máy / từ chối cuộc gọi hiện tại.
  void hangup() {
    final account = _activeAccount;
    if (_currentCall == null || account == null) return;
    engine.hangup(account.hotline);
    _endCall();
  }

  String? _validateDial(String number) {
    if (number.isEmpty) return 'Số điện thoại không được để trống.';
    if (number.length < 10) return 'Số điện thoại không hợp lệ.';
    if (_activeAccount == null) return 'Bạn phải đăng ký hot line.';
    if (hasCall) return 'Đang có cuộc gọi khác!';
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
        _onRegisterFailed(event);
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
      _completePendingRegistration(account, false);
      _completePendingUnregistration(account, true);
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
      _completePendingRegistration(account, true);
      onConnectionChanged?.call(true);
    }
    notifyListeners();
  }

  void _onRegisterFailed(SipEvent event) {
    log('[SoftPhone] register failed: $event');
    _isUnregistering = false;
    // Lỗi khi huỷ đăng ký: chỉ báo cho unregisterAndWait nếu nhận ra account.
    final unregistering = _pendingUnregistrations.keys
        .where((a) => event.text.contains(a.hotline))
        .firstOrNull;
    if (unregistering != null) {
      _completePendingUnregistration(unregistering, false);
      return;
    }
    // Nếu nhận ra account trong nội dung sự kiện thì chỉ báo lỗi account đó,
    // không thì coi mọi lời gọi registerAndWait đang chờ đều thất bại.
    final account = _pendingRegistrations.keys
        .where((a) => event.text.contains(a.hotline))
        .firstOrNull;
    if (account != null) {
      _completePendingRegistration(account, false);
    } else {
      _failAllPendingRegistrations();
    }
  }

  void _onIncomingCall(SipEvent event) {
    audioIn.start();
    _currentCall = CallSession(
      direction: CallDirection.incoming,
      remoteNumber: event.callerNumber ?? event.text,
    );
    notifyListeners();
    onIncomingCall?.call(true);
    _notifyCallChanged();
  }

  void _onCallEstablished() {
    audioIn.start();
    _currentCall?.state = CallState.active;
    notifyListeners();
    _notifyCallChanged();
  }

  void _endCall() {
    audioIn.stop();
    _currentCall = null;
    _message = '';
    notifyListeners();
    onConnectionChanged?.call(isOnline);
    onIncomingCall?.call(false);
    _notifyCallChanged();
  }

  /// Báo [onCallChanged] nếu cuộc gọi hoặc trạng thái của nó khác lần báo trước.
  void _notifyCallChanged() {
    final call = _currentCall;
    if (identical(call, _notifiedCall) && call?.state == _notifiedCallState) {
      return;
    }
    _notifiedCall = call;
    _notifiedCallState = call?.state;
    onCallChanged?.call(call);
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
