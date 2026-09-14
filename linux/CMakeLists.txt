cmake_minimum_required(VERSION 3.13)

set(PROJECT_NAME "scrcpy_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "scrcpy_flutter_plugin")

add_library(${PLUGIN_NAME} SHARED
  "scrcpy_flutter_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)

# The plugin still builds on minimal hosts. Native video is enabled when the
# standard GStreamer development modules are available.
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(GSTREAMER QUIET IMPORTED_TARGET
    gstreamer-1.0
    gstreamer-app-1.0
    gstreamer-video-1.0
  )
endif()
if(GSTREAMER_FOUND)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE
    SCRCPY_FLUTTER_HAS_GSTREAMER=1)
  target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GSTREAMER)
endif()

set(RESOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/resources")
file(MAKE_DIRECTORY "${RESOURCE_DIR}")
configure_file("third_party/platform-tools/adb" "${RESOURCE_DIR}/adb" COPYONLY)
configure_file("third_party/platform-tools/NOTICE.txt"
  "${RESOURCE_DIR}/platform-tools-NOTICE.txt" COPYONLY)
configure_file("third_party/scrcpy/scrcpy-server-v4.1"
  "${RESOURCE_DIR}/scrcpy-server-v4.1" COPYONLY)
configure_file("third_party/scrcpy/LICENSE"
  "${RESOURCE_DIR}/scrcpy-LICENSE" COPYONLY)
file(CHMOD "${RESOURCE_DIR}/adb"
  PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE
              WORLD_READ WORLD_EXECUTE)

set(scrcpy_flutter_bundled_libraries
  "${RESOURCE_DIR}/adb"
  "${RESOURCE_DIR}/platform-tools-NOTICE.txt"
  "${RESOURCE_DIR}/scrcpy-server-v4.1"
  "${RESOURCE_DIR}/scrcpy-LICENSE"
  PARENT_SCOPE
)
