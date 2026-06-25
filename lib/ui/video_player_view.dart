import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/media_asset.dart';
import '../services/media_service.dart';
import 'widgets/shimmers.dart';

final _media = MediaService();

/// Full-featured in-app video playback via Chewie: play/pause, scrub bar,
/// fullscreen (resize), playback speed, and mute. Freed videos show their
/// thumbnail with a note.
class VideoPlayerView extends StatefulWidget {
  const VideoPlayerView({super.key, required this.asset});
  final MediaAsset asset;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  bool _initializing = true;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    File? file;
    final a = widget.asset;
    if (a.isFileAsset && a.localPath != null) {
      file = File(a.localPath!);
    } else {
      final entity = await _media.entity(a.id);
      file = await entity?.file;
    }
    if (file == null || !await file.exists()) {
      setState(() {
        _unavailable = true;
        _initializing = false;
      });
      return;
    }
    final v = VideoPlayerController.file(file);
    try {
      await v.initialize();
      final c = ChewieController(
        videoPlayerController: v,
        autoPlay: true,
        looping: false,
        allowFullScreen: true, // fullscreen toggle = resize
        allowMuting: true,
        allowPlaybackSpeedChanging: true,
        showControls: true,
        aspectRatio: v.value.aspectRatio,
        materialProgressColors: ChewieProgressColors(
          playedColor: const Color(0xFF7C5CFF),
          handleColor: const Color(0xFF7C5CFF),
          bufferedColor: Colors.white24,
          backgroundColor: Colors.white12,
        ),
      );
      setState(() {
        _video = v;
        _chewie = c;
        _initializing = false;
      });
    } catch (_) {
      setState(() {
        _unavailable = true;
        _initializing = false;
      });
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: ShimmerBox(height: 240, radius: 18),
      );
    }
    if (_unavailable || _chewie == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_outlined, color: Colors.white54, size: 56),
            SizedBox(height: 12),
            Text('Video freed from device — download to play',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return Chewie(controller: _chewie!);
  }
}
