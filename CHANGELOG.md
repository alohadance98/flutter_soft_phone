## 0.0.1

* Tách soft phone (baresip FFI) từ app limo_windows thành plugin.
* `baresip-window.dll` và `sndfile.dll` được đóng gói trong `windows/libs/`
  và tự copy cạnh file exe của app qua `flutter_soft_phone_bundled_libraries`.
