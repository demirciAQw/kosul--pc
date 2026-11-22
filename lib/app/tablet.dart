import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/question_bank/question_bank_providers.dart';
import 'platform.dart';
import 'routes.dart';
import 'tablet_menu.dart';
import 'tablet_menu_prefs.dart';

/// Tablet eşiği (dp): kısa kenar bu değer ya da üstündeyse tablet düzeni.
/// Katlanabilirin açık iç ekranı (~670 dp) tablet sayılır, kapalı dış ekranı
/// (~360 dp) ve telefonlar sayılmaz. Casper PAD H10 (2560x1600) en az ~800 dp
/// kısa kenar verir.
const double kTabletShortestSide = 600;

/// Araç çubuğunun "…" menüsüne daraldığı genişlik (dp); tablet dikeyi.
const double kToolbarCompactWidth = 900;

/// Saf karar: Android ve kısa kenar >= 600 dp. Yön (yatay/dikey) fark etmez.
bool isTabletLayout(Size size, {required bool android}) =>
    android && size.shortestSide >= kTabletShortestSide;

/// Çerçeveli sayfaların üstüne başka sayfa açıldığını duyuran gözlemci
/// ([routerProvider] gözlemcilerine eklenir).
final RouteObserver<PageRoute<dynamic>> tabletRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Sistem çubuğu kipi çağrısı; testte yerine konur.
@visibleForTesting
Future<void> Function(SystemUiMode mode) systemUiModeSetter =
    SystemChrome.setEnabledSystemUIMode;

/// Testte Android'i taklit eder (yalnızca testler kurar).
@visibleForTesting
bool? debugAndroidOverride;

/// Bu ekranda tablet düzeni mi (MediaQuery boyutu + platform).
bool isTabletContext(BuildContext context) => isTabletLayout(
  MediaQuery.sizeOf(context),
  android: debugAndroidOverride ?? isAndroid,
);

/// Odak (tam ekran çizim) durumu; çerçeve içinde [TabletFrame] sağlar.
class TabletFocus extends InheritedNotifier<ValueNotifier<bool>> {
  const TabletFocus({
    super.key,
    required ValueNotifier<bool> focus,
    required super.child,
  }) : super(notifier: focus);

  /// Çerçeve yoksa (telefon) null.
  static ValueNotifier<bool>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabletFocus>()?.notifier;
}

/// Okuyucu ve sayfa editörü çubuğundaki odak düğmesi: tek dokunuş rayı gizler,
/// aynı düğme geri getirir. Telefonda ya da çerçevesiz ekranda görünmez.
class FocusModeButton extends StatelessWidget {
  const FocusModeButton({super.key});

  @override
  Widget build(BuildContext context) {
    final focus = TabletFocus.maybeOf(context);
    if (focus == null) return const SizedBox.shrink();
    final on = focus.value;
    return IconButton(
      key: const Key('focus-mode'),
      tooltip: on ? 'Odaktan çık' : 'Odak modu',
      icon: Icon(on ? Icons.fullscreen_exit : Icons.fullscreen),
      onPressed: () => focus.value = !on,
    );
  }
}

/// Rayda seçili olabilecek hedefler.
enum RailItem { kitaplik, defterler, notlar, soruDefteri, diger, ayarlar }

/// Genişletilmiş menü ve dar ikon rayı genişlikleri (dp).
const double kTabletMenuWidth = 232;
const double kTabletRailWidth = 96;

/// Menü girişinin hangi [RailItem] ile eşleştiği (çerçeve `selected` verir).
const _entryRail = {
  'pdf': RailItem.kitaplik,
  'notebooks': RailItem.defterler,
  'anlik': RailItem.notlar,
  'notebook': RailItem.soruDefteri,
  'settings': RailItem.ayarlar,
};

/// Dar rayda kısa etiketler (96 dp'ye sığsın).
const _railLabels = {
  'pdf': 'Kitaplık',
  'anlik': 'Notlar',
  'insights': 'Analiz',
  'settings': 'Ayarlar',
};

/// Sol gezinme: varsayılan kalıcı, kaydırılabilir gruplu menü (232 dp: bütün
/// hedefler, ikon + ad); "daralt" ile dar ikon rayı (96 dp: sık kullanılan
/// hedefler + genişlet düğmesi). Ayarlar altta sabit. [onShell]: menü ana
/// kabukta mı (rotası kabuk dışı sayfalar `push` ile açılır).
class TabletRail extends ConsumerWidget {
  const TabletRail({
    super.key,
    required this.selected,
    required this.due,
    this.onShell = false,
  });
  final RailItem? selected;
  final int due;
  final bool onShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final narrow = ref.watch(tabletMenuNarrowProvider);
    final listenable = tabletRouteListenable(context);

    bool isSel(MenuEntry e, String here) {
      if (e.route != null && e.route == here) return true;
      final r = _entryRail[e.id];
      return r != null && r == selected;
    }

    void go(MenuEntry e) {
      if (e.id == 'settings' && selected == RailItem.ayarlar) return;
      openMenuEntry(context, ref, e, onShell: onShell);
    }

    Widget body(String here) {
      final settings = tabletMenuSettings;
      return Column(
        children: [
          narrow ? _railTop(context, ref) : _menuTop(context, ref),
          Expanded(
            child: narrow
                ? SingleChildScrollView(
                    key: const Key('rail-scroll'),
                    child: Column(
                      children: [
                        for (final id in tabletRailIds)
                          _railButton(
                            context,
                            tabletMenuEntry(id),
                            isSel(tabletMenuEntry(id), here),
                            () => go(tabletMenuEntry(id)),
                            badge: id == 'notebook' ? due : 0,
                          ),
                      ],
                    ),
                  )
                : ListView(
                    key: const Key('menu-scroll'),
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    children: [
                      for (final g in tabletMenuGroups) ...[
                        Padding(
                          key: Key('menu-group-${g.title}'),
                          padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
                          child: Text(
                            g.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: cs.primary),
                          ),
                        ),
                        for (final e in g.entries)
                          _menuTile(
                            context,
                            e,
                            isSel(e, here),
                            () => go(e),
                            badge: e.id == 'notebook' ? due : 0,
                          ),
                      ],
                    ],
                  ),
          ),
          if (narrow)
            _railButton(
              context,
              settings,
              isSel(settings, here),
              () => go(settings),
              key: const Key('rail-settings'),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
              child: _menuTile(
                context,
                settings,
                isSel(settings, here),
                () => go(settings),
              ),
            ),
          const SizedBox(height: 8),
        ],
      );
    }

    return Material(
      color: cs.surfaceContainerLow,
      child: SizedBox(
        key: const Key('tablet-rail'),
        width: narrow ? kTabletRailWidth : kTabletMenuWidth,
        child: SafeArea(
          right: false,
          child: listenable == null
              ? body('')
              : ListenableBuilder(
                  listenable: listenable,
                  builder: (context, _) => body(tabletCurrentPath(context)),
                ),
        ),
      ),
    );
  }

  Widget _menuTop(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Icon(Icons.school_rounded, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Koçum',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              key: const Key('menu-collapse'),
              tooltip: 'Menüyü daralt',
              icon: const Icon(Icons.chevron_left),
              onPressed: () =>
                  ref.read(tabletMenuNarrowProvider.notifier).set(true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _railTop(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 56,
      child: Center(
        child: IconButton(
          key: const Key('menu-expand'),
          tooltip: 'Menüyü genişlet',
          icon: const Icon(Icons.menu),
          onPressed: () =>
              ref.read(tabletMenuNarrowProvider.notifier).set(false),
        ),
      ),
    );
  }

  Widget _menuTile(
    BuildContext context,
    MenuEntry e,
    bool sel,
    VoidCallback onTap, {
    int badge = 0,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      selected: sel,
      button: true,
      label: e.label,
      excludeSemantics: true,
      child: Padding(
        key: Key('menu-${e.id}'),
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: sel ? cs.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Badge.count(
                      count: badge,
                      isLabelVisible: badge > 0,
                      child: Icon(
                        e.icon,
                        size: 22,
                        color: sel
                            ? cs.onSecondaryContainer
                            : cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        e.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: sel ? cs.onSecondaryContainer : cs.onSurface,
                          fontWeight: sel ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _railButton(
    BuildContext context,
    MenuEntry e,
    bool sel,
    VoidCallback onTap, {
    int badge = 0,
    Key? key,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      selected: sel,
      button: true,
      label: e.label,
      child: InkWell(
        key: key ?? Key('rail-${e.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          width: 88,
          height: 60,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: sel ? cs.secondaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Badge.count(
                  count: badge,
                  isLabelVisible: badge > 0,
                  child: Icon(e.icon, size: 22),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _railLabels[e.id] ?? e.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: sel ? cs.onSurface : cs.onSurfaceVariant,
                  fontWeight: sel ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tam ekran sayfaları (Kitaplık, Defterler, okuyucu, sayfa editörü) tablette
/// rayla çevreler; telefonda [child] aynen döner. Odak modunda ray gizlenir ve
/// sistem çubukları kalkar (dokunulursa kısa süre görünür, sonra gizlenir).
class TabletFrame extends ConsumerStatefulWidget {
  const TabletFrame({super.key, required this.selected, required this.child});
  final RailItem selected;
  final Widget child;

  @override
  ConsumerState<TabletFrame> createState() => _TabletFrameState();
}

class _TabletFrameState extends ConsumerState<TabletFrame> with RouteAware {
  final _focus = ValueNotifier<bool>(false);
  // Telefon↔tablet geçişinde (bölünmüş ekran, katlanabilir) çocuğun State'i
  // (kaydırma, araç, geri al yığını, çizgi) kaybolmasın: aynı anahtarla taşınır.
  final _childKey = GlobalKey();
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_applyChrome);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute && route != _route) {
      tabletRouteObserver.unsubscribe(this);
      _route = route;
      tabletRouteObserver.subscribe(this, route);
    }
  }

  // Üstüne çerçevesiz bir sayfa açılınca odak kapanır: orada çıkış düğmesi yok.
  @override
  void didPushNext() => _leaveFocus();

  void _leaveFocus() {
    if (!_focus.value) return;
    systemUiModeSetter(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.value = false;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _applyChrome() {
    systemUiModeSetter(
      _focus.value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    tabletRouteObserver.unsubscribe(this);
    if (_focus.value) {
      systemUiModeSetter(SystemUiMode.edgeToEdge);
    }
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    if (!isTabletContext(context)) {
      // Tablet eşiğinin altına inildi: odak açıksa kapat, çubukları geri getir.
      if (_focus.value) _leaveFocus();
      return child;
    }
    final due = ref.watch(dueCountProvider).value ?? 0;
    // Yığında tek sayfa (ray `go` ile açtı) iken geri tuşu uygulamayı
    // kapatmasın: ana sayfaya git. Telefonun `push` akışı etkilenmez.
    final canPop = Navigator.of(context).canPop();
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(AppRoutes.home);
      },
      child: TabletFocus(
        focus: _focus,
        child: Row(
          children: [
            if (!_focus.value) ...[
              TabletRail(selected: widget.selected, due: due),
              const VerticalDivider(width: 1),
            ],
            // İçerik sistem çubuğunun (görev çubuğu/gezinme) altına girmesin:
            // kenardan kenara çizimde alt boşluk burada bırakılır, ray da böyle.
            Expanded(
              child: SafeArea(
                top: false,
                left: false,
                right: false,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
