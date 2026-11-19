Pod::Spec.new do |s|
  s.name = 'amer_background'; s.version = '0.1.0'; s.summary = 'Background blur and low light for Amer Teams calls'
  s.homepage = 'https://github.com/mamerm77/amer-teams'; s.license = { :type => 'Proprietary' }; s.author = 'Amer Teams'
  s.source = { :path => '.' }; s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'          # flutter_webrtc is reached at run time (it ships as a Swift package; no CocoaPods link)
  s.platform = :ios, '13.0'; s.frameworks = 'Vision', 'CoreImage'
end
