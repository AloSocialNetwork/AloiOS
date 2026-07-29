platform :ios, '17.0'

ENV['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'] = '3d9be5ff55dea2d1c1263aca16fb3eaf289293637f98de47b77821309407828c'

target 'AloiOS' do
  use_frameworks!

  pod 'LibSignalClient', :git => 'https://github.com/signalapp/libsignal.git', :tag => 'v0.97.1'
  pod 'WebRTC-SDK', :podspec => 'https://raw.githubusercontent.com/webrtc-sdk/Specs/144.7559.10/WebRTC-SDK.podspec'

  target 'AloiOSTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['SWIFT_ENABLE_EXPLICIT_MODULES'] = 'NO'
      config.build_settings['CLANG_ENABLE_EXPLICIT_MODULES'] = 'NO'
    end
  end

  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.user_project.native_targets.each do |target|
      target.build_configurations.each do |config|
        config.build_settings['SWIFT_ENABLE_EXPLICIT_MODULES'] = 'NO'
        config.build_settings['CLANG_ENABLE_EXPLICIT_MODULES'] = 'NO'
      end
    end
    aggregate_target.user_project.save
  end
end
