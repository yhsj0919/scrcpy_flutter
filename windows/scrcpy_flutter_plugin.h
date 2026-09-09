#ifndef FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <cstdint>
#include <unordered_map>

namespace scrcpy_flutter {

class NativeVideoTexture;
class NativeAudioPlayer;
class ProcessGpuSampler;

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

  void HandleAudioMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  flutter::TextureRegistrar* texture_registrar_;
  std::unordered_map<int64_t, std::unique_ptr<NativeVideoTexture>> videos_;
  std::unordered_map<int64_t, std::unique_ptr<NativeAudioPlayer>> audios_;
  int64_t next_audio_id_ = 1;
  std::unique_ptr<ProcessGpuSampler> process_gpu_sampler_;
};

}  // namespace scrcpy_flutter

#endif  // FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_
