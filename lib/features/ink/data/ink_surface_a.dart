import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/ink_channel_codec.dart';
import 'ink_a_controller.dart';

/// A uygulaması: Android yerel çizim yüzeyi (PlatformView). Yalnızca Android'de
/// kullanılır; çağıran yer platformu denetler (`lib/app/platform.dart`).
class InkSurfaceAView extends StatefulWidget {
  const InkSurfaceAView({super.key, required this.controller});

  final InkAController controller;

  @override
  State<InkSurfaceAView> createState() => _InkSurfaceAViewState();
}

class _InkSurfaceAViewState extends State<InkSurfaceAView> {
  @override
  void dispose() {
    widget.controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      viewType: inkViewType,
      creationParams: encodeBrush(widget.controller.brush),
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: widget.controller.attach,
      // Dokunuşları yerel görünüm alsın (kalem/parmak ayrımını o yapar).
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
    );
  }
}
