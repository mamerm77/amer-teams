import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

/// Choices made before joining a meeting.
class PreJoinChoice {
  const PreJoinChoice({required this.mic, required this.cam, this.micId, this.camId, this.speakerId});
  final bool mic, cam; final String? micId, camId, speakerId;
}

/// Pre-join, as in Teams and Zoom: camera preview, microphone and camera on/off, and device choice.
/// Nothing is sent anywhere until Join; the preview stays on this device.
Future<PreJoinChoice?> showPreJoin(BuildContext context, {required String title, bool video = true}) =>
    Navigator.push<PreJoinChoice>(context, MaterialPageRoute(builder: (_) => _PreJoin(title: title, video: video)));

class _PreJoin extends StatefulWidget {
  const _PreJoin({required this.title, required this.video});
  final String title; final bool video;
  @override State<_PreJoin> createState() => _S();
}

class _S extends State<_PreJoin> {
  late bool cam = widget.video; bool mic = true;
  List<MediaDevice> mics = [], cams = [], speakers = [];
  String? micId, camId, speakerId, err;
  LocalVideoTrack? preview;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final d = await Hardware.instance.enumerateDevices();
      mics = d.where((x) => x.kind == 'audioinput').toList();
      cams = d.where((x) => x.kind == 'videoinput').toList();
      speakers = d.where((x) => x.kind == 'audiooutput').toList();
      micId ??= mics.firstOrNull?.deviceId; camId ??= cams.firstOrNull?.deviceId; speakerId ??= speakers.firstOrNull?.deviceId;
      if (cams.isEmpty) cam = false;
    } catch (e) { err = 'Could not list your devices: $e'; }
    if (mounted) setState(() {});
    await _preview();
  }
  Future<void> _preview() async {
    await preview?.stop(); preview = null;
    if (cam && camId != null) {
      try { preview = await LocalVideoTrack.createCameraTrack(CameraCaptureOptions(deviceId: camId)); }
      catch (e) { err = 'Camera not available: ${'$e'.split('\n').first}'; cam = false; }
    }
    if (mounted) setState(() {});
  }
  @override void dispose() { preview?.stop(); super.dispose(); }

  Widget _pick(String label, IconData icon, List<MediaDevice> ds, String? v, ValueChanged<String?> on) => ds.isEmpty
      ? ListTile(dense: true, leading: Icon(icon), title: Text('$label: none found'))
      : ListTile(dense: true, leading: Icon(icon), title: DropdownButton<String>(isExpanded: true, value: v, underline: const SizedBox(),
          items: [for (final d in ds) DropdownMenuItem(value: d.deviceId, child: Text(d.label.isEmpty ? label : d.label, overflow: TextOverflow.ellipsis))],
          onChanged: on));

  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Scaffold(appBar: AppBar(title: Text(widget.title)), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(padding: const EdgeInsets.all(16), children: [
      AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Container(color: cs.surfaceContainerHighest,
        child: preview != null && cam ? VideoTrackRenderer(preview!, mirrorMode: VideoViewMirrorMode.mirror)
          : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.videocam_off, size: 40, color: cs.outline), const SizedBox(height: 6), Text(cams.isEmpty ? 'No camera found' : 'Camera is off')]))))),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        FilterChip(avatar: Icon(mic ? Icons.mic : Icons.mic_off, size: 18), label: Text(mic ? 'Microphone on' : 'Microphone off'), selected: mic, onSelected: mics.isEmpty ? null : (v) => setState(() => mic = v)),
        const SizedBox(width: 8),
        FilterChip(avatar: Icon(cam ? Icons.videocam : Icons.videocam_off, size: 18), label: Text(cam ? 'Camera on' : 'Camera off'), selected: cam, onSelected: cams.isEmpty ? null : (v) { cam = v; _preview(); }),
      ]),
      if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: TextStyle(color: cs.error), textAlign: TextAlign.center)),
      const SizedBox(height: 8),
      _pick('Microphone', Icons.mic_none, mics, micId, (v) => setState(() => micId = v)),
      _pick('Camera', Icons.videocam_outlined, cams, camId, (v) { camId = v; _preview(); }),
      _pick('Speaker', Icons.volume_up_outlined, speakers, speakerId, (v) => setState(() => speakerId = v)),
      const SizedBox(height: 8),
      Row(children: const [Icon(Icons.lock, size: 16, color: Colors.green), SizedBox(width: 6), Expanded(child: Text('End-to-end encrypted with quantum-safe keys. Your preview stays on this device until you join.'))]),
      const SizedBox(height: 16),
      FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), icon: const Icon(Icons.login), label: Text(L.t(context, 'Join now')),
        onPressed: () async { await preview?.stop(); preview = null; if (c.mounted) Navigator.pop(c, PreJoinChoice(mic: mic, cam: cam, micId: micId, camId: camId, speakerId: speakerId)); }),
    ]))));
  }
}
