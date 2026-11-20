import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../routes.dart';

/// Sekme ekranlarının sol üstündeki logo: basınca ana ekrana (eski "Bugün") döner.
/// AppBar'da `leading: const HomeLogoButton(), leadingWidth: HomeLogoButton.width` olarak kullanılır.
class HomeLogoButton extends StatelessWidget {
  const HomeLogoButton({super.key});

  static const double width = 64;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Ana ekran',
      child: InkWell(
        key: const Key('home-logo'),
        customBorder: const CircleBorder(),
        onTap: () => context.go(AppRoutes.home),
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/icon/logo.png', width: 32, height: 32),
          ),
        ),
      ),
    );
  }
}
