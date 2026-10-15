# flutter_soft_phone

SIP soft phone cho Flutter **Windows**, gọi thẳng vào `baresip-window.dll`
qua `dart:ffi`.

## Cài đặt

```yaml
dependencies:
  flutter_soft_phone:
    git:
      url: https://github.com/<your-org>/flutter_soft_phone.git
```

Sau đó build lại app Windows (`flutter clean && flutter build windows`
hoặc `flutter run -d windows`). Không cần copy DLL hay khai báo assets gì
thêm ở phía app.

## Cách plugin xử lý DLL

Hai thư viện native nằm sẵn trong plugin tại `windows/libs/`:

| File | Vai trò |
| --- | --- |
| `baresip-window.dll` | SIP engine (baresip) |
| `sndfile.dll` | Thư viện ghi âm, được `baresip-window.dll` import |

`windows/CMakeLists.txt` khai báo hai file này trong
`flutter_soft_phone_bundled_libraries`. Khi build, Flutter copy chúng vào
**cùng thư mục với file `.exe`** của app (`build/windows/x64/runner/<Config>/`).
Vì vậy phía Dart chỉ cần `DynamicLibrary.open('baresip-window.dll')`: Windows
loader luôn tìm trong thư mục chứa exe trước, và cũng tự resolve `sndfile.dll`
từ đó.

Nếu chạy ngoài app Flutter (ví dụ `dart test`), set thư mục chứa DLL trước
khi dùng:

```dart
BaresipLibrary.overrideDirectory = r'D:\path\to\flutter_soft_phone\windows\libs';
```

## Sử dụng

```dart
import 'package:flutter_soft_phone/flutter_soft_phone.dart';

final phone = SoftPhoneController();
await phone.init();

final account = SipAccount(uid: 'acc-1', server: '172.28.0.203', hotline: '1001', password: '...');

// Cách 1: gửi lệnh và trả về ngay; trạng thái online về sau qua notifyListeners.
phone.addAccount(account);
await phone.register(account);

// Cách 2: chờ kết quả thật từ server SIP (true = online, false = lỗi/timeout).
final ok = await phone.registerAndWait(account, timeout: const Duration(seconds: 10));

phone.dial('0912345678');
phone.hangup();

// Huỷ đăng ký: unregister() trả về ngay, unregisterAndWait() chờ server xác nhận
// (true = đã offline, false = lỗi/timeout).
final off = await phone.unregisterAndWait(account);

// Sửa account theo uid; nếu đang online sẽ tự huỷ đăng ký và đăng ký lại.
await phone.updateAccount(account.copyWith(password: 'new-password'));
```

`SoftPhoneController` là `ChangeNotifier`, bọc UI bằng `ListenableBuilder`
để nhận cập nhật trạng thái. Xem `example/` để có app mẫu đầy đủ.

## Lưu ý

- `baresip-window.dll` hiện là **bản Debug** (import `VCRUNTIME140D.dll`,
  `ucrtbased.dll`). Các DLL debug này chỉ có trên máy đã cài Visual Studio,
  nên app sẽ không chạy trên máy người dùng cuối cho tới khi build lại baresip
  ở cấu hình Release.
- Plugin chỉ hỗ trợ Windows x64.
