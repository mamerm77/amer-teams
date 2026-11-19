import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:path_provider/path_provider.dart';

/// Recordings with consent (docs/RECORDINGS.md).
///
/// Media is end-to-end encrypted, so the server cannot record a meeting and never tries. The host's device records
/// what it already decrypts (the speaker's video and the meeting's audio) and, when stopped, shares the file in the
/// meeting chat as an end-to-end encrypted attachment.
///
/// Consent: the host asks; every participant in the meeting is asked on their own screen. Recording starts only
/// when everyone present has agreed. Someone who declines, or who joins later and declines, or who withdraws, stops
/// the recording at once. Each step is written to the server's tamper-evident audit trail.
class RecordingConsent {
  String? id;                       // current request
  final agreed = <String>{}, declined = <String>{};
  bool recording = false;

  /// [present] = identities in the meeting now (including the host). True when everyone present agreed.
  bool allAgreed(Iterable<String> present) => id != null && declined.isEmpty && present.every(agreed.contains);
  List<String> waitingFor(Iterable<String> present) => present.where((p) => !agreed.contains(p) && !declined.contains(p)).toList();
  void reset() { id = null; agreed.clear(); declined.clear(); recording = false; }
}

class DeviceRecorder {
  rtc.MediaRecorder? _r; String? path; DateTime? started;
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  Future<void> start(rtc.MediaStreamTrack? video) async {
    final dir = await getTemporaryDirectory();
    path = '${dir.path}/meeting-${DateTime.now().millisecondsSinceEpoch}.mp4';
    _r = rtc.MediaRecorder();
    await _r!.start(path!, videoTrack: video, audioChannel: rtc.RecorderAudioChannel.OUTPUT);
    started = DateTime.now();
  }
  /// Returns the file, or null if nothing was written.
  Future<File?> stop() async {
    final r = _r; _r = null; if (r == null) return null;
    await r.stop();
    final f = File(path!); return await f.exists() && await f.length() > 0 ? f : null;
  }
}
