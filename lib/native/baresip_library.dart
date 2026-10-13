import 'dart:ffi';
import 'dart:io';

import 'baresip_bindings.dart';

/// Tìm và mở `baresip-window.dll` (kèm `sndfile.dll` mà nó phụ thuộc).
///
/// Hai DLL này nằm trong `windows/libs/` của plugin và được khai báo trong
/// `windows/CMakeLists.txt` (`flutter_soft_phone_bundled_libraries`). Khi
/// build, Flutter copy chúng vào cùng thư mục với file `.exe` của app, nên
/// Windows loader tìm thấy chúng theo tên mà không cần đường dẫn tuyệt đối.
///
/// Dùng `BaresipLibrary.instance` để lấy [DynamicLibrary] đã mở.
/// Mỗi Isolate có bản copy static riêng, nên trong isolate mới DLL sẽ được
/// `open` lại; hệ điều hành trả về cùng một handle nên không tốn thêm gì.
class BaresipLibrary {
  BaresipLibrary._();

  static const String baresipDllName = 'baresip-window.dll';
  static const String sndfileDllName = 'sndfile.dll';

  static DynamicLibrary? _instance;

  /// Thư mục chứa DLL do người dùng chỉ định. Mặc định `null`: tìm cạnh
  /// file `.exe`. Chỉ cần set khi chạy ngoài app Flutter (ví dụ `dart test`),
  /// và phải set trước lần gọi [instance] đầu tiên.
  static String? overrideDirectory;

  static DynamicLibrary get instance => _instance ??= _open();

  /// Thư mục chứa file thực thi đang chạy (nơi Flutter copy các DLL bundled).
  static String get executableDirectory =>
      File(Platform.resolvedExecutable).parent.path;

  static DynamicLibrary _open() {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'flutter_soft_phone hiện chỉ hỗ trợ Windows '
        '(đang chạy trên ${Platform.operatingSystem}).',
      );
    }

    final dir = overrideDirectory;
    if (dir != null) {
      // sndfile phải được load trước vì baresip-window.dll link tới nó, và
      // Windows loader không tự tìm trong thư mục tuỳ ý.
      _openOrThrow('$dir${Platform.pathSeparator}$sndfileDllName');
      return _openOrThrow('$dir${Platform.pathSeparator}$baresipDllName');
    }

    // Mở theo tên: Windows tìm trong thư mục chứa .exe trước tiên, đúng chỗ
    // Flutter copy các bundled libraries. sndfile sẽ được loader tự resolve,
    // nhưng vẫn mở tường minh để báo lỗi rõ ràng nếu thiếu file.
    _openOrThrow(sndfileDllName);
    return _openOrThrow(baresipDllName);
  }

  static DynamicLibrary _openOrThrow(String pathOrName) {
    try {
      return DynamicLibrary.open(pathOrName);
    } on ArgumentError catch (e) {
      throw StateError(
        'Không mở được "$pathOrName". '
        'Thư mục exe: $executableDirectory. '
        'Hãy chắc rằng app đã được build lại sau khi thêm plugin '
        '(flutter clean && flutter build windows) và các DLL runtime '
        'của Visual C++ đã có trên máy. Lỗi gốc: $e',
      );
    }
  }

  /// Entry point cho `Isolate.spawn`: chạy main loop của baresip.
  /// Hàm này block cho tới khi native `stop()` được gọi.
  static void runMainLoop(void _) {
    BaresipBindings(instance).init();
  }
}
