import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/question_bank/question_bank_providers.dart';
import 'tablet.dart';

/// Alt gezinme çubuğu: Anlık, Kitaplar, Defter, Deneme, Analiz.
/// Ana ekran (eski "Bugün") çubukta değil: sekmelerdeki logoya basınca açılır.
/// Araçlar, Ayarlar'dan açılır. Planlar ve oturum geçmişi ana ekrandan.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  /// Dal 0 ana ekran; çubuktaki sekme `i`, dal `i + 1`.
  static const _homeBranch = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(dueCountProvider).value ?? 0;
    final onHome = shell.currentIndex == _homeBranch;
    final theme = Theme.of(context);

    // Tablet: alt çubuk yerine sol ray (telefon düzeni aşağıda, aynen).
    if (isTabletContext(context)) {
      // Dallar: 0 Bugün, 1 Anlık (Notlar), 2 Kitaplar, 3 Soru defteri, 4 Deneme, 5 Analiz.
      final selected = switch (shell.currentIndex) {
        1 => RailItem.notlar,
        3 => RailItem.soruDefteri,
        _ => RailItem.diger,
      };
      return Scaffold(
        body: Row(
          children: [
            TabletRail(selected: selected, due: due, onShell: true),
            const VerticalDivider(width: 1),
            Expanded(child: shell),
          ],
        ),
      );
    }

    Widget badge(IconData icon) =>
        Badge.count(count: due, isLabelVisible: due > 0, child: Icon(icon));

    // Ana ekrandayken çubukta seçili sekme olmaz.
    NavigationDestination dest(IconData icon, IconData selected, String label, {Widget? iconWidget, Widget? selectedWidget}) =>
        NavigationDestination(
          icon: iconWidget ?? Icon(icon),
          selectedIcon: onHome ? (iconWidget ?? Icon(icon)) : (selectedWidget ?? Icon(selected)),
          label: label,
        );

    final bar = NavigationBar(
      selectedIndex: onHome ? 0 : shell.currentIndex - 1,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      onDestinationSelected: (i) => shell.goBranch(i + 1, initialLocation: i + 1 == shell.currentIndex),
      destinations: [
        dest(Icons.bolt_outlined, Icons.bolt_rounded, 'Anlık'),
        dest(Icons.menu_book_outlined, Icons.menu_book_rounded, 'Kitaplar'),
        dest(Icons.collections_bookmark_outlined, Icons.collections_bookmark_rounded, 'Defter',
            iconWidget: badge(Icons.collections_bookmark_outlined),
            selectedWidget: badge(Icons.collections_bookmark_rounded)),
        dest(Icons.assignment_outlined, Icons.assignment_rounded, 'Deneme'),
        dest(Icons.insights_outlined, Icons.insights_rounded, 'Analiz'),
      ],
    );

    return Scaffold(
      body: shell,
      bottomNavigationBar: onHome
          ? NavigationBarTheme(
              data: NavigationBarTheme.of(context).copyWith(
                indicatorColor: Colors.transparent,
                labelTextStyle: WidgetStatePropertyAll(
                  theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              child: bar,
            )
          : bar,
    );
  }
}
