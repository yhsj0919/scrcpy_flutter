#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "scrcpy_flutter_plugin.h"

#include <windows.h>
#include <codecapi.h>
#include <icodecapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace scrcpy_flutter {
namespace {
using Microsoft::WRL::ComPtr;

void Check(HRESULT hr, const char* operation) {
  if (SUCCEEDED(hr)) return;
  std::ostringstream message;
  message << operation << " failed (0x" << std::hex
          << static_cast<unsigned long>(hr) << ')';
  throw std::runtime_error(message.str());
}

const flutter::EncodableMap& Args(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!map) throw std::invalid_argument("Expected map arguments");
  return *map;
}

const flutter::EncodableValue& Get(const flutter::EncodableMap& map,
                                   const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) throw std::invalid_argument(std::string("Missing ") + key);
  return it->second;
}

int64_t GetInt(const flutter::EncodableMap& map, const char* key) {
  const auto& value = Get(map, key);
  if (const auto* v = std::get_if<int64_t>(&value)) return *v;
  if (const auto* v = std::get_if<int32_t>(&value)) return *v;
  throw std::invalid_argument(std::string("Invalid integer ") + key);
}

bool GetBool(const flutter::EncodableMap& map, const char* key) {
  const auto* value = std::get_if<bool>(&Get(map, key));
  if (!value) throw std::invalid_argument(std::string("Invalid bool ") + key);
  return *value;
}
}  // namespace

class NativeVideoTexture {
 public:
  NativeVideoTexture(flutter::TextureRegistrar* registrar, uint32_t width,
                     uint32_t height)
      : registrar_(registrar), width_(width), height_(height),
        pixels_(static_cast<size_t>(width) * height * 4),
        texture_(flutter::PixelBufferTexture([this](size_t, size_t) {
          std::lock_guard<std::mutex> lock(mutex_);
          pixel_buffer_.buffer = pixels_.data();
          pixel_buffer_.width = width_;
          pixel_buffer_.height = height_;
          return &pixel_buffer_;
        })) {
    Check(MFStartup(MF_VERSION, MFSTARTUP_LITE), "MFStartup");
    try {
      Configure();
      texture_id_ = registrar_->RegisterTexture(&texture_);
      if (texture_id_ < 0) throw std::runtime_error("Texture registration failed");
      conversion_thread_ = std::thread([this] { RunConversionLoop(); });
    } catch (...) {
      MFShutdown();
      throw;
    }
  }

  ~NativeVideoTexture() {
    if (decoder_) decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    StopConversion();
    MFShutdown();
  }

  void StopConversion() {
    {
      std::lock_guard<std::mutex> lock(conversion_mutex_);
      conversion_stopping_ = true;
    }
    conversion_ready_.notify_one();
    if (conversion_thread_.joinable()) conversion_thread_.join();
  }

  int64_t id() const { return texture_id_; }
  int64_t frame_count() const { return frame_count_; }
  int64_t input_count() const { return input_count_; }
  int64_t need_more_count() const { return need_more_count_; }

  void Decode(const std::vector<uint8_t>& bytes, int64_t pts_us,
              bool config, bool key_frame) {
    if (bytes.empty()) return;
    if (config) {
      ConfigureInput(&bytes);
      return;
    }
    if (!configured_) throw std::runtime_error("H264 sequence header missing");
    ComPtr<IMFMediaBuffer> buffer;
    Check(MFCreateMemoryBuffer(static_cast<DWORD>(bytes.size()), &buffer),
          "Create input buffer");
    BYTE* destination = nullptr;
    Check(buffer->Lock(&destination, nullptr, nullptr), "Lock input buffer");
    std::copy(bytes.begin(), bytes.end(), destination);
    buffer->Unlock();
    Check(buffer->SetCurrentLength(static_cast<DWORD>(bytes.size())),
          "Set input length");
    ComPtr<IMFSample> sample;
    Check(MFCreateSample(&sample), "Create input sample");
    Check(sample->AddBuffer(buffer.Get()), "Add input buffer");
    Check(sample->SetSampleTime(pts_us * 10), "Set sample time");
    sample->SetSampleDuration(166667);
    if (first_input_) {
      Check(sample->SetUINT32(MFSampleExtension_Discontinuity, TRUE),
            "Set first sample discontinuity");
      first_input_ = false;
    }
    if (key_frame) sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);
    if (config) sample->SetUINT32(MFSampleExtension_Discontinuity, TRUE);

    HRESULT hr = decoder_->ProcessInput(0, sample.Get(), 0);
    if (hr == MF_E_NOTACCEPTING) {
      Drain();
      hr = decoder_->ProcessInput(0, sample.Get(), 0);
    }
    Check(hr, "H264 ProcessInput");
    ++input_count_;
    Drain();
  }

 private:
  void Configure() {
    // Each scrcpy packet is one Annex-B access unit. MFVideoFormat_H264 tells
    // the decoder that sample boundaries are frame boundaries; the sequence
    // header below still contains Annex-B SPS/PPS.
    MFT_REGISTER_TYPE_INFO input_filter = {MFMediaType_Video,
                                           MFVideoFormat_H264};
    MFT_REGISTER_TYPE_INFO output_filter = {MFMediaType_Video,
                                            MFVideoFormat_NV12};
    IMFActivate** activates = nullptr;
    UINT32 activate_count = 0;
    Check(MFTEnumEx(
              MFT_CATEGORY_VIDEO_DECODER,
              MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
                  MFT_ENUM_FLAG_SORTANDFILTER,
              &input_filter, &output_filter, &activates, &activate_count),
          "Enumerate Windows H264 decoders");
    if (activate_count == 0) {
      CoTaskMemFree(activates);
      throw std::runtime_error("Windows has no H264 Media Foundation decoder");
    }
    HRESULT activate_result =
        activates[0]->ActivateObject(IID_PPV_ARGS(&decoder_));
    for (UINT32 index = 0; index < activate_count; ++index) {
      activates[index]->Release();
    }
    CoTaskMemFree(activates);
    Check(activate_result, "Activate Windows H264 decoder");
    ComPtr<IMFAttributes> decoder_attributes;
    if (SUCCEEDED(decoder_->GetAttributes(&decoder_attributes))) {
      decoder_attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
    }
    ComPtr<ICodecAPI> codec_api;
    if (SUCCEEDED(decoder_.As(&codec_api))) {
      VARIANT value;
      VariantInit(&value);
      value.vt = VT_BOOL;
      value.boolVal = VARIANT_TRUE;
      codec_api->SetValue(&CODECAPI_AVLowLatencyMode, &value);
      VariantClear(&value);
    }
  }

  void ConfigureInput(const std::vector<uint8_t>* sequence_header) {
    if (!sequence_header) return;
    if (configured_) {
      decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    }
    ComPtr<IMFMediaType> input;
    Check(MFCreateMediaType(&input), "Create input type");
    Check(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), "Input major type");
    Check(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264), "Input subtype");
    Check(MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width_, height_),
          "Input frame size");
    input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    Check(input->SetBlob(MF_MT_MPEG_SEQUENCE_HEADER,
                         sequence_header->data(),
                         static_cast<UINT32>(sequence_header->size())),
          "Set H264 sequence header");
    Check(decoder_->SetInputType(0, input.Get(), 0), "Set H264 input type");
    ConfigureOutput();
    if (!configured_) {
      Check(decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0),
            "Begin streaming");
      configured_ = true;
    }
      Check(decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0),
            "Restart stream");
  }

  void ConfigureOutput() {
    for (DWORD index = 0;; ++index) {
      ComPtr<IMFMediaType> type;
      HRESULT hr = decoder_->GetOutputAvailableType(0, index, &type);
      if (hr == MF_E_NO_MORE_TYPES) break;
      Check(hr, "Get output type");
      GUID subtype = {};
      if (SUCCEEDED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) &&
          subtype == MFVideoFormat_NV12 &&
          SUCCEEDED(decoder_->SetOutputType(0, type.Get(), 0))) {
        UINT32 storage_width = 0;
        UINT32 storage_height = 0;
        if (SUCCEEDED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE,
                                         &storage_width, &storage_height)) &&
            storage_width >= width_ && storage_height >= height_) {
          storage_height_ = storage_height;
        }
        UINT32 raw_stride = 0;
        if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &raw_stride))) {
          output_stride_ = static_cast<LONG>(raw_stride);
        } else {
          LONG calculated_stride = 0;
          if (SUCCEEDED(MFGetStrideForBitmapInfoHeader(
                  MFVideoFormat_NV12.Data1, width_, &calculated_stride))) {
            output_stride_ = calculated_stride;
          }
        }
        return;
      }
    }
    throw std::runtime_error("Windows H264 decoder has no NV12 output");
  }

  void Drain() {
    for (int output_count = 0; output_count < 8; ++output_count) {
      MFT_OUTPUT_STREAM_INFO info = {};
      Check(decoder_->GetOutputStreamInfo(0, &info), "Get output stream info");
      ComPtr<IMFSample> sample;
      if ((info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
        ComPtr<IMFMediaBuffer> buffer;
        Check(MFCreateSample(&sample), "Create output sample");
        DWORD size = (std::max<DWORD>)(
            info.cbSize, width_ * storage_height_ * 3 / 2);
        Check(MFCreateMemoryBuffer(size, &buffer), "Create output buffer");
        Check(sample->AddBuffer(buffer.Get()), "Add output buffer");
      }
      MFT_OUTPUT_DATA_BUFFER output = {};
      output.pSample = sample.Get();
      DWORD status = 0;
      HRESULT hr = decoder_->ProcessOutput(0, 1, &output, &status);
      if (output.pEvents) output.pEvents->Release();
      if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        ++need_more_count_;
        return;
      }
      if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        ConfigureOutput();
        continue;
      }
      Check(hr, "H264 ProcessOutput");
      ComPtr<IMFSample> decoded = output.pSample;
      if (!decoded) continue;
      ComPtr<IMFMediaBuffer> contiguous;
      Check(decoded->ConvertToContiguousBuffer(&contiguous), "Contiguous output");
      ComPtr<IMF2DBuffer> two_d;
      if (SUCCEEDED(contiguous.As(&two_d))) {
        BYTE* scanline = nullptr;
        LONG stride = 0;
        Check(two_d->Lock2D(&scanline, &stride), "Lock 2D output");
        bool has_frame = stride >= static_cast<LONG>(width_);
        if (has_frame) QueueNv12(scanline, static_cast<uint32_t>(stride));
        two_d->Unlock2D();
        continue;
      }
      BYTE* nv12 = nullptr;
      DWORD length = 0;
      Check(contiguous->Lock(&nv12, nullptr, &length), "Lock output");
      uint32_t stride = output_stride_ > 0
                            ? static_cast<uint32_t>(output_stride_)
                            : width_;
      // Some software MFTs omit MF_MT_DEFAULT_STRIDE. For tightly packed
      // NV12, the buffer length still reveals the aligned row stride.
      const uint64_t denominator = static_cast<uint64_t>(storage_height_) * 3;
      if (denominator != 0 &&
          (static_cast<uint64_t>(length) * 2) % denominator == 0) {
        const uint64_t inferred =
            (static_cast<uint64_t>(length) * 2) / denominator;
        if (inferred >= width_ && inferred <= width_ + 512) {
          stride = static_cast<uint32_t>(inferred);
        }
      }
      bool has_frame =
          length >= static_cast<uint64_t>(stride) * storage_height_ * 3 / 2;
      if (has_frame) QueueNv12(nv12, stride);
      contiguous->Unlock();
    }
    throw std::runtime_error("H264 decoder produced too many frames for one packet");
  }

  void ConvertNv12(const uint8_t* source, uint32_t stride) {
    std::lock_guard<std::mutex> lock(mutex_);
    const uint8_t* uv_plane =
        source + static_cast<size_t>(stride) * storage_height_;
    for (uint32_t y = 0; y < height_; ++y) {
      for (uint32_t x = 0; x < width_; ++x) {
        int yy = std::max(0, static_cast<int>(source[y * stride + x]) - 16);
        size_t uv = (y / 2) * stride + (x & ~1u);
        int u = static_cast<int>(uv_plane[uv]) - 128;
        int v = static_cast<int>(uv_plane[uv + 1]) - 128;
        size_t p = (static_cast<size_t>(y) * width_ + x) * 4;
        pixels_[p] = static_cast<uint8_t>(std::clamp((298 * yy + 409 * v + 128) >> 8, 0, 255));
        pixels_[p + 1] = static_cast<uint8_t>(std::clamp((298 * yy - 100 * u - 208 * v + 128) >> 8, 0, 255));
        pixels_[p + 2] = static_cast<uint8_t>(std::clamp((298 * yy + 516 * u + 128) >> 8, 0, 255));
        pixels_[p + 3] = 255;
      }
    }
  }

  void QueueNv12(const uint8_t* source, uint32_t stride) {
    const size_t size =
        static_cast<size_t>(stride) * storage_height_ * 3 / 2;
    std::vector<uint8_t> frame(source, source + size);
    {
      std::lock_guard<std::mutex> lock(conversion_mutex_);
      pending_nv12_ = std::move(frame);
      pending_stride_ = stride;
    }
    conversion_ready_.notify_one();
  }

  void RunConversionLoop() {
    for (;;) {
      std::vector<uint8_t> frame;
      uint32_t stride = 0;
      {
        std::unique_lock<std::mutex> lock(conversion_mutex_);
        conversion_ready_.wait(lock, [this] {
          return conversion_stopping_ || !pending_nv12_.empty();
        });
        if (conversion_stopping_) return;
        frame.swap(pending_nv12_);
        stride = pending_stride_;
      }
      ConvertNv12(frame.data(), stride);
      ++frame_count_;
      registrar_->MarkTextureFrameAvailable(texture_id_);
    }
  }

  flutter::TextureRegistrar* registrar_;
  uint32_t width_;
  uint32_t height_;
  uint32_t storage_height_ = height_;
  LONG output_stride_ = 0;
  int64_t texture_id_ = -1;
  std::atomic<int64_t> frame_count_ = 0;
  int64_t input_count_ = 0;
  int64_t need_more_count_ = 0;
  std::mutex mutex_;
  std::vector<uint8_t> pixels_;
  FlutterDesktopPixelBuffer pixel_buffer_ = {};
  flutter::TextureVariant texture_;
  ComPtr<IMFTransform> decoder_;
  bool configured_ = false;
  bool first_input_ = true;
  std::mutex conversion_mutex_;
  std::condition_variable conversion_ready_;
  std::vector<uint8_t> pending_nv12_;
  uint32_t pending_stride_ = 0;
  bool conversion_stopping_ = false;
  std::thread conversion_thread_;
};

void ScrcpyFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto video_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "scrcpy_flutter/video",
      &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<ScrcpyFlutterPlugin>(registrar);
  video_channel->SetMethodCallHandler([pointer = plugin.get()](const auto& call, auto result) {
    pointer->HandleVideoMethodCall(call, std::move(result));
  });
  registrar->AddPlugin(std::move(plugin));
}

ScrcpyFlutterPlugin::ScrcpyFlutterPlugin(flutter::PluginRegistrarWindows* registrar)
    : texture_registrar_(registrar->texture_registrar()) {}

ScrcpyFlutterPlugin::~ScrcpyFlutterPlugin() {
  if (texture_registrar_) {
    for (auto& entry : videos_) {
      entry.second->StopConversion();
      texture_registrar_->UnregisterTexture(entry.first);
    }
  }
}

void ScrcpyFlutterPlugin::HandleVideoMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  try {
    const auto& args = Args(call);
    if (call.method_name() == "create") {
      if (!texture_registrar_) throw std::runtime_error("Texture registrar unavailable");
      auto video = std::make_unique<NativeVideoTexture>(
          texture_registrar_, static_cast<uint32_t>(GetInt(args, "width")),
          static_cast<uint32_t>(GetInt(args, "height")));
      int64_t id = video->id();
      videos_[id] = std::move(video);
      result->Success(flutter::EncodableValue(id));
    } else if (call.method_name() == "decode") {
      auto video = videos_.find(GetInt(args, "textureId"));
      if (video == videos_.end()) throw std::invalid_argument("Unknown texture");
      const auto* data = std::get_if<std::vector<uint8_t>>(&Get(args, "data"));
      if (!data) throw std::invalid_argument("Invalid packet data");
      video->second->Decode(*data, GetInt(args, "pts"),
                            GetBool(args, "config"), GetBool(args, "keyFrame"));
      result->Success();
    } else if (call.method_name() == "frameCount") {
      auto video = videos_.find(GetInt(args, "textureId"));
      if (video == videos_.end()) throw std::invalid_argument("Unknown texture");
      result->Success(flutter::EncodableValue(video->second->frame_count()));
    } else if (call.method_name() == "videoStats") {
      auto video = videos_.find(GetInt(args, "textureId"));
      if (video == videos_.end()) throw std::invalid_argument("Unknown texture");
      flutter::EncodableMap stats;
      stats[flutter::EncodableValue("frames")] =
          flutter::EncodableValue(video->second->frame_count());
      stats[flutter::EncodableValue("inputs")] =
          flutter::EncodableValue(video->second->input_count());
      stats[flutter::EncodableValue("needMore")] =
          flutter::EncodableValue(video->second->need_more_count());
      result->Success(flutter::EncodableValue(stats));
    } else if (call.method_name() == "dispose") {
      int64_t id = GetInt(args, "textureId");
      auto video = videos_.find(id);
      if (video != videos_.end()) {
        video->second->StopConversion();
        texture_registrar_->UnregisterTexture(id);
        videos_.erase(video);
      }
      result->Success();
    } else {
      result->NotImplemented();
    }
  } catch (const std::exception& error) {
    result->Error("native_video_error", error.what());
  }
}

}  // namespace scrcpy_flutter
