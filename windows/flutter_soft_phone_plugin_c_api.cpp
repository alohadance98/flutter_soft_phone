#include "include/flutter_soft_phone/flutter_soft_phone_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_soft_phone_plugin.h"

void FlutterSoftPhonePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_soft_phone::FlutterSoftPhonePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
