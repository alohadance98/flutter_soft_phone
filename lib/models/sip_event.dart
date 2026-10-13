import 'dart:typed_data';

import '../native/baresip_bindings.dart';

/// Loại sự kiện DLL gửi lên, map từ mã số trong `NativeMessage.type`.
enum SipEventType {
  /// Bắt đầu đăng ký một UA.
  registering(1),

  /// Đăng ký **hoặc** huỷ đăng ký xong. DLL dùng chung một mã cho cả hai,
  /// phải dựa vào sự kiện [registering] / [unregistering] trước đó để phân biệt.
  /// `data` = hotline (có thể kèm hậu tố).
  registrationChanged(2),

  registerFailed(3),

  /// Bắt đầu huỷ đăng ký một UA.
  unregistering(4),

  /// Có cuộc gọi đến. `data` = `sip:<số gọi đến>@<server>`.
  incomingCall(5),

  /// Cuộc gọi (vào hoặc ra) đã được nối.
  callEstablished(8),

  /// Cuộc gọi kết thúc (bên nào cúp cũng vậy).
  callClosed(9),

  /// DLL đã ghi file ghi âm xong. `data` = đường dẫn file.
  recordingSaved(10),

  unknown(-1);

  const SipEventType(this.code);

  /// Mã số gốc từ native.
  final int code;

  static SipEventType fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return unknown;
  }
}

/// Một sự kiện đã được đọc từ [NativeMessage] và copy sang bộ nhớ Dart.
class SipEvent {
  SipEvent({
    required this.code,
    required this.name,
    required this.data,
  }) : type = SipEventType.fromCode(code);

  factory SipEvent.fromNative(NativeMessage message) {
    return SipEvent(
      code: message.type,
      name: message.nameText,
      data: message.dataBytes,
    );
  }

  final SipEventType type;

  /// Mã số gốc, hữu ích khi `type == unknown`.
  final int code;

  final String name;
  final Uint8List data;

  /// `data` đọc dạng chuỗi.
  String get text => String.fromCharCodes(data);

  /// Với [SipEventType.incomingCall]: tách số gọi đến từ `sip:0916767869@172.28.0.19`.
  /// Trả `null` nếu không đúng định dạng.
  String? get callerNumber {
    final match = RegExp(r'sip:([^@]+)@').firstMatch(text);
    return match?.group(1);
  }

  @override
  String toString() => 'SipEvent($type[$code], name=$name, data=$text)';
}
