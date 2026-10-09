Pod::Spec.new do |s|
  s.name             = 'scrcpy_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Embeddable Flutter client components for scrcpy.'
  s.description      = <<-DESC
Cross-platform ADB and scrcpy session support for Flutter applications.
                       DESC
  s.homepage         = 'https://github.com/yhsj0919/scrcpy_flutter'
  s.license          = { :type => 'Proprietary', :text => 'Not published.' }
  s.author           = { 'scrcpy_flutter' => 'scrcpy_flutter' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.swift_version    = '5.0'
  s.frameworks       = 'AVFoundation', 'AudioToolbox', 'CoreMedia', 'CoreVideo', 'VideoToolbox'
  s.prepare_command  = 'chmod 755 third_party/platform-tools/adb'
  s.resource_bundles = {
    'scrcpy_flutter_resources' => [
      'third_party/platform-tools/adb',
      'third_party/platform-tools/NOTICE.txt',
      'third_party/scrcpy/scrcpy-server-v5.0.1',
      'third_party/scrcpy/LICENSE'
    ]
  }
end
