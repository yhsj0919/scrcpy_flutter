#include "include/scrcpy_flutter/scrcpy_flutter_plugin.h"

#include <cstring>
#include <unordered_map>
#include <utility>

#ifdef SCRCPY_FLUTTER_HAS_GSTREAMER
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#endif

namespace {

FlValue* argument(FlMethodCall* call, const gchar* name) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, name);
}

bool read_int(FlMethodCall* call, const gchar* name, int64_t* value) {
  FlValue* item = argument(call, name);
  if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_INT) {
    return false;
  }
  *value = fl_value_get_int(item);
  return true;
}

bool read_bool(FlMethodCall* call, const gchar* name, bool* value) {
  FlValue* item = argument(call, name);
  if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_BOOL) {
    return false;
  }
  *value = fl_value_get_bool(item);
  return true;
}

bool read_double(FlMethodCall* call, const gchar* name, double* value) {
  FlValue* item = argument(call, name);
  if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_FLOAT) {
    return false;
  }
  *value = fl_value_get_float(item);
  return true;
}

const gchar* read_string(FlMethodCall* call, const gchar* name) {
  FlValue* item = argument(call, name);
  if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(item);
}

void respond_success(FlMethodCall* call, FlValue* result = nullptr) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(call, response, nullptr);
}

void respond_error(FlMethodCall* call, const gchar* code,
                   const gchar* message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
  fl_method_call_respond(call, response, nullptr);
}

#ifdef SCRCPY_FLUTTER_HAS_GSTREAMER

typedef struct _ScrcpyVideoTexture {
  FlPixelBufferTexture parent_instance;
  FlTextureRegistrar* registrar;
  GstElement* pipeline;
  GstAppSrc* source;
  GstAppSink* sink;
  GMutex frame_mutex;
  guint8* pixels;
  gsize pixel_capacity;
  guint32 width;
  guint32 height;
  guint8* pending_pixels;
  gsize pending_pixel_capacity;
  guint32 pending_width;
  guint32 pending_height;
  gint input_count;
  gint frame_count;
  gint dropped_inputs;
  GstElement* recording_pipeline;
  GstAppSrc* recording_source;
  gint64 recording_first_pts_us;
  gint recording_frames;
  gboolean recording_waiting_for_key_frame;
} ScrcpyVideoTexture;

typedef struct _ScrcpyVideoTextureClass {
  FlPixelBufferTextureClass parent_class;
} ScrcpyVideoTextureClass;

G_DEFINE_TYPE(ScrcpyVideoTexture, scrcpy_video_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean scrcpy_video_texture_copy_pixels(
    FlPixelBufferTexture* texture, const uint8_t** buffer, uint32_t* width,
    uint32_t* height, GError**) {
  auto* self = reinterpret_cast<ScrcpyVideoTexture*>(texture);
  g_mutex_lock(&self->frame_mutex);
  if (self->pending_pixels != nullptr && self->pending_width != 0 &&
      self->pending_height != 0) {
    std::swap(self->pixels, self->pending_pixels);
    std::swap(self->pixel_capacity, self->pending_pixel_capacity);
    self->width = self->pending_width;
    self->height = self->pending_height;
    self->pending_width = 0;
    self->pending_height = 0;
  }
  if (self->pixels == nullptr || self->width == 0 || self->height == 0) {
    g_mutex_unlock(&self->frame_mutex);
    return FALSE;
  }
  *buffer = self->pixels;
  *width = self->width;
  *height = self->height;
  g_mutex_unlock(&self->frame_mutex);
  return TRUE;
}

static void scrcpy_video_texture_dispose(GObject* object) {
  auto* self = reinterpret_cast<ScrcpyVideoTexture*>(object);
  if (self->pipeline != nullptr) {
    gst_element_set_state(self->pipeline, GST_STATE_NULL);
  }
  if (self->recording_pipeline != nullptr) {
    gst_element_set_state(self->recording_pipeline, GST_STATE_NULL);
    gst_object_unref(self->recording_source);
    gst_object_unref(self->recording_pipeline);
    self->recording_source = nullptr;
    self->recording_pipeline = nullptr;
  }
  g_clear_pointer(&self->pipeline, gst_object_unref);
  self->source = nullptr;
  self->sink = nullptr;
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(scrcpy_video_texture_parent_class)->dispose(object);
}

static void scrcpy_video_texture_finalize(GObject* object) {
  auto* self = reinterpret_cast<ScrcpyVideoTexture*>(object);
  g_free(self->pixels);
  g_free(self->pending_pixels);
  g_mutex_clear(&self->frame_mutex);
  G_OBJECT_CLASS(scrcpy_video_texture_parent_class)->finalize(object);
}

static void scrcpy_video_texture_class_init(ScrcpyVideoTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      scrcpy_video_texture_copy_pixels;
  GObjectClass* object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = scrcpy_video_texture_dispose;
  object_class->finalize = scrcpy_video_texture_finalize;
}

static void scrcpy_video_texture_init(ScrcpyVideoTexture* self) {
  self->registrar = nullptr;
  self->pipeline = nullptr;
  self->source = nullptr;
  self->sink = nullptr;
  self->pixels = nullptr;
  self->pixel_capacity = 0;
  self->width = 0;
  self->height = 0;
  self->pending_pixels = nullptr;
  self->pending_pixel_capacity = 0;
  self->pending_width = 0;
  self->pending_height = 0;
  self->input_count = 0;
  self->frame_count = 0;
  self->dropped_inputs = 0;
  self->recording_pipeline = nullptr;
  self->recording_source = nullptr;
  self->recording_first_pts_us = -1;
  self->recording_frames = 0;
  self->recording_waiting_for_key_frame = TRUE;
  g_mutex_init(&self->frame_mutex);
}

static GstFlowReturn on_video_sample(GstAppSink* sink, gpointer user_data) {
  auto* self = static_cast<ScrcpyVideoTexture*>(user_data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) return GST_FLOW_EOS;

  GstCaps* caps = gst_sample_get_caps(sample);
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstVideoInfo info;
  GstVideoFrame frame;
  gst_video_info_init(&info);
  const gboolean valid = caps != nullptr && buffer != nullptr &&
      gst_video_info_from_caps(&info, caps) &&
      gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ);
  if (!valid) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  const guint32 width = GST_VIDEO_FRAME_WIDTH(&frame);
  const guint32 height = GST_VIDEO_FRAME_HEIGHT(&frame);
  const gsize row_bytes = static_cast<gsize>(width) * 4;
  const gsize required = row_bytes * height;
  const guint8* source = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
  const gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);

  g_mutex_lock(&self->frame_mutex);
  if (self->pending_pixel_capacity < required) {
    self->pending_pixels =
        static_cast<guint8*>(g_realloc(self->pending_pixels, required));
    self->pending_pixel_capacity = required;
  }
  for (guint32 row = 0; row < height; ++row) {
    std::memcpy(self->pending_pixels + row * row_bytes, source + row * stride,
                row_bytes);
  }
  self->pending_width = width;
  self->pending_height = height;
  g_atomic_int_inc(&self->frame_count);
  g_mutex_unlock(&self->frame_mutex);

  gst_video_frame_unmap(&frame);
  gst_sample_unref(sample);
  fl_texture_registrar_mark_texture_frame_available(
      self->registrar, FL_TEXTURE(self));
  return GST_FLOW_OK;
}

ScrcpyVideoTexture* create_video_texture(FlTextureRegistrar* registrar,
                                         GError** error) {
  auto* texture = reinterpret_cast<ScrcpyVideoTexture*>(
      g_object_new(scrcpy_video_texture_get_type(), nullptr));
  texture->registrar = FL_TEXTURE_REGISTRAR(g_object_ref(registrar));
  texture->pipeline = gst_parse_launch(
      "appsrc name=source is-live=true format=time block=false "
      "max-bytes=2097152 ! queue max-size-buffers=8 max-size-bytes=0 "
      "max-size-time=0 leaky=downstream ! h264parse config-interval=-1 ! "
      "decodebin ! "
      "videoconvert ! video/x-raw,format=RGBA ! "
      "appsink name=sink emit-signals=true sync=false max-buffers=1 "
      "drop=true wait-on-eos=false",
      error);
  if (texture->pipeline == nullptr) {
    g_object_unref(texture);
    return nullptr;
  }
  texture->source =
      GST_APP_SRC(gst_bin_get_by_name(GST_BIN(texture->pipeline), "source"));
  texture->sink =
      GST_APP_SINK(gst_bin_get_by_name(GST_BIN(texture->pipeline), "sink"));
  if (texture->source == nullptr || texture->sink == nullptr) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                        "Unable to create the GStreamer video pipeline");
    if (texture->source != nullptr) gst_object_unref(texture->source);
    if (texture->sink != nullptr) gst_object_unref(texture->sink);
    texture->source = nullptr;
    texture->sink = nullptr;
    g_object_unref(texture);
    return nullptr;
  }
  GstCaps* source_caps = gst_caps_new_simple(
      "video/x-h264", "stream-format", G_TYPE_STRING, "byte-stream",
      "alignment", G_TYPE_STRING, "au", nullptr);
  gst_app_src_set_caps(texture->source, source_caps);
  gst_caps_unref(source_caps);
  g_signal_connect(texture->sink, "new-sample", G_CALLBACK(on_video_sample),
                   texture);
  gst_object_unref(texture->source);
  gst_object_unref(texture->sink);

  if (gst_element_set_state(texture->pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                        "Unable to start the GStreamer video decoder");
    g_object_unref(texture);
    return nullptr;
  }
  return texture;
}

bool push_video_packet(ScrcpyVideoTexture* texture, const guint8* data,
                       gsize size, gint64 presentation_time_us,
                       gboolean configuration, gboolean key_frame) {
  GstBuffer* buffer = gst_buffer_new_allocate(nullptr, size, nullptr);
  if (buffer == nullptr) return false;
  gst_buffer_fill(buffer, 0, data, size);
  if (presentation_time_us >= 0) {
    GST_BUFFER_PTS(buffer) = presentation_time_us * GST_USECOND;
  }
  if (!key_frame) GST_BUFFER_FLAG_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT);
  g_atomic_int_inc(&texture->input_count);
  if (gst_app_src_push_buffer(texture->source, buffer) != GST_FLOW_OK) {
    g_atomic_int_inc(&texture->dropped_inputs);
    return false;
  }
  if (texture->recording_source != nullptr &&
      (configuration || key_frame ||
       !texture->recording_waiting_for_key_frame)) {
    if (key_frame) texture->recording_waiting_for_key_frame = FALSE;
    GstBuffer* recording_buffer =
        gst_buffer_new_allocate(nullptr, size, nullptr);
    if (recording_buffer == nullptr) return false;
    gst_buffer_fill(recording_buffer, 0, data, size);
    if (configuration) {
      GST_BUFFER_FLAG_SET(recording_buffer, GST_BUFFER_FLAG_HEADER);
    } else if (presentation_time_us >= 0) {
      if (texture->recording_first_pts_us < 0) {
        texture->recording_first_pts_us = presentation_time_us;
      }
      const GstClockTime timestamp =
          (presentation_time_us - texture->recording_first_pts_us) *
          GST_USECOND;
      GST_BUFFER_PTS(recording_buffer) = timestamp;
      GST_BUFFER_DTS(recording_buffer) = timestamp;
    }
    if (!key_frame) {
      GST_BUFFER_FLAG_SET(recording_buffer, GST_BUFFER_FLAG_DELTA_UNIT);
    }
    if (gst_app_src_push_buffer(texture->recording_source,
                                recording_buffer) != GST_FLOW_OK) {
      return false;
    }
    if (!configuration) g_atomic_int_inc(&texture->recording_frames);
  }
  return true;
}

bool start_video_recording(ScrcpyVideoTexture* texture, const gchar* path,
                           GError** error) {
  if (texture->recording_pipeline != nullptr) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_EXISTS,
                        "Video recording is already active");
    return false;
  }
  GstElement* pipeline = gst_parse_launch(
      "appsrc name=source is-live=true format=time block=true ! "
      "h264parse config-interval=-1 ! video/x-h264,stream-format=avc,"
      "alignment=au ! mp4mux faststart=true ! filesink name=output",
      error);
  if (pipeline == nullptr) return false;
  GstAppSrc* source =
      GST_APP_SRC(gst_bin_get_by_name(GST_BIN(pipeline), "source"));
  GstElement* output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
  if (source == nullptr || output == nullptr) {
    if (source != nullptr) gst_object_unref(source);
    if (output != nullptr) gst_object_unref(output);
    gst_object_unref(pipeline);
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                        "Unable to create the GStreamer recording pipeline");
    return false;
  }
  GstCaps* caps = gst_caps_new_simple(
      "video/x-h264", "stream-format", G_TYPE_STRING, "byte-stream",
      "alignment", G_TYPE_STRING, "au", nullptr);
  gst_app_src_set_caps(source, caps);
  gst_caps_unref(caps);
  g_object_set(output, "location", path, nullptr);
  gst_object_unref(output);
  if (gst_element_set_state(pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    gst_object_unref(source);
    gst_object_unref(pipeline);
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                        "Unable to start the GStreamer recorder");
    return false;
  }
  texture->recording_pipeline = pipeline;
  texture->recording_source = source;
  texture->recording_first_pts_us = -1;
  texture->recording_frames = 0;
  texture->recording_waiting_for_key_frame = TRUE;
  return true;
}

struct RecordingFinalizeTask {
  GstElement* pipeline;
  GstAppSrc* source;
  int frames;
};

void finalize_recording(GTask* task, gpointer, gpointer task_data,
                        GCancellable*) {
  auto* recording = static_cast<RecordingFinalizeTask*>(task_data);
  gst_app_src_end_of_stream(recording->source);
  GstBus* bus = gst_element_get_bus(recording->pipeline);
  GstMessage* message = gst_bus_timed_pop_filtered(
      bus, 5 * GST_SECOND,
      static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
  const bool succeeded = message != nullptr &&
      GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
  if (message != nullptr && GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
    GError* pipeline_error = nullptr;
    gchar* details = nullptr;
    gst_message_parse_error(message, &pipeline_error, &details);
    g_task_return_new_error(
        task, G_IO_ERROR, G_IO_ERROR_FAILED, "%s%s%s",
        pipeline_error == nullptr ? "Unable to finalize recording"
                                  : pipeline_error->message,
        details == nullptr ? "" : ": ", details == nullptr ? "" : details);
    g_clear_error(&pipeline_error);
    g_free(details);
  } else if (!succeeded) {
    g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                            "Timed out while finalizing video recording");
  } else {
    g_task_return_int(task, recording->frames);
  }
  if (message != nullptr) gst_message_unref(message);
  gst_object_unref(bus);
  gst_element_set_state(recording->pipeline, GST_STATE_NULL);
  gst_object_unref(recording->source);
  gst_object_unref(recording->pipeline);
}

void recording_finalized(GObject* source_object, GAsyncResult* result,
                         gpointer) {
  auto* call = FL_METHOD_CALL(source_object);
  g_autoptr(GError) error = nullptr;
  const int frames = g_task_propagate_int(G_TASK(result), &error);
  if (error != nullptr) {
    respond_error(call, "recording_failure", error->message);
  } else {
    respond_success(call, fl_value_new_int(frames));
  }
}

void stop_video_recording(ScrcpyVideoTexture* texture, FlMethodCall* call) {
  if (texture->recording_pipeline == nullptr) {
    respond_success(call, fl_value_new_int(0));
    return;
  }
  auto* recording = g_new(RecordingFinalizeTask, 1);
  recording->pipeline = texture->recording_pipeline;
  recording->source = texture->recording_source;
  recording->frames = g_atomic_int_get(&texture->recording_frames);
  texture->recording_source = nullptr;
  texture->recording_pipeline = nullptr;
  g_autoptr(GTask) task = g_task_new(call, nullptr, recording_finalized, nullptr);
  g_task_set_task_data(task, recording, g_free);
  g_task_run_in_thread(task, finalize_recording);
}

struct ScrcpyAudioPlayer {
  GstElement* pipeline;
  GstAppSrc* source;
  GstElement* gain;
  gint decoded_packets;
  gint played_buffers;
  gint dropped_buffers;
  gint64 first_pts_us;
  guint bus_watch_id;
};

static void on_audio_buffer(GstElement*, GstBuffer*, gpointer user_data) {
  auto* player = static_cast<ScrcpyAudioPlayer*>(user_data);
  g_atomic_int_inc(&player->played_buffers);
}

static gboolean on_audio_bus_message(GstBus*, GstMessage* message,
                                     gpointer) {
  if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
    GError* error = nullptr;
    gchar* details = nullptr;
    gst_message_parse_error(message, &error, &details);
    const gchar* message_text =
        error == nullptr ? "unknown error" : error->message;
    if (details == nullptr) {
      g_warning("scrcpy audio: %s", message_text);
    } else {
      g_warning("scrcpy audio: %s (%s)", message_text, details);
    }
    g_clear_error(&error);
    g_free(details);
  }
  return G_SOURCE_CONTINUE;
}

ScrcpyAudioPlayer* create_audio_player(GError** error) {
  auto* player = g_new0(ScrcpyAudioPlayer, 1);
  player->first_pts_us = -1;
  player->pipeline = gst_parse_launch(
      "appsrc name=source is-live=true format=time block=false "
      "max-bytes=524288 caps=audio/x-opus,rate=48000,channels=2,"
      "channel-mapping-family=0 ! queue max-size-buffers=12 "
      "max-size-bytes=0 max-size-time=0 leaky=downstream ! opusdec ! "
      "audioconvert ! audioresample ! volume name=gain ! "
      "identity name=rendered signal-handoffs=true ! autoaudiosink sync=true",
      error);
  if (player->pipeline == nullptr) {
    g_free(player);
    return nullptr;
  }
  player->source =
      GST_APP_SRC(gst_bin_get_by_name(GST_BIN(player->pipeline), "source"));
  player->gain = gst_bin_get_by_name(GST_BIN(player->pipeline), "gain");
  GstElement* rendered =
      gst_bin_get_by_name(GST_BIN(player->pipeline), "rendered");
  if (player->source == nullptr || player->gain == nullptr ||
      rendered == nullptr) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                        "Unable to create the GStreamer audio pipeline");
    if (player->source != nullptr) gst_object_unref(player->source);
    if (player->gain != nullptr) gst_object_unref(player->gain);
    if (rendered != nullptr) gst_object_unref(rendered);
    gst_object_unref(player->pipeline);
    g_free(player);
    return nullptr;
  }
  g_signal_connect(rendered, "handoff", G_CALLBACK(on_audio_buffer), player);
  gst_object_unref(rendered);
  GstBus* bus = gst_element_get_bus(player->pipeline);
  player->bus_watch_id = gst_bus_add_watch(bus, on_audio_bus_message, player);
  gst_object_unref(bus);
  if (gst_element_set_state(player->pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                        "Unable to open the Linux audio output");
    if (player->bus_watch_id != 0) g_source_remove(player->bus_watch_id);
    gst_object_unref(player->source);
    gst_object_unref(player->gain);
    gst_object_unref(player->pipeline);
    g_free(player);
    return nullptr;
  }
  return player;
}

void dispose_audio_player(ScrcpyAudioPlayer* player) {
  if (player == nullptr) return;
  if (player->bus_watch_id != 0) {
    g_source_remove(player->bus_watch_id);
    player->bus_watch_id = 0;
  }
  gst_element_set_state(player->pipeline, GST_STATE_NULL);
  gst_object_unref(player->source);
  gst_object_unref(player->gain);
  gst_object_unref(player->pipeline);
  g_free(player);
}

bool push_audio_packet(ScrcpyAudioPlayer* player, const guint8* data,
                       gsize size, gint64 presentation_time_us) {
  if (size == 0) return true;
  GstBuffer* buffer = gst_buffer_new_allocate(nullptr, size, nullptr);
  if (buffer == nullptr) return false;
  gst_buffer_fill(buffer, 0, data, size);
  if (presentation_time_us >= 0) {
    if (player->first_pts_us < 0) player->first_pts_us = presentation_time_us;
    GST_BUFFER_PTS(buffer) =
        (presentation_time_us - player->first_pts_us) * GST_USECOND;
  }
  if (gst_app_src_push_buffer(player->source, buffer) != GST_FLOW_OK) {
    g_atomic_int_inc(&player->dropped_buffers);
    return false;
  }
  g_atomic_int_inc(&player->decoded_packets);
  return true;
}

#endif
}  // namespace

struct _ScrcpyFlutterPlugin {
  GObject parent_instance;
  FlMethodChannel* video_channel;
  FlMethodChannel* audio_channel;
  FlTextureRegistrar* texture_registrar;
#ifdef SCRCPY_FLUTTER_HAS_GSTREAMER
  std::unordered_map<int64_t, ScrcpyVideoTexture*>* videos;
  std::unordered_map<int64_t, ScrcpyAudioPlayer*>* audios;
  int64_t next_audio_id;
#endif
};

G_DEFINE_TYPE(ScrcpyFlutterPlugin, scrcpy_flutter_plugin, G_TYPE_OBJECT)

static void scrcpy_flutter_plugin_dispose(GObject* object) {
  ScrcpyFlutterPlugin* self = SCRCPY_FLUTTER_PLUGIN(object);
#ifdef SCRCPY_FLUTTER_HAS_GSTREAMER
  if (self->videos != nullptr) {
    for (const auto& entry : *self->videos) {
      fl_texture_registrar_unregister_texture(
          self->texture_registrar, FL_TEXTURE(entry.second));
      g_object_unref(entry.second);
    }
    self->videos->clear();
  }
  if (self->audios != nullptr) {
    for (const auto& entry : *self->audios) {
      dispose_audio_player(entry.second);
    }
    self->audios->clear();
  }
#endif
  g_clear_object(&self->video_channel);
  g_clear_object(&self->audio_channel);
  g_clear_object(&self->texture_registrar);
  G_OBJECT_CLASS(scrcpy_flutter_plugin_parent_class)->dispose(object);
}

static void scrcpy_flutter_plugin_finalize(GObject* object) {
  ScrcpyFlutterPlugin* self = SCRCPY_FLUTTER_PLUGIN(object);
#ifdef SCRCPY_FLUTTER_HAS_GSTREAMER
  delete self->videos;
  self->videos = nullptr;
  delete self->audios;
  self->audios = nullptr;
#endif
  G_OBJECT_CLASS(scrcpy_flutter_plugin_parent_class)->finalize(object);
}

static void scrcpy_flutter_plugin_class_init(ScrcpyFlutterPluginClass* klass) {
  GObjectClass* object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = scrcpy_flutter_plugin_dispose;
  object_class->finalize = scrcpy_flutter_plugin_finalize;
}

static void scrcpy_flutter_plugin_init(ScrcpyFlutterPlugin* self) {
  self->video_channel = nullptr;
  self->audio_channel = nullptr;
  self->texture_registrar = nullptr;
#ifdef SCRCPY_FLUTTER_HAS_GSTREAMER
  self->videos = new std::unordered_map<int64_t, ScrcpyVideoTexture*>();
  self->audios = new std::unordered_map<int64_t, ScrcpyAudioPlayer*>();
  self->next_audio_id = 1;
#endif
}

static void handle_video_method_call(ScrcpyFlutterPlugin* self,
                                     FlMethodCall* call) {
#ifndef SCRCPY_FLUTTER_HAS_GSTREAMER
  respond_error(call, "unsupported_capability",
                "Linux video requires GStreamer 1.0 with the app, video, "
                "H.264 parser and decoder plugins");
#else
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "create") == 0) {
    int64_t codec_id = 0;
    if (!read_int(call, "codecId", &codec_id) || codec_id != 0x68323634) {
      respond_error(call, "unsupported_capability",
                    "The Linux video backend currently supports H.264 only");
      return;
    }
    g_autoptr(GError) error = nullptr;
    ScrcpyVideoTexture* texture =
        create_video_texture(self->texture_registrar, &error);
    if (texture == nullptr) {
      respond_error(call, "native_video_error",
                    error == nullptr ? "Unable to create video decoder"
                                     : error->message);
      return;
    }
    if (!fl_texture_registrar_register_texture(self->texture_registrar,
                                               FL_TEXTURE(texture))) {
      g_object_unref(texture);
      respond_error(call, "native_video_error",
                    "Unable to register the Flutter video texture");
      return;
    }
    const int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
    (*self->videos)[id] = texture;
    respond_success(call, fl_value_new_int(id));
    return;
  }

  int64_t texture_id = 0;
  if (!read_int(call, "textureId", &texture_id)) {
    respond_error(call, "native_video_error", "Missing textureId");
    return;
  }
  auto entry = self->videos->find(texture_id);
  if (entry == self->videos->end()) {
    respond_error(call, "native_video_error", "Unknown video texture");
    return;
  }
  ScrcpyVideoTexture* texture = entry->second;

  if (strcmp(method, "decode") == 0) {
    FlValue* data_value = argument(call, "data");
    int64_t pts = 0;
    if (data_value == nullptr ||
        fl_value_get_type(data_value) != FL_VALUE_TYPE_UINT8_LIST ||
        !read_int(call, "pts", &pts)) {
      respond_error(call, "native_video_error", "Invalid video packet");
      return;
    }
    FlValue* key_value = argument(call, "keyFrame");
    FlValue* config_value = argument(call, "config");
    const gboolean key_frame = key_value != nullptr &&
        fl_value_get_type(key_value) == FL_VALUE_TYPE_BOOL &&
        fl_value_get_bool(key_value);
    const gboolean configuration = config_value != nullptr &&
        fl_value_get_type(config_value) == FL_VALUE_TYPE_BOOL &&
        fl_value_get_bool(config_value);
    if (!push_video_packet(texture, fl_value_get_uint8_list(data_value),
                           fl_value_get_length(data_value), pts, configuration,
                           key_frame)) {
      respond_error(call, "native_video_error",
                    "The GStreamer decoder rejected the video packet");
      return;
    }
    respond_success(call);
  } else if (strcmp(method, "frameCount") == 0) {
    respond_success(call,
                    fl_value_new_int(g_atomic_int_get(&texture->frame_count)));
  } else if (strcmp(method, "videoStats") == 0) {
    g_autoptr(FlValue) stats = fl_value_new_map();
    fl_value_set_string_take(
        stats, "frames",
        fl_value_new_int(g_atomic_int_get(&texture->frame_count)));
    fl_value_set_string_take(
        stats, "inputs",
        fl_value_new_int(g_atomic_int_get(&texture->input_count)));
    fl_value_set_string_take(
        stats, "needMore",
        fl_value_new_int(g_atomic_int_get(&texture->dropped_inputs)));
    respond_success(call, stats);
  } else if (strcmp(method, "dispose") == 0) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(texture));
    self->videos->erase(entry);
    g_object_unref(texture);
    respond_success(call);
  } else if (strcmp(method, "captureFrame") == 0) {
    g_mutex_lock(&texture->frame_mutex);
    const guint8* source = texture->pending_pixels != nullptr &&
            texture->pending_width != 0 && texture->pending_height != 0
        ? texture->pending_pixels
        : texture->pixels;
    const guint32 width = texture->pending_width != 0
        ? texture->pending_width
        : texture->width;
    const guint32 height = texture->pending_height != 0
        ? texture->pending_height
        : texture->height;
    if (source == nullptr || width == 0 || height == 0) {
      g_mutex_unlock(&texture->frame_mutex);
      respond_error(call, "capture_failure",
                    "No decoded video frame is available");
      return;
    }
    const gsize length = static_cast<gsize>(width) * height * 4;
    g_autofree guint8* pixels = static_cast<guint8*>(g_malloc(length));
    std::memcpy(pixels, source, length);
    g_mutex_unlock(&texture->frame_mutex);
    g_autoptr(FlValue) frame = fl_value_new_map();
    fl_value_set_string_take(frame, "width", fl_value_new_int(width));
    fl_value_set_string_take(frame, "height", fl_value_new_int(height));
    fl_value_set_string_take(
        frame, "pixels", fl_value_new_uint8_list(pixels, length));
    respond_success(call, frame);
  } else if (strcmp(method, "startRecording") == 0) {
    const gchar* path = read_string(call, "path");
    if (path == nullptr || *path == '\0') {
      respond_error(call, "recording_failure", "Missing recording path");
      return;
    }
    g_autoptr(GError) error = nullptr;
    if (!start_video_recording(texture, path, &error)) {
      respond_error(call, "recording_failure",
                    error == nullptr ? "Unable to start video recording"
                                     : error->message);
      return;
    }
    respond_success(call);
  } else if (strcmp(method, "stopRecording") == 0) {
    stop_video_recording(texture, call);
  } else {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
#endif
}

static void handle_audio_method_call(ScrcpyFlutterPlugin* self,
                                     FlMethodCall* call) {
#ifndef SCRCPY_FLUTTER_HAS_GSTREAMER
  respond_error(call, "unsupported_capability",
                "Linux audio requires GStreamer 1.0 with Opus and an "
                "available system audio sink");
#else
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "create") == 0) {
    g_autoptr(GError) error = nullptr;
    ScrcpyAudioPlayer* player = create_audio_player(&error);
    if (player == nullptr) {
      respond_error(call, "native_audio_error",
                    error == nullptr ? "Unable to create audio player"
                                     : error->message);
      return;
    }
    const int64_t id = self->next_audio_id++;
    (*self->audios)[id] = player;
    respond_success(call, fl_value_new_int(id));
    return;
  }

  int64_t audio_id = 0;
  if (!read_int(call, "audioId", &audio_id)) {
    respond_error(call, "native_audio_error", "Missing audioId");
    return;
  }
  auto entry = self->audios->find(audio_id);
  if (entry == self->audios->end()) {
    respond_error(call, "native_audio_error", "Unknown audio player");
    return;
  }
  ScrcpyAudioPlayer* player = entry->second;

  if (strcmp(method, "decode") == 0) {
    FlValue* data_value = argument(call, "data");
    int64_t pts = 0;
    bool configuration = false;
    if (data_value == nullptr ||
        fl_value_get_type(data_value) != FL_VALUE_TYPE_UINT8_LIST ||
        !read_int(call, "pts", &pts) ||
        !read_bool(call, "config", &configuration)) {
      respond_error(call, "native_audio_error", "Invalid audio packet");
      return;
    }
    if (!configuration &&
        !push_audio_packet(player, fl_value_get_uint8_list(data_value),
                           fl_value_get_length(data_value), pts)) {
      respond_error(call, "native_audio_error",
                    "The GStreamer player rejected the audio packet");
      return;
    }
    respond_success(call);
  } else if (strcmp(method, "setMuted") == 0) {
    bool muted = false;
    if (!read_bool(call, "muted", &muted)) {
      respond_error(call, "native_audio_error", "Invalid muted value");
      return;
    }
    g_object_set(player->gain, "mute", muted, nullptr);
    respond_success(call);
  } else if (strcmp(method, "setVolume") == 0) {
    double volume = 0;
    if (!read_double(call, "volume", &volume) || volume < 0 || volume > 1) {
      respond_error(call, "native_audio_error", "Invalid volume value");
      return;
    }
    g_object_set(player->gain, "volume", volume, nullptr);
    respond_success(call);
  } else if (strcmp(method, "audioStats") == 0) {
    guint64 buffered_bytes = 0;
    g_object_get(player->source, "current-level-bytes", &buffered_bytes,
                 nullptr);
    g_autoptr(FlValue) stats = fl_value_new_map();
    fl_value_set_string_take(
        stats, "decodedPackets",
        fl_value_new_int(g_atomic_int_get(&player->decoded_packets)));
    fl_value_set_string_take(
        stats, "playedBuffers",
        fl_value_new_int(g_atomic_int_get(&player->played_buffers)));
    fl_value_set_string_take(
        stats, "droppedBuffers",
        fl_value_new_int(g_atomic_int_get(&player->dropped_buffers)));
    fl_value_set_string_take(
        stats, "bufferedBytes",
        fl_value_new_int(static_cast<int64_t>(buffered_bytes)));
    fl_value_set_string_take(stats, "peakSample", fl_value_new_int(0));
    respond_success(call, stats);
  } else if (strcmp(method, "dispose") == 0) {
    self->audios->erase(entry);
    dispose_audio_player(player);
    respond_success(call);
  } else {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
#endif
}

void scrcpy_flutter_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
#ifdef SCRCPY_FLUTTER_HAS_GSTREAMER
  gst_init(nullptr, nullptr);
#endif
  ScrcpyFlutterPlugin* plugin = SCRCPY_FLUTTER_PLUGIN(
      g_object_new(scrcpy_flutter_plugin_get_type(), nullptr));
  plugin->texture_registrar = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->video_channel = fl_method_channel_new(
      messenger, "scrcpy_flutter/video", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->video_channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
        handle_video_method_call(SCRCPY_FLUTTER_PLUGIN(user_data), call);
      },
      g_object_ref(plugin), g_object_unref);
  plugin->audio_channel = fl_method_channel_new(
      messenger, "scrcpy_flutter/audio", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->audio_channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
        handle_audio_method_call(SCRCPY_FLUTTER_PLUGIN(user_data), call);
      },
      g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}
