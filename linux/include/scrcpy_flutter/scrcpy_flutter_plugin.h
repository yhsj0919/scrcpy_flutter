#ifndef FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_SCRCPY_FLUTTER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

G_DECLARE_FINAL_TYPE(ScrcpyFlutterPlugin, scrcpy_flutter_plugin,
                     SCRCPY_FLUTTER, PLUGIN, GObject)

void scrcpy_flutter_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif
