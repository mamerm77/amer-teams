import 'dart:io';
import 'package:flutter/services.dart';

/// Background effects on the local camera track (docs/BACKGROUND_EFFECTS.md). Frames are processed on this device
/// by the platform's own person-segmentation model before they are encoded and end-to-end encrypted.
/// Android: ML Kit selfie segmentation. iOS: Apple Vision person segmentation (iOS 15+). Desktop: not available.
class AmerBackground {
  static const _ch = MethodChannel('com.amerteams/background');
  static bool get supported => Platform.isAndroid || Platform.isIOS;
  /// [trackId] is the WebRTC id of the local camera track. [blur] 0 = off, 1..25 = blur radius. [lowLight] brightens dark video.
  static Future<bool> apply(String trackId, {int blur = 0, bool lowLight = false}) async {
    if (!supported) return false;
    try { return await _ch.invokeMethod<bool>('apply', {'trackId': trackId, 'blur': blur, 'lowLight': lowLight}) ?? false; }
    on PlatformException { return false; } on MissingPluginException { return false; }
  }
}
