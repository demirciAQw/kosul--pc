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
      // Yerel görünüm yalnız KALEM (ve fare) olaylarını alır; parmak, "yalnız kalem"
      // açıkken Flutter'da kalır (üstteki InkViewport kaydırır/yakınlaştırır).
      // Fabrika bir kez çağrılır; bu yüzden kip her dokunuşta denetleyiciden okunur.
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(
          () => InkEagerRecognizer(
            touchAllowed: () => !widget.controller.stylusOnly,
          ),
        ),
      },
    );
  }
}

/// Hemen kazanan tanıyıcı; [touchAllowed] false iken parmak dokunuşlarını ALMAZ
/// (yerel görünüme hiç iletilmez, Flutter'daki kaydırma/yakınlaştırma çalışır).
class InkEagerRecognizer extends EagerGestureRecognizer {
  InkEagerRecognizer({required this.touchAllowed});

  final bool Function() touchAllowed;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch && !touchAllowed()) return false;
    return super.isPointerAllowed(event);
  }
}
