"""Adds the camera/mic/network permissions the app needs to the generated native projects."""
import re, sys, pathlib
if "android" in sys.argv:
    m = pathlib.Path("android/app/src/main/AndroidManifest.xml"); s = m.read_text()
    perms = ["INTERNET", "CAMERA", "RECORD_AUDIO", "MODIFY_AUDIO_SETTINGS", "BLUETOOTH_CONNECT", "ACCESS_NETWORK_STATE",
             "FOREGROUND_SERVICE", "FOREGROUND_SERVICE_MEDIA_PROJECTION", "POST_NOTIFICATIONS", "WAKE_LOCK"]
    tags = "".join(f'    <uses-permission android:name="android.permission.{p}"/>\n' for p in perms)
    s = s.replace("<application", tags + "    <application", 1)
    s = s.replace("<application", '<application android:usesCleartextTraffic="true"', 1)  # LAN test mode only
    m.write_text(s)
    g = pathlib.Path("android/app/build.gradle")
    if not g.exists(): g = pathlib.Path("android/app/build.gradle.kts")
    t = g.read_text(); t = re.sub(r"minSdk\s*=?\s*[\w.]+", "minSdk = 24" if g.suffix == ".kts" else "minSdk 24", t); g.write_text(t)
if "ios" in sys.argv:
    p = pathlib.Path("ios/Runner/Info.plist"); s = p.read_text()
    add = """	<key>NSCameraUsageDescription</key><string>Video calls</string>
	<key>NSMicrophoneUsageDescription</key><string>Voice and video calls</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>On-device live captions</string>
	<key>UIBackgroundModes</key><array><string>audio</string><string>voip</string><string>remote-notification</string></array>
"""
    p.write_text(s.replace("<dict>", "<dict>\n" + add, 1))
    pod = pathlib.Path("ios/Podfile")          # newer Flutter creates it only at first build
    if pod.exists():
        t = pod.read_text(); t = re.sub(r"^#?\s*platform :ios, '[\d.]+'", "platform :ios, '14.0'", t, flags=re.M); pod.write_text(t)
    else:
        pod.write_text("platform :ios, '14.0'\n" + "\n".join([
            "ENV['COCOAPODS_DISABLE_STATS'] = 'true'",
            "project 'Runner', {'Debug' => :debug, 'Profile' => :release, 'Release' => :release}",
            "def flutter_root",
            "  generated = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)",
            "  File.foreach(generated) { |l| m = l.match(/FLUTTER_ROOT\\=(.*)/); return m[1].strip if m }",
            "end",
            "require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)",
            "flutter_ios_podfile_setup",
            "target 'Runner' do",
            "  use_frameworks!",
            "  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))",
            "end",
            "post_install do |installer|",
            "  installer.pods_project.targets.each do |t|",
            "    flutter_additional_ios_build_settings(t)",
            "    t.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0' }",
            "  end",
            "end", ""]))
    pbx = pathlib.Path("ios/Runner.xcodeproj/project.pbxproj"); t = pbx.read_text()
    t = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;", "IPHONEOS_DEPLOYMENT_TARGET = 14.0;", t)
    t = t.replace("PRODUCT_BUNDLE_IDENTIFIER = com.amerteams.amerTeams;", "PRODUCT_BUNDLE_IDENTIFIER = com.amerteams.app;")
    pbx.write_text(t)
if "windows" in sys.argv:
    import shutil
    shutil.copy("../installer/amer-teams.ico", "windows/runner/resources/app_icon.ico")
    m = pathlib.Path("windows/runner/main.cpp"); t = m.read_text()
    t = re.sub(r'L"amer_teams"', 'L"Amer Teams"', t); m.write_text(t)
    rc = pathlib.Path("windows/runner/Runner.rc"); t = rc.read_text(encoding="utf-8", errors="ignore")
    for k, v in {"CompanyName": "Amer Telecom", "FileDescription": "Amer Teams", "ProductName": "Amer Teams", "LegalCopyright": "Copyright (C) 2026 Amer Telecom"}.items():
        t = re.sub(rf'VALUE "{k}", "[^"]*"', f'VALUE "{k}", "{v}"', t)
    rc.write_text(t, encoding="utf-8")
print("native projects patched")
