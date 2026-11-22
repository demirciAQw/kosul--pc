import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../desktop_providers.dart';
import '../today/today_page.dart';
import '../anlik/notes_page.dart';
import '../anlik/people_page.dart';
import '../../features/ledger/presentation/ledger_views.dart';
import '../analysis/analysis_page.dart';
import '../entry/books_page.dart';
import '../entry/exams_page.dart';
import '../entry/optic_page.dart';
import '../entry/plans_page.dart';
import '../entry/sessions_page.dart';
import '../../features/pdf/presentation/pdf_library_page.dart';
import '../../features/pdf/presentation/pdf_reader_page.dart';
import '../import/import_providers.dart';
import '../import/presentation/auto_import.dart';
import '../import/presentation/import_flow.dart';
import '../notebook/notebook_page.dart';
import '../settings/desktop_settings_page.dart';
import '../sync/wireless_controller.dart';
import '../widgets/desktop_page.dart';

/// Geniş ekran düzeni: solda kalıcı gezinme, sağda seçili bölüm.
class DesktopShell extends ConsumerWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(desktopSectionProvider);
    // İzlenen klasör ve (açıksa) kablosuz alma uygulama açıldığı andan
    // itibaren dinlenir.
    ref.watch(autoImportProvider);
    // Başka bir süreç (kocum aracı) veriyi değiştirirse ekranlar yenilenir.
    ref.watch(externalChangeWatcherProvider);
    // Kablosuz almanın her olayında (ör. her fotoğraf) kabuk yeniden
    // çizilmesin: yalnızca canlı tutulur.
    ref.listen(wirelessProvider, (previous, next) {});
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Gezinme ve altında içe aktarma durumu.
          ColoredBox(
            color: theme.navigationRailTheme.backgroundColor ?? theme.colorScheme.surface,
            child: Column(
              children: [
                Expanded(
                  child: NavigationRail(
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
                ),
                const _ImportStatus(),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _page(section)),
        ],
      ),
    );
  }
}

Widget _page(DesktopSection section) => switch (section) {
      DesktopSection.today => const DesktopTodayPage(),
      DesktopSection.notebook => const NotebookPage(),
      DesktopSection.books => const DesktopBooksPage(),
      DesktopSection.optic => const DesktopOpticPage(),
      DesktopSection.exams => const DesktopExamsPage(),
      DesktopSection.sessions => const DesktopSessionsPage(),
      DesktopSection.analysis => const DesktopAnalysisPage(),
      DesktopSection.plans => const DesktopPlansPage(),
      DesktopSection.notes => const DesktopNotesPage(),
      DesktopSection.people => const DesktopPeoplePage(),
      DesktopSection.tags => const DesktopTagsPage(),
      DesktopSection.changes => const DesktopPage(title: 'Claude\'un değişiklikleri', subtitle: 'Oturum oturum; geri alınabilir', child: ClaudeChangesView()),
      DesktopSection.conflicts => const DesktopPage(title: 'Çakışmalar', subtitle: 'Telefonla bilgisayarın ikisinde de değişen satırlar', child: ConflictsView()),
      DesktopSection.pdf => DesktopPage(
          title: 'PDF\'ler',
          subtitle: 'İçe aktar, oku, kalemle yaz',
          child: Builder(
            builder: (context) => PdfLibraryPage(
              embedded: true,
              onOpen: (context, d) => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => PdfReaderPage(documentId: d.id))),
            ),
          ),
        ),
      DesktopSection.settings => const DesktopSettingsPage(),
    };

/// Gezinmenin altında: süren içe aktarma ya da son içe aktarmanın tarihi.
class _ImportStatus extends ConsumerWidget {
  const _ImportStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = ref.watch(importBusyProvider);
    final last = ref.watch(importHistoryProvider).value?.firstOrNull;
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 192,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
          child: busy != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 6),
                    Text(busy, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ],
                )
              : Text(
                  last == null ? 'Telefon verisi yok.\nAyarlar → Telefondan veri al' : 'Son veri: ${formatShortDate(last.at)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
        ),
      ),
    );
  }
}
