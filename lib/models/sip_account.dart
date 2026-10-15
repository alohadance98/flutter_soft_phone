/// Trạng thái đăng ký của một đầu số với SIP server.
enum AccountStatus { offline, online }

/// Một đầu số (hotline) đăng ký lên SIP server.
///
/// `server`, `hotline`, `password` là định danh, không đổi sau khi tạo.
/// `autoConnect` do người dùng chỉnh trong màn cài đặt, `status` do
/// [SoftPhoneController] cập nhật theo sự kiện từ baresip.
class SipAccount {
  SipAccount({
    required this.uid,
    required this.server,
    required this.hotline,
    required this.password,
    this.autoConnect = false,
    this.status = AccountStatus.offline,
  });

  /// UID của account
  final String uid;

  /// Địa chỉ SIP/Register server, ví dụ `172.28.0.203`.
  final String server;

  /// Đầu số dùng để đăng ký và gọi ra.
  final String hotline;

  final String password;

  /// Tự đăng ký khi mở soft phone.
  bool autoConnect;

  AccountStatus status;

  bool get isOnline => status == AccountStatus.online;

  /// Đủ thông tin để đăng ký.
  bool get isComplete =>
      server.isNotEmpty && hotline.isNotEmpty && password.isNotEmpty;

  /// URI truyền cho baresip: `<sip:hotline@server>;auth_pass=password`.
  /// Trả chuỗi rỗng nếu thiếu thông tin.
  String get registrationUri {
    if (!isComplete) return '';
    return '<sip:$hotline@$server>;auth_pass=$password'
        .replaceAll(RegExp(r'[\r\n]+'), '')
        .trim();
  }

  /// Hai account trùng nhau khi cùng server và cùng hotline.
  bool sameIdentity(SipAccount other) =>
      server == other.server && hotline == other.hotline;

  SipAccount copyWith({
    String? uid,
    String? server,
    String? hotline,
    String? password,
    bool? autoConnect,
    AccountStatus? status,
  }) {
    return SipAccount(
      uid: uid ?? this.uid,
      server: server ?? this.server,
      hotline: hotline ?? this.hotline,
      password: password ?? this.password,
      autoConnect: autoConnect ?? this.autoConnect,
      status: status ?? this.status,
    );
  }

  // ---- JSON (để lưu/đọc cấu hình; không lưu status) ----

  static const _kUid = 'uid';
  static const _kServer = 'sipServer';
  static const _kHotline = 'hotline';
  static const _kPassword = 'password';
  static const _kAutoConnect = 'autoConnect';
  static const _kIsOnline = 'isOnline';

  factory SipAccount.fromJson(Map<String, dynamic> json) {
    return SipAccount(
      uid: json[_kUid] as String? ?? '',
      server: json[_kServer] as String? ?? '',
      hotline: json[_kHotline] as String? ?? '',
      password: json[_kPassword] as String? ?? '',
      autoConnect: json[_kAutoConnect] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    _kUid: uid,
    _kServer: server,
    _kHotline: hotline,
    _kPassword: password,
    _kAutoConnect: autoConnect,
    _kIsOnline: status == AccountStatus.online,
  };

  @override
  String toString() => 'SipAccount($hotline@$server, $status)';
}
