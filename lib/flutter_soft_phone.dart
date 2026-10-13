/// Điểm import duy nhất cho soft phone.
///
/// ```dart
/// import 'package:flutter_soft_phone/flutter_soft_phone.dart';
///
/// final phone = SoftPhoneController();
/// await phone.init();
/// phone.addAccount(SipAccount(server: '...', hotline: '...', password: '...'));
/// ```
library;

export 'audio_stream.dart';
export 'models/call_session.dart';
export 'models/sip_account.dart';
export 'models/sip_event.dart';
export 'native/baresip_library.dart' show BaresipLibrary;
export 'sip_engine.dart';
export 'soft_phone_controller.dart';
