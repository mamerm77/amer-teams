import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';

/// Ringtone (callee) and ringback (caller), synthesised as 16-bit PCM WAV, so no audio assets are needed.
/// Ringback follows the ITU-T E.180 / UAE pattern: 400+450 Hz, 0.4 s on, 0.2 s off, 0.4 s on, 2 s off.
class Tones {
  Tones._();
  static final _p = AudioPlayer();
  static Uint8List? _ring, _back, _busy, _end;

  static Uint8List _wav(List<(List<double>, double)> segs, {double vol = .35}) {
    const sr = 16000;
    final pcm = BytesBuilder();
    for (final (freqs, secs) in segs) {
      final n = (sr * secs).round();
      for (var i = 0; i < n; i++) {
        var v = 0.0;
        for (final f in freqs) { v += sin(2 * pi * f * i / sr); }
        if (freqs.isNotEmpty) v /= freqs.length;
        final fade = min(1.0, min(i, n - i) / 160);              // 10 ms fade, no clicks
        final s = (v * vol * fade * 32767).round();
        pcm.add([s & 0xff, (s >> 8) & 0xff]);
      }
    }
    final d = pcm.toBytes();
    final h = ByteData(44)
      ..setUint32(0, 0x52494646) ..setUint32(4, 36 + d.length, Endian.little) ..setUint32(8, 0x57415645)
      ..setUint32(12, 0x666d7420) ..setUint32(16, 16, Endian.little) ..setUint16(20, 1, Endian.little) ..setUint16(22, 1, Endian.little)
      ..setUint32(24, sr, Endian.little) ..setUint32(28, sr * 2, Endian.little) ..setUint16(32, 2, Endian.little) ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461) ..setUint32(40, d.length, Endian.little);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...d]);
  }

  static Future<void> _loop(Uint8List b) async {
    await _p.stop(); await _p.setReleaseMode(ReleaseMode.loop); await _p.play(BytesSource(b, mimeType: 'audio/wav'));
  }
  static Future<void> ringtone() => _loop(_ring ??= _wav([([880, 1100], .25), ([], .05), ([880, 1100], .25), ([], .05), ([880, 1100], .25), ([], 1.4)], vol: .5));
  static Future<void> ringback() => _loop(_back ??= _wav([([400, 450], .4), ([], .2), ([400, 450], .4), ([], 2.0)]));
  static Future<void> busy() async {
    await _p.stop(); await _p.setReleaseMode(ReleaseMode.stop);
    await _p.play(BytesSource(_busy ??= _wav([for (var i = 0; i < 4; i++) ...[([400], .375), ([], .375)]]), mimeType: 'audio/wav'));
  }
  static Future<void> ended() async {
    await _p.stop(); await _p.setReleaseMode(ReleaseMode.stop);
    await _p.play(BytesSource(_end ??= _wav([([480, 620], .25), ([], .1), ([480, 620], .25)]), mimeType: 'audio/wav'));
  }
  static Future<void> stop() async { try { await _p.stop(); } catch (_) {} }
}
