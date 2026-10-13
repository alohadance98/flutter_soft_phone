enum CallDirection { incoming, outgoing }

enum CallState {
  /// Đang đổ chuông (gọi đến) hoặc đang chờ bên kia nhấc máy (gọi ra).
  ringing,

  /// Hai bên đã nối, đang nói chuyện.
  active,
}

/// Cuộc gọi đang diễn ra. Khi không có cuộc gọi, controller giữ `null`.
class CallSession {
  CallSession({
    required this.direction,
    required this.remoteNumber,
    this.state = CallState.ringing,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final CallDirection direction;

  /// Số bên kia: số gọi đến hoặc số mình gọi ra.
  final String remoteNumber;

  CallState state;

  /// Thời điểm bắt đầu đổ chuông / bấm gọi.
  final DateTime startedAt;

  bool get isIncoming => direction == CallDirection.incoming;
  bool get isOutgoing => direction == CallDirection.outgoing;
  bool get isRinging => state == CallState.ringing;
  bool get isActive => state == CallState.active;

  @override
  String toString() => 'CallSession($direction $remoteNumber, $state)';
}
