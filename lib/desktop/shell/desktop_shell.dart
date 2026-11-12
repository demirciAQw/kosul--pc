import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop_providers.dart';
import '../widgets/desktop_page.dart';

/// Geniş ekran düzeni: solda kalıcı gezinme, sağda seçili bölüm.
class DesktopShell extends ConsumerWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(desktopSectionProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NavigationRail(
            extended: true,
            minExtendedWidth: 208,
            selectedIndex: section.index,
            onDestinationSelected: (i) =>
                ref.read(desktopSectionProvider.notifier).select(DesktopSection.values[i]),
            leading: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 20),
              child: Text('Koçum', style: theme.textTheme.titleLarge),
            ),
            destinations: [
              for (final s in DesktopSection.values)
                NavigationRailDestination(
                  icon: Icon(s.icon),
                  selectedIcon: Icon(s.selectedIcon),
                  label: Text(s.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _page(section)),
        ],
      ),
    );
  }
}

Widget _page(DesktopSection section) => switch (section) {
      DesktopSection.notebook => DesktopPlaceholder(title: section.label, icon: section.icon),
      DesktopSection.books => DesktopPlaceholder(title: section.label, icon: section.icon),
      DesktopSection.exams => DesktopPlaceholder(title: section.label, icon: section.icon),
      DesktopSection.sessions => DesktopPlaceholder(title: section.label, icon: section.icon),
      DesktopSection.analysis => DesktopPlaceholder(title: section.label, icon: section.icon),
      DesktopSection.plans => DesktopPlaceholder(title: section.label, icon: section.icon),
      DesktopSection.notes => DesktopPlaceholder(title: section.label, icon: section.icon),
      DesktopSection.settings => DesktopPlaceholder(title: section.label, icon: section.icon),
    };
