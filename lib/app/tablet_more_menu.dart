import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/mock_exam/presentation/karne_import_screen.dart';
import 'routes.dart';

/// Gezinme türü: kabuk dalına `go`; diğer sayfalara kabuktayken `push`,
/// başka bir çerçeveli sayfadayken `pushReplacement` (yığın şişmesin).
enum MoreNav { shell, frame, page }

/// "Daha fazla" menüsündeki bir hedef. [route] null ise [special] çalışır
/// (yalnızca rotası olmayan, dosya seçtirerek açılan akışlar).
class MoreEntry {
  const MoreEntry(
    this.id,
    this.label,
    this.icon,
    this.route, {
    this.nav = MoreNav.page,
    this.special,
  });
  final String id;
  final String label;
  final IconData icon;
  final String? route;
  final MoreNav nav;
  final Future<void> Function(BuildContext context, WidgetRef ref)? special;
}

class MoreGroup {
  const MoreGroup(this.title, this.entries);
  final String title;
  final List<MoreEntry> entries;
}

/// Telefon + bilgisayar uygulamasındaki tüm hedefler. Yeni bir rota
/// eklenince buraya da konmalı (`test/tablet_more_menu_test.dart` denetler).
final List<MoreGroup> tabletMoreGroups = [
  MoreGroup('Çalışma', [
    const MoreEntry(
      'home',
      'Bugün',
      Icons.today_outlined,
      AppRoutes.home,
      nav: MoreNav.shell,
    ),
    const MoreEntry(
      'new-session',
      'Yeni oturum',
      Icons.play_circle_outline,
      AppRoutes.newSession,
    ),
    const MoreEntry(
      'sessions',
      'Geçmiş oturumlar',
      Icons.history,
      AppRoutes.sessions,
    ),
    const MoreEntry(
      'plan',
      'Planlar',
      Icons.event_note_outlined,
      AppRoutes.plan,
    ),
    const MoreEntry(
      'new-plan',
      'Plan oluştur',
      Icons.edit_calendar_outlined,
      AppRoutes.newPlan,
    ),
  ]),
  MoreGroup('Sorular', [
    const MoreEntry(
      'notebook',
      'Soru defteri',
      Icons.collections_bookmark_outlined,
      AppRoutes.notebook,
      nav: MoreNav.shell,
    ),
    const MoreEntry(
      'new-question',
      'Soru ekle',
      Icons.add_a_photo_outlined,
      AppRoutes.newQuestion,
    ),
    const MoreEntry(
      'incomplete',
      'Eksik sorular',
      Icons.rule_outlined,
      AppRoutes.incompleteQuestions,
    ),
    const MoreEntry(
      'review',
      'Tekrar / yanlışlarım',
      Icons.replay_rounded,
      AppRoutes.review,
    ),
  ]),
  MoreGroup('Kitaplar ve denemeler', [
    const MoreEntry(
      'books',
      'Kitaplar',
      Icons.menu_book_outlined,
      AppRoutes.books,
      nav: MoreNav.shell,
    ),
    const MoreEntry(
      'mock',
      'Deneme',
      Icons.assignment_outlined,
      AppRoutes.mockExams,
      nav: MoreNav.shell,
    ),
    const MoreEntry(
      'new-mock',
      'Deneme ekle',
      Icons.note_add_outlined,
      AppRoutes.newMockExam,
    ),
    MoreEntry(
      'karne',
      'Karne içe aktar (PDF)',
      Icons.upload_file_outlined,
      null,
      special: (context, ref) => importKarneFlow(context, ref),
    ),
  ]),
  MoreGroup('Notlar', [
    const MoreEntry(
      'anlik',
      'Anlık notlar',
      Icons.bolt_outlined,
      AppRoutes.anlikTab,
      nav: MoreNav.shell,
    ),
    const MoreEntry(
      'new-anlik',
      'Yeni anlık not',
      Icons.bolt_rounded,
      AppRoutes.newAnlik,
    ),
    const MoreEntry(
      'new-note',
      'Yeni ders notu',
      Icons.sticky_note_2_outlined,
      AppRoutes.newNote,
    ),
    const MoreEntry('tags', 'Etiketler', Icons.sell_outlined, AppRoutes.tags),
    const MoreEntry(
      'people',
      'Kişiler',
      Icons.people_outline,
      AppRoutes.people,
    ),
  ]),
  MoreGroup('Analiz', [
    const MoreEntry(
      'insights',
      'Analiz / derin analiz',
      Icons.insights_outlined,
      AppRoutes.insights,
      nav: MoreNav.shell,
    ),
    const MoreEntry(
      'claude-report',
      'Claude raporu',
      Icons.smart_toy_outlined,
      AppRoutes.tools,
    ),
  ]),
  MoreGroup('Tablet', [
    const MoreEntry(
      'pdf',
      'PDF kitaplık',
      Icons.picture_as_pdf_outlined,
      AppRoutes.pdfLibrary,
      nav: MoreNav.frame,
    ),
    const MoreEntry(
      'notebooks',
      'Defterler',
      Icons.edit_note_outlined,
      AppRoutes.notebooks,
      nav: MoreNav.frame,
    ),
  ]),
  MoreGroup('Araçlar', [
    const MoreEntry(
      'tools',
      'Tüm araçlar',
      Icons.handyman_outlined,
      AppRoutes.tools,
    ),
    const MoreEntry(
      'practice-test',
      'Test çöz',
      Icons.quiz_outlined,
      AppRoutes.practiceTest,
    ),
    const MoreEntry(
      'computer',
      'Bilgisayarla eşitle',
      Icons.computer,
      AppRoutes.sendToComputer,
    ),
    const MoreEntry(
      'changes',
      'Claude\'un değişiklikleri',
      Icons.auto_fix_high_outlined,
      AppRoutes.claudeChanges,
    ),
    const MoreEntry(
      'conflicts',
      'Çakışmalar',
      Icons.merge_type_rounded,
      AppRoutes.conflicts,
    ),
    const MoreEntry(
      'ink-lab',
      'Kalem denemesi',
      Icons.edit_outlined,
      AppRoutes.inkLab,
    ),
  ]),
  MoreGroup('Ayarlar', [
    const MoreEntry(
      'settings',
      'Ayarlar',
      Icons.settings_outlined,
      AppRoutes.settings,
    ),
  ]),
];

/// Menüdeki tüm rotalar (test için).
Set<String> get tabletMenuRoutes => {
  for (final g in tabletMoreGroups)
    for (final e in g.entries)
      if (e.route != null) e.route!,
};

/// Girişe git. [onShell]: çağıran ray ana kabukta mı.
Future<void> openMoreEntry(
  BuildContext context,
  WidgetRef ref,
  MoreEntry e, {
  required bool onShell,
}) async {
  final route = e.route;
  if (route == null) return e.special?.call(context, ref);
  switch (e.nav) {
    case MoreNav.shell || MoreNav.frame:
      context.go(route);
    case MoreNav.page:
      if (onShell) {
        await context.push(route);
      } else {
        context.pushReplacement(route);
      }
  }
}

String _currentPath(BuildContext context) {
  try {
    return GoRouter.of(context).routeInformationProvider.value.uri.path;
  } catch (_) {
    return '';
  }
}

/// Rayın yanında açılan, kaydırılabilir gruplu menü paneli.
Future<void> showTabletMoreMenu(
  BuildContext context,
  WidgetRef ref, {
  required bool onShell,
}) {
  final here = _currentPath(context);
  final railWidth = MediaQuery.paddingOf(context).left + 96;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Menüyü kapat',
    barrierColor: Colors.black26,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, _, _) {
      final cs = Theme.of(dialogContext).colorScheme;
      final text = Theme.of(dialogContext).textTheme;
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.fromLTRB(railWidth + 8, 8, 8, 8),
          child: Material(
            key: const Key('rail-more-panel'),
            color: cs.surfaceContainerHigh,
            elevation: 6,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: 340,
              child: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    for (final g in tabletMoreGroups) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                        child: Text(
                          g.title,
                          style: text.labelLarge?.copyWith(color: cs.primary),
                        ),
                      ),
                      for (final e in g.entries)
                        ListTile(
                          key: Key('rail-more-${e.id}'),
                          dense: true,
                          minTileHeight: 48,
                          leading: Icon(e.icon),
                          title: Text(e.label),
                          selected: e.route != null && e.route == here,
                          selectedTileColor: cs.secondaryContainer,
                          onTap: () {
                            Navigator.of(dialogContext).pop();
                            openMoreEntry(context, ref, e, onShell: onShell);
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}
