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

  // ---- JSON (để truyền dữ liệu cuộc gọi sang webview) ----

  static const _kDirection = 'direction';
  static const _kRemoteNumber = 'remoteNumber';
  static const _kState = 'state';
  static const _kStartedAt = 'startedAt';

  /// Enum đọc theo tên (`incoming`, `ringing`...); giá trị lạ hoặc thiếu
  /// thì dùng mặc định. `startedAt` dạng ISO 8601, thiếu thì lấy thời điểm hiện tại.
  factory CallSession.fromJson(Map<String, dynamic> json) {
    return CallSession(
      direction: CallDirection.values.asNameMap()[json[_kDirection]] ??
          CallDirection.outgoing,
      remoteNumber: json[_kRemoteNumber] as String? ?? '',
      state: CallState.values.asNameMap()[json[_kState]] ?? CallState.ringing,
      startedAt: DateTime.tryParse(json[_kStartedAt] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
    _kDirection: direction.name,
    _kRemoteNumber: remoteNumber,
    _kState: state.name,
    _kStartedAt: startedAt.toIso8601String(),
  };

  @override
  String toString() => 'CallSession($direction $remoteNumber, $state)';
}
