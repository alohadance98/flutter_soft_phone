import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Kích thước mảng trong [NativeMessage]. Struct FFI không được chứa hằng số,
// nên đặt ở ngoài; phải trùng với giá trị trong annotation `@Array`.
const int _kMessageNameCapacity = 128;
const int _kMessageDataCapacity = 1024;

/// Message mà DLL đẩy vào queue, lấy ra bằng [BaresipBindings.dequeue].
///
/// Layout phải khớp 100% với struct bên C, không đổi thứ tự / kích thước.
final class NativeMessage extends Struct {
  @Int32()
  external int type;

  @Int32()
  external int dataLength;

  @Int32()
  external int nameLength;

  @Array(_kMessageNameCapacity)
  external Array<Uint8> name;

  @Array(_kMessageDataCapacity)
  external Array<Uint8> data;

  /// `name` dạng chuỗi C (dừng ở byte 0 đầu tiên).
  String get nameText {
    final length = nameLength.clamp(0, _kMessageNameCapacity);
    final bytes = <int>[];
    for (var i = 0; i < length; i++) {
      final byte = name[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return String.fromCharCodes(bytes);
  }

  /// Copy toàn bộ `data` sang bộ nhớ Dart (an toàn khi native ghi đè sau đó).
  Uint8List get dataBytes {
    final length = dataLength.clamp(0, _kMessageDataCapacity);
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = data[i];
    }
    return bytes;
  }
}

// Chữ ký phía C (chỉ dùng cho lookupFunction).
typedef _VoidC = Void Function();
typedef _StrC = Void Function(Pointer<Utf8>);
typedef _Str2C = Void Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _RingC = Void Function(Pointer<Void>);
typedef _PushC = Void Function(Pointer<Void>, Pointer<Void>);

// Chữ ký phía Dart (kiểu của các field bên dưới).
typedef NativeVoidFn = void Function();
typedef NativeStringFn = void Function(Pointer<Utf8>);
typedef NativeString2Fn = void Function(Pointer<Utf8>, Pointer<Utf8>);
typedef NativeRingFn = void Function(Pointer<Void>);
typedef NativeGetPtrFn = Pointer<Void> Function();
typedef NativeDequeueFn = Pointer<NativeMessage> Function();
typedef NativePeekFn = Pointer<Uint8> Function(Pointer<Void>);
typedef NativePushFn = void Function(Pointer<Void>, Pointer<Void>);

/// Tất cả hàm export của `baresip-window.dll`, lookup một lần duy nhất.
///
/// Đây là lớp thấp nhất: chỉ map 1-1 với C, không có logic.
/// Code nghiệp vụ dùng [SipEngine] / [AudioRxStream] / [AudioTxStream] thay vì gọi trực tiếp.
class BaresipBindings {
  BaresipBindings(DynamicLibrary lib)
    : init = lib.lookupFunction<_VoidC, NativeVoidFn>('libBaresip_init'),
      stop = lib.lookupFunction<_VoidC, NativeVoidFn>('stop'),
      dequeue = lib.lookupFunction<NativeDequeueFn, NativeDequeueFn>('dequeue'),
      uaNew = lib.lookupFunction<_StrC, NativeStringFn>('ua_new'),
      uaUnregister = lib.lookupFunction<_StrC, NativeStringFn>('ua_unRegister'),
      dial = lib.lookupFunction<_Str2C, NativeString2Fn>('dial'),
      answer = lib.lookupFunction<_StrC, NativeStringFn>('answer'),
      hangup = lib.lookupFunction<_StrC, NativeStringFn>('hangup'),
      rxRingBuffer = lib.lookupFunction<NativeGetPtrFn, NativeGetPtrFn>(
        'get_rx_ring_buffer_ptr',
      ),
      rxPeek = lib.lookupFunction<NativePeekFn, NativePeekFn>('rx_arb_peek'),
      rxConsume = lib.lookupFunction<_RingC, NativeRingFn>('rx_arb_consume'),
      rxReset = lib.lookupFunction<_RingC, NativeRingFn>('rx_arb_reset'),
      txRingBuffer = lib.lookupFunction<NativeGetPtrFn, NativeGetPtrFn>(
        'get_tx_ring_buffer_ptr',
      ),
      txPush = lib.lookupFunction<_PushC, NativePushFn>(
        'push_tx_ring_buffer_ptr',
      ),
      txReset = lib.lookupFunction<_RingC, NativeRingFn>('tx_arb_reset');

  // ---- Vòng đời baresip ----

  /// Chạy main loop của baresip. **Block thread** cho tới khi [stop] được gọi,
  /// nên phải chạy trong Isolate riêng (xem [BaresipLibrary.runMainLoop]).
  final NativeVoidFn init;
  final NativeVoidFn stop;

  /// Lấy message kế tiếp từ queue sự kiện, trả `nullptr` nếu rỗng.
  final NativeDequeueFn dequeue;

  // ---- User agent / cuộc gọi ----

  /// Tạo và đăng ký UA từ URI `<sip:user@server>;auth_pass=...`.
  final NativeStringFn uaNew;

  /// Huỷ đăng ký UA theo hotline.
  final NativeStringFn uaUnregister;

  /// `dial(hotline, số đích)`.
  final NativeString2Fn dial;
  final NativeStringFn answer;
  final NativeStringFn hangup;

  // ---- Ring buffer âm thanh nhận (RX: từ cuộc gọi về Dart) ----

  final NativeGetPtrFn rxRingBuffer;
  final NativePeekFn rxPeek;
  final NativeRingFn rxConsume;
  final NativeRingFn rxReset;

  // ---- Ring buffer âm thanh gửi (TX: từ Dart ra cuộc gọi) ----

  final NativeGetPtrFn txRingBuffer;
  final NativePushFn txPush;
  final NativeRingFn txReset;
}
