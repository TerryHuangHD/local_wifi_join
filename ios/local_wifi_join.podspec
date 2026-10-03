#
# Keep `s.version` in sync with `version` in ../pubspec.yaml.
# Validate with `pod lib lint local_wifi_join.podspec --allow-warnings`.
#
Pod::Spec.new do |s|
  s.name             = 'local_wifi_join'
  s.version          = '0.1.0'
  s.summary          = 'Join and leave a WPA2-Personal Wi-Fi access point from Flutter.'
  s.description      = <<-DESC
Flutter plugin that joins and leaves a WPA2-Personal access point with
NEHotspotConfiguration, judging the result by the apply error only (iOS 26+ safe).
                       DESC
  s.homepage         = 'https://github.com/TerryHuangHD/local_wifi_join'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Terry Huang' => 'https://github.com/TerryHuangHD' }
  s.source           = { :path => '.' }
  s.source_files     = 'local_wifi_join/Sources/local_wifi_join/**/*.swift'
  s.resource_bundles = { 'local_wifi_join_privacy' => ['local_wifi_join/Sources/local_wifi_join/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Network', 'NetworkExtension'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
