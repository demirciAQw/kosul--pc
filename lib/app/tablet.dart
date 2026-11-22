import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/question_bank/question_bank_providers.dart';
import 'platform.dart';
import 'routes.dart';

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
enum RailItem { kitaplik, defterler, notlar, soruDefteri, daha, ayarlar }

/// Dar sol gezinme rayı: Kitaplık, Defterler, Notlar, Soru defteri, Daha fazla
/// (Bugün, Kitaplar, Deneme, Analiz) ve en altta Ayarlar.
class TabletRail extends StatelessWidget {
  const TabletRail({super.key, required this.selected, required this.due});
  final RailItem? selected;
  final int due;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget item(
      RailItem id,
      IconData icon,
      IconData on,
      String label,
      VoidCallback onTap, {
      int badge = 0,
    }) {
      final sel = selected == id;
      return Semantics(
        selected: sel,
        button: true,
        label: label,
        child: InkWell(
          key: Key('rail-${id.name}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            width: 72,
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
                    child: Icon(sel ? on : icon, size: 22),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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

    final more = PopupMenuButton<String>(
      key: const Key('rail-daha-menu'),
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (path) => context.go(path),
      itemBuilder: (_) => const [
        PopupMenuItem(
          key: Key('rail-more-home'),
          value: AppRoutes.home,
          child: Text('Bugün'),
        ),
        PopupMenuItem(
          key: Key('rail-more-books'),
          value: AppRoutes.books,
          child: Text('Kitaplar'),
        ),
        PopupMenuItem(
          key: Key('rail-more-mock'),
          value: AppRoutes.mockExams,
          child: Text('Deneme'),
        ),
        PopupMenuItem(
          key: Key('rail-more-insights'),
          value: AppRoutes.insights,
          child: Text('Analiz'),
        ),
      ],
      child: IgnorePointer(
        child: item(
          RailItem.daha,
          Icons.more_horiz,
          Icons.more_horiz,
          'Daha fazla',
          () {},
        ),
      ),
    );

    return Material(
      color: cs.surfaceContainerLow,
      child: SizedBox(
        key: const Key('tablet-rail'),
        width: 80,
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              item(
                RailItem.kitaplik,
                Icons.picture_as_pdf_outlined,
                Icons.picture_as_pdf,
                'Kitaplık',
                () => context.go(AppRoutes.pdfLibrary),
              ),
              item(
                RailItem.defterler,
                Icons.edit_note_outlined,
                Icons.edit_note,
                'Defterler',
                () => context.go(AppRoutes.notebooks),
              ),
              item(
                RailItem.notlar,
                Icons.bolt_outlined,
                Icons.bolt_rounded,
                'Notlar',
                () => context.go(AppRoutes.anlikTab),
              ),
              item(
                RailItem.soruDefteri,
                Icons.collections_bookmark_outlined,
                Icons.collections_bookmark_rounded,
                'Soru defteri',
                () => context.go(AppRoutes.notebook),
                badge: due,
              ),
              more,
              const Spacer(),
              item(
                RailItem.ayarlar,
                Icons.settings_outlined,
                Icons.settings,
                'Ayarlar',
                () => context.push(AppRoutes.settings),
              ),
              const SizedBox(height: 8),
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
