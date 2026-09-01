#ifndef FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <cstdint>
#include <unordered_map>

namespace scrcpy_flutter {

class NativeVideoTexture;

class ScrcpyFlutterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit ScrcpyFlutterPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~ScrcpyFlutterPlugin();

  // Disallow copy and assign.
  ScrcpyFlutterPlugin(const ScrcpyFlutterPlugin&) = delete;
  ScrcpyFlutterPlugin& operator=(const ScrcpyFlutterPlugin&) = delete;

  void HandleVideoMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  flutter::TextureRegistrar* texture_registrar_;
  std::unordered_map<int64_t, std::unique_ptr<NativeVideoTexture>> videos_;
};

}  // namespace scrcpy_flutter

#endif  // FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_
