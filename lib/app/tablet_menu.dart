import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/mock_exam/presentation/karne_import_screen.dart';
import 'routes.dart';

/// Gezinme türü: kabuk dalına `go`; diğer sayfalara kabuktayken `push`,
/// başka bir çerçeveli sayfadayken `pushReplacement` (yığın şişmesin).
enum MenuNav { shell, frame, page }

/// Sol menüdeki bir hedef. [route] null ise [special] çalışır
/// (yalnızca rotası olmayan, dosya seçtirerek açılan akışlar).
class MenuEntry {
  const MenuEntry(
    this.id,
    this.label,
    this.icon,
    this.route, {
    this.nav = MenuNav.page,
    this.special,
  });
  final String id;
  final String label;
  final IconData icon;
  final String? route;
  final MenuNav nav;
  final Future<void> Function(BuildContext context, WidgetRef ref)? special;
}

class MenuGroup {
  const MenuGroup(this.title, this.entries);
  final String title;
  final List<MenuEntry> entries;
}

/// Telefon + bilgisayar uygulamasındaki tüm hedefler. Yeni bir rota
/// eklenince buraya da konmalı (`test/tablet_menu_test.dart` denetler).
final List<MenuGroup> tabletMenuGroups = [
  MenuGroup('Çalışma', [
    const MenuEntry(
      'home',
      'Bugün',
      Icons.today_outlined,
      AppRoutes.home,
      nav: MenuNav.shell,
    ),
    const MenuEntry(
      'new-session',
      'Yeni oturum',
      Icons.play_circle_outline,
      AppRoutes.newSession,
    ),
    const MenuEntry(
      'sessions',
      'Geçmiş oturumlar',
      Icons.history,
      AppRoutes.sessions,
    ),
    const MenuEntry(
      'plan',
      'Planlar',
      Icons.event_note_outlined,
      AppRoutes.plan,
    ),
    const MenuEntry(
      'new-plan',
      'Plan oluştur',
      Icons.edit_calendar_outlined,
      AppRoutes.newPlan,
    ),
  ]),
  MenuGroup('Sorular', [
    const MenuEntry(
      'notebook',
      'Soru defteri',
      Icons.collections_bookmark_outlined,
      AppRoutes.notebook,
      nav: MenuNav.shell,
    ),
    const MenuEntry(
      'new-question',
      'Soru ekle',
      Icons.add_a_photo_outlined,
      AppRoutes.newQuestion,
    ),
    const MenuEntry(
      'incomplete',
      'Eksik sorular',
      Icons.rule_outlined,
      AppRoutes.incompleteQuestions,
    ),
    const MenuEntry(
      'review',
      'Tekrar / yanlışlarım',
      Icons.replay_rounded,
      AppRoutes.review,
    ),
  ]),
  MenuGroup('Kitaplar ve denemeler', [
    const MenuEntry(
      'books',
      'Kitaplar',
      Icons.menu_book_outlined,
      AppRoutes.books,
      nav: MenuNav.shell,
    ),
    const MenuEntry(
      'mock',
      'Deneme',
      Icons.assignment_outlined,
      AppRoutes.mockExams,
      nav: MenuNav.shell,
    ),
    const MenuEntry(
      'new-mock',
      'Deneme ekle',
      Icons.note_add_outlined,
      AppRoutes.newMockExam,
    ),
    MenuEntry(
      'karne',
      'Karne içe aktar (PDF)',
      Icons.upload_file_outlined,
      null,
      special: (context, ref) => importKarneFlow(context, ref),
    ),
  ]),
  MenuGroup('Notlar', [
    const MenuEntry(
      'anlik',
      'Anlık notlar',
      Icons.bolt_outlined,
      AppRoutes.anlikTab,
      nav: MenuNav.shell,
    ),
    const MenuEntry(
      'new-anlik',
      'Yeni anlık not',
      Icons.bolt_rounded,
      AppRoutes.newAnlik,
    ),
    const MenuEntry(
      'new-note',
      'Yeni ders notu',
      Icons.sticky_note_2_outlined,
      AppRoutes.newNote,
    ),
    const MenuEntry('tags', 'Etiketler', Icons.sell_outlined, AppRoutes.tags),
    const MenuEntry(
      'people',
      'Kişiler',
      Icons.people_outline,
      AppRoutes.people,
    ),
  ]),
  MenuGroup('Analiz', [
    const MenuEntry(
      'insights',
      'Analiz / derin analiz',
      Icons.insights_outlined,
      AppRoutes.insights,
      nav: MenuNav.shell,
    ),
    const MenuEntry(
      'claude-report',
      'Claude raporu',
      Icons.smart_toy_outlined,
      AppRoutes.tools,
    ),
  ]),
  MenuGroup('Tablet', [
    const MenuEntry(
      'pdf',
      'PDF kitaplık',
      Icons.picture_as_pdf_outlined,
      AppRoutes.pdfLibrary,
      nav: MenuNav.frame,
    ),
    const MenuEntry(
      'notebooks',
      'Defterler',
      Icons.edit_note_outlined,
      AppRoutes.notebooks,
      nav: MenuNav.frame,
    ),
  ]),
  MenuGroup('Araçlar', [
    const MenuEntry(
      'tools',
      'Tüm araçlar',
      Icons.handyman_outlined,
      AppRoutes.tools,
    ),
    const MenuEntry(
      'practice-test',
      'Test çöz',
      Icons.quiz_outlined,
      AppRoutes.practiceTest,
    ),
    const MenuEntry(
      'computer',
      'Bilgisayarla eşitle',
      Icons.computer,
      AppRoutes.sendToComputer,
    ),
    const MenuEntry(
      'changes',
      'Claude\'un değişiklikleri',
      Icons.auto_fix_high_outlined,
      AppRoutes.claudeChanges,
    ),
    const MenuEntry(
      'conflicts',
      'Çakışmalar',
      Icons.merge_type_rounded,
      AppRoutes.conflicts,
    ),
    const MenuEntry(
      'ink-lab',
      'Kalem denemesi',
      Icons.edit_outlined,
      AppRoutes.inkLab,
    ),
  ]),
];

/// Altta sabit duran Ayarlar girişi (gruplarda değil).
const tabletMenuSettings = MenuEntry(
  'settings',
  'Ayarlar',
  Icons.settings_outlined,
  AppRoutes.settings,
);

/// Daraltılmış ikon rayında kalan sık kullanılan hedefler (kimlikler).
const tabletRailIds = [
  'home',
  'pdf',
  'notebooks',
  'anlik',
  'notebook',
  'books',
  'mock',
  'insights',
];

/// Menüdeki tüm rotalar (test için).
Set<String> get tabletMenuRoutes => {
  if (tabletMenuSettings.route != null) tabletMenuSettings.route!,
  for (final g in tabletMenuGroups)
    for (final e in g.entries)
      if (e.route != null) e.route!,
};

/// Girişe git. [onShell]: çağıran menü ana kabukta mı.
Future<void> openMenuEntry(
  BuildContext context,
  WidgetRef ref,
  MenuEntry e, {
  required bool onShell,
}) async {
  final route = e.route;
  if (route == null) return e.special?.call(context, ref);
  switch (e.nav) {
    case MenuNav.shell || MenuNav.frame:
      context.go(route);
    case MenuNav.page:
      if (onShell) {
        await context.push(route);
      } else {
        context.pushReplacement(route);
      }
  }
}

/// Geçerli yol ve değişimini dinleyen [Listenable]; yönlendirici yoksa null.
Listenable? tabletRouteListenable(BuildContext context) {
  try {
    return GoRouter.of(context).routeInformationProvider;
  } catch (_) {
    return null;
  }
}

String tabletCurrentPath(BuildContext context) {
  try {
    return GoRouter.of(context).routeInformationProvider.value.uri.path;
  } catch (_) {
    return '';
  }
}

/// Kimlikle giriş (ray ve menü için).
MenuEntry tabletMenuEntry(String id) => [
  for (final g in tabletMenuGroups) ...g.entries,
  tabletMenuSettings,
].firstWhere((e) => e.id == id);
