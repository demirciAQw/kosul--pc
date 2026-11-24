import 'dart:io';

import 'package:flutter/material.dart';

import '../domain/page_board.dart';

/// Sayfadaki görsel. Çözülmüş boyutla ([ResizeImage]) Flutter'ın görsel önbelleğinden
/// (LRU, bellek sınırlı) gelir: büyük sayfada çok görsel olsa da tam çözünürlük hep
/// bellekte durmaz. [highRes]: yakınlaştırılınca daha yüksek çözünürlük (en çok 2048).
class ImageItemView extends StatelessWidget {
  const ImageItemView({
    super.key,
    required this.file,
    required this.payload,
    this.highRes = false,
  });
  final File file;
  final ImageItemPayload payload;
  final bool highRes;

  /// Normal ve yakın çözünürlük (piksel, en uzun kenar için genişlik/yükseklikten biri).
  static const normalSide = 1024;
  static const highSide = 2048;

  @override
  Widget build(BuildContext context) {
    final side = highRes ? highSide : normalSide;
    final landscape = payload.pxW >= payload.pxH;
    final big = (landscape ? payload.pxW : payload.pxH) > side;
    final ImageProvider base = FileImage(file);
    final provider = !big
        ? base
        : ResizeImage(base, width: landscape ? side : null, height: landscape ? null : side, allowUpscaling: false);
    return Opacity(
      opacity: payload.alpha.clamp(0.0, 1.0),
      child: Image(
        image: provider,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, _, _) => Container(
          key: const Key('note-image-broken'),
          color: Theme.of(context).colorScheme.errorContainer,
          alignment: Alignment.center,
          child: Icon(Icons.broken_image_outlined, color: Theme.of(context).colorScheme.onErrorContainer),
        ),
      ),
    );
  }
}
