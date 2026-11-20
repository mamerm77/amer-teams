import 'dart:io';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

/// Plays an end-to-end encrypted video: decrypted on this device into a temporary file that is deleted when the
/// player closes (docs/TEAMS_APPS.md, Stream).
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.event}); final Event event;
  @override State<VideoPlayerScreen> createState() => _S();
}
class _S extends State<VideoPlayerScreen> {
  late final player = Player(); late final ctl = VideoController(player); File? tmp; String? err;
  @override void initState() { super.initState(); _open(); }
  Future<void> _open() async {
    try {
      final f = await widget.event.downloadAndDecryptAttachment();
      final dir = await getTemporaryDirectory();
      tmp = File('${dir.path}/amer-play-${DateTime.now().microsecondsSinceEpoch}-${f.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}');
      await tmp!.writeAsBytes(f.bytes, flush: true);
      await player.open(Media(tmp!.path));
    } catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  @override void dispose() { player.dispose(); try { tmp?.deleteSync(); } catch (_) {} super.dispose(); }
  @override Widget build(BuildContext c) => Scaffold(backgroundColor: Colors.black,
    appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(widget.event.body, style: const TextStyle(fontSize: 15))),
    body: err != null ? Center(child: Text('Could not play: $err', style: const TextStyle(color: Colors.white)))
        : Video(controller: ctl));
}
