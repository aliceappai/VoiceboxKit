Pod::Spec.new do |s|
  s.name             = 'VoiceboxKit'
  s.version          = '1.0.0'
  s.summary          = 'Drop-in Voicebox recording experience for iOS apps.'
  s.description      = <<-DESC
    VoiceboxKit lets any iOS engineer embed a Voicebox recording experience
    in their app in minutes. Wraps a WKWebView with clean configuration,
    aggressive caching, and flexible presentation modes.
  DESC
  s.homepage         = 'https://github.com/aliceappai/VoiceboxKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Voicebox AI' => 'eng@voicebox.ai' }
  s.source           = { :git => 'https://github.com/aliceappai/VoiceboxKit.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.7'
  s.source_files     = 'Sources/VoiceboxKit/**/*.swift'
  s.frameworks       = 'UIKit', 'WebKit', 'AVFoundation', 'SystemConfiguration'
end
