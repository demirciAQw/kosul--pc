import 'package:flutter/material.dart';

import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../widgets/desktop_page.dart';

/// Analiz (bilgisayar): telefondaki analizlerin salt okunur görünümü. Derin
/// analiz, soru kökü analizi, örüntüler, en çok yanlış ve çalışma süresi aynı
/// sağlayıcılardan gelir; bu sayfada veri girilmez ya da değiştirilmez.
class DesktopAnalysisPage extends StatelessWidget {
  const DesktopAnalysisPage({super.key});

  @override
  Widget build(BuildContext context) => const DesktopPage(
        title: 'Analiz',
        subtitle: 'Yalnızca okunur',
        child: DashboardContent(maxWidth: 980),
      );
}
