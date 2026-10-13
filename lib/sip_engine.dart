import 'dart:async';
import 'dart:developer';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'models/sip_account.dart';
import 'models/sip_event.dart';
import 'native/baresip_bindings.dart';
import 'native/baresip_library.dart';

/// Lớp bọc baresip với API có kiểu, che toàn bộ FFI và isolate.
///
/// - [start] chạy main loop của baresip trong isolate riêng và bắt đầu poll queue sự kiện.
/// - Sự kiện native được phát qua [events] dưới dạng [SipEvent].
/// - Các lệnh ([register], [dial], ...) gọi thẳng vào DLL, không chờ phản hồi;
///   kết quả về qua [events].
class SipEngine {
  SipEngine({BaresipBindings? bindings})
    : _native = bindings ?? BaresipBindings(BaresipLibrary.instance);

  /// Sau khi spawn isolate, baresip cần một lúc để khởi tạo xong trước khi
  /// nhận lệnh. Chưa có cơ chế báo "ready" từ native nên dùng thời gian chờ cố định.
  static const Duration warmUp = Duration(seconds: 2);

  static const Duration _pollInterval = Duration(milliseconds: 100);

  final BaresipBindings _native;
  final StreamController<SipEvent> _events = StreamController.broadcast();

  Isolate? _mainLoop;
  Timer? _poller;

  Stream<SipEvent> get events => _events.stream;

  bool get isRunning => _mainLoop != null;

  /// Khởi động baresip nếu chưa chạy. Chờ [warmUp] nếu vừa mới khởi động.
  Future<void> start() async {
    if (isRunning) return;
    _mainLoop = await Isolate.spawn(BaresipLibrary.runMainLoop, null);
    _poller = Timer.periodic(_pollInterval, (_) => _drainEventQueue());
    await Future<void>.delayed(warmUp);
  }

  /// Dừng baresip và kill isolate. Gọi [start] để chạy lại.
  void stop() {
    _poller?.cancel();
    _poller = null;
    if (_mainLoop == null) return;
    _native.stop();
    _mainLoop!.kill();
    _mainLoop = null;
  }

  void register(SipAccount account) {
    log('[SipEngine] register ${account.hotline}');
    _native.uaNew(_utf8(account.registrationUri));
  }

  void unregister(SipAccount account) {
    log('[SipEngine] unregister ${account.hotline}');
    _native.uaUnregister(_utf8(account.hotline));
  }

  void dial({required String fromHotline, required String toNumber}) {
    log('[SipEngine] dial $fromHotline -> $toNumber');
    _native.dial(_utf8(fromHotline), _utf8(toNumber));
  }

  void answer(String hotline) {
    log('[SipEngine] answer $hotline');
    _native.answer(_utf8(hotline));
  }

  void hangup(String hotline) {
    log('[SipEngine] hangup $hotline');
    _native.hangup(_utf8(hotline));
  }

  void dispose() {
    stop();
    _events.close();
  }

  void _drainEventQueue() {
    // Mỗi tick lấy hết message đang chờ thay vì chỉ một.
    while (true) {
      final ptr = _native.dequeue();
      if (ptr == nullptr) return;
      _events.add(SipEvent.fromNative(ptr.ref));
    }
  }

  /// Chuỗi Dart -> C.
  ///
  /// Cố ý **không free**: DLL chạy trên thread khác và có thể giữ pointer
  /// trong queue lệnh của nó; free ngay ở đây có thể gây use-after-free.
  /// Chỉ vài byte mỗi lệnh (đăng ký / gọi), chấp nhận được. Nếu phía native
  /// xác nhận đã copy chuỗi, đổi sang `malloc.free` sau khi gọi.
  static Pointer<Utf8> _utf8(String value) => value.toNativeUtf8();
}
