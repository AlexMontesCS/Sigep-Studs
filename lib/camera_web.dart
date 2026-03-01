// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

Future<XFile?> captureWebPhoto(BuildContext context) async {
  html.MediaStream? stream;
  try {
    stream = await html.window.navigator.mediaDevices!.getUserMedia({
      'video': {'facingMode': 'environment'},
      'audio': false,
    });
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not access camera')),
      );
    }
    return null;
  }

  final videoElement = html.VideoElement()
    ..autoplay = true
    ..muted = true
    ..srcObject = stream
    ..setAttribute('playsinline', '');

  final viewId = 'cam-${DateTime.now().millisecondsSinceEpoch}';
  ui_web.platformViewRegistry.registerViewFactory(viewId, (_) => videoElement);

  XFile? result;
  if (context.mounted) {
    result = await showDialog<XFile?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _CameraDialog(
        videoElement: videoElement,
        viewId: viewId,
      ),
    );
  }

  for (final t in stream.getTracks()) {
    t.stop();
  }
  return result;
}

class _CameraDialog extends StatefulWidget {
  final html.VideoElement videoElement;
  final String viewId;

  const _CameraDialog({required this.videoElement, required this.viewId});

  @override
  State<_CameraDialog> createState() => _CameraDialogState();
}

class _CameraDialogState extends State<_CameraDialog> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.videoElement.onCanPlay.first.then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  void _capture() {
    final w = widget.videoElement.videoWidth;
    final h = widget.videoElement.videoHeight;
    if (w == 0 || h == 0) return;
    final canvas = html.CanvasElement(width: w, height: h);
    canvas.context2D.drawImage(widget.videoElement, 0, 0);
    final dataUrl = canvas.toDataUrl('image/jpeg', 0.85);
    final bytes = base64.decode(dataUrl.split(',')[1]);
    Navigator.pop(
      context,
      XFile.fromData(
        bytes,
        mimeType: 'image/jpeg',
        name: 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Take Photo',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: 320,
              height: 240,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  HtmlElementView(viewType: widget.viewId),
                  if (!_ready) const CircularProgressIndicator(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: _ready ? _capture : null,
                  child: const Text('Capture'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
