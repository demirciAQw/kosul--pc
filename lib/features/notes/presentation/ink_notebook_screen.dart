import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/tablet.dart';
import '../../handwriting/handwriting_providers.dart';
import '../../handwriting/presentation/notebook_text_screen.dart';
import '../../handwriting/presentation/page_text_sheet.dart';
import '../../ink/data/ink_outline.dart';
import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../ink/domain/pen_profiles.dart';
import '../../pdf/pdf_providers.dart';
import '../data/ink_notebook_repository.dart';
import '../data/note_tool_prefs_store.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_size.dart';
import '../notes_providers.dart';
import 'ink_tags_panel.dart';
import 'note_page_editor.dart';
import 'note_tool_dock.dart';
import 'note_tool_settings.dart';
import 'page_template_painter.dart';

/// Defter içi: yan şeritte sayfa küçük resimleri, ortada sayfa düzenleyicisi.
/// Açılışta `ensureVisiblePage` çağrılır (senkronda tüm sayfalar silinmiş olabilir).
class InkNotebookScreen extends ConsumerStatefulWidget {
  const InkNotebookScreen({
    super.key,
    required this.notebookId,
    this.stylusOnlyOverride,
    this.initialPageId,
  });
  final String notebookId;

  /// Açılışta gösterilecek sayfa (el yazısı metin araması); geçersizse ilk sayfa.
  final String? initialPageId;

  /// Testte: parmak/fare davranışını sabitlemek için.
  final bool? stylusOnlyOverride;

  @override
  ConsumerState<InkNotebookScreen> createState() => _InkNotebookScreenState();
}

class _InkNotebookScreenState extends ConsumerState<InkNotebookScreen> {
  final _tools = NoteToolSettings();
  // Sayfa değişince yeni anahtar: her sayfa kendi oturumuyla (yeni State) açılır.
  var _editorKey = GlobalKey<NotePageEditorState>();
  String? _keyFor;
  String? _pageId;

  /// Yerel işlem (ekle/çoğalt/geri al) yeni sayfayı seçti ama liste henüz getirmedi:
  /// gelene kadar eski sayfa açık kalır (oturum bir kare için açılıp kapanmasın).
  String? _pendingId;
  bool _ensuring = false;

  /// Şeritte iyimser yerel sıra (kayıt sürerken); akış aynı sırayı getirince ya da hata olunca düşer.
  List<String>? _order;
  Object? _openError;

  /// Sayfa şeridi varsayılan kapalı (çizim alanı geniş kalsın); üstteki düğmeyle açılır.
  bool _strip = false;

  /// Çizgi aralığı çarpanı: yalnızca bu oturumda (sayfa kaydına yazılmaz).
  double _spacing = 1;

  late final NoteToolPrefsStore _prefsStore;
  Timer? _saveTimer;
  Map<String, Object?>? _savedPrefs;
  bool _prefsLoaded = false;

  @override
  void initState() {
    super.initState();
    _prefsStore = ref.read(noteToolPrefsStoreProvider);
    _tools.addListener(_prefsChanged);
    _loadPrefs();
    _open();
  }

  /// Kayıtlı kalem/silgi boyutları ve yuva konumu açılışta geri gelir.
  Future<void> _loadPrefs() async {
    try {
      final m = await _prefsStore.load();
      if (!mounted) return;
      _tools.restoreSizes(m);
      _savedPrefs = _tools.toPrefs();
    } catch (_) {
      // Okunamazsa varsayılanlarla devam; ayar yalnızca kolaylıktır.
    }
    _prefsLoaded = true;
  }

  /// Değişince kısa gecikmeyle kaydeder (sürgü sürüklenirken her karede yazmaz).
  void _prefsChanged() {
    if (!_prefsLoaded) return;
    final now = _tools.toPrefs();
    if (_savedPrefs != null && mapEquals(_savedPrefs, now)) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _savePrefs);
  }

  void _savePrefs() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final now = _tools.toPrefs();
    if (mapEquals(_savedPrefs, now)) return;
    _savedPrefs = now;
    _prefsStore.save(now).catchError((_) {});
  }

  Future<void> _open() async {
    try {
      final repo = ref.read(inkNotebookRepositoryProvider);
      var id = await repo.ensureVisiblePage(widget.notebookId);
      final want = widget.initialPageId;
      if (want != null) {
        final p = await repo.findPage(want);
        if (p != null && !p.deleted && p.notebookId == widget.notebookId) id = want;
      }
      if (mounted) setState(() => _pageId = id);
    } catch (e) {
      if (mounted) setState(() => _openError = e);
    }
  }

  @override
  void dispose() {
    _tools.removeListener(_prefsChanged);
    if (_prefsLoaded) _savePrefs();
    _saveTimer?.cancel();
    _tools.dispose();
    super.dispose();
  }

  InkNotebookRepository get _repo => ref.read(inkNotebookRepositoryProvider);

  void _msg(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on StateError catch (e) {
      if (mounted) _msg(e.message);
    } on ArgumentError {
      if (mounted) _msg('İşlem kaydedilemedi; liste yenilendi, yeniden dene.');
    }
  }

  /// Liste boş geldi (senkronda tüm sayfalar silinmiş): bir kez görünür sayfa sağlanır.
  void _ensureAfterFrame() {
    if (_ensuring) return;
    _ensuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;
        final id = await _repo.ensureVisiblePage(widget.notebookId);
        if (mounted) setState(() => _pageId = id);
      } catch (e) {
        if (mounted) setState(() => _openError = e);
      } finally {
        _ensuring = false;
      }
    });
  }

  Future<void> _add(
    List<InkNotePageRecord> pages, {
    required bool afterCurrent,
  }) => _guard(() async {
    final i = pages.indexWhere((p) => p.id == _pageId);
    final id = await _repo.addPage(
      widget.notebookId,
      index: afterCurrent && i >= 0 ? i + 1 : null,
    );
    if (mounted) setState(() => _pendingId = id);
  });

  Future<void> _duplicate() => _guard(() async {
    final cur = _pageId;
    if (cur == null) return;
    // Çoğaltma çizgileri veritabanından kopyalar: bekleyen kayıtlar önce bitmeli.
    await _editorKey.currentState?.flush();
    final id = await _repo.duplicatePage(cur);
    if (mounted) setState(() => _pendingId = id);
  });

  Future<void> _delete(List<InkNotePageRecord> pages) async {
    final cur = _pageId;
    if (cur == null) return;
    if (pages.length <= 1) {
      _msg('Defterin son sayfası silinemez.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sayfa silinsin mi?'),
        content: const Text(
          'Sayfa defterden kalkar; çizgileri silinmez, geri alabilirsin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            key: const Key('note-page-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final i = pages.indexWhere((p) => p.id == cur);
    await _guard(() async {
      await _editorKey.currentState?.flush();
      await _repo.deletePage(cur);
      if (!mounted) return;
      final rest = [
        for (final p in pages)
          if (p.id != cur) p,
      ];
      setState(
        () => _pageId =
            rest[(i < rest.length ? i : rest.length - 1).clamp(
                  0,
                  rest.length - 1,
                )]
                .id,
      );
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Sayfa silindi.'),
            action: SnackBarAction(
              label: 'Geri al',
              onPressed: () async {
                await _repo.restorePage(cur);
                if (mounted) setState(() => _pendingId = cur);
              },
            ),
          ),
        );
    });
  }

  Future<void> _reorderStrip(
    List<InkNotePageRecord> shown,
    int from,
    int to,
  ) async {
    if (from < 0 || from >= shown.length) return;
    final ids = [for (final p in shown) p.id];
    ids.insert(to.clamp(0, ids.length - 1), ids.removeAt(from));
    setState(
      () => _order = ids,
    ); // iyimser: kayıt bitmeden şerit yeni sırayı gösterir
    try {
      await _repo.reorderPages(widget.notebookId, ids);
    } on StateError catch (e) {
      if (mounted) {
        setState(() => _order = null);
        _msg(e.message);
      }
    } on ArgumentError {
      if (mounted) {
        setState(() => _order = null);
        _msg('Sıralama kaydedilemedi; liste yenilendi, yeniden dene.');
      }
    }
  }

  Future<void> _move(List<InkNotePageRecord> pages, int delta) =>
      _guard(() async {
        final i = pages.indexWhere((p) => p.id == _pageId);
        if (i < 0) return;
        await _repo.movePage(pages[i].id, i + delta);
      });

  @override
  Widget build(BuildContext context) {
    if (_openError != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Defter açılamadı: $_openError')),
      );
    }
    final nb = ref
        .watch(inkNotebooksProvider)
        .value
        ?.where((n) => n.id == widget.notebookId)
        .firstOrNull;
    final pagesAsync = ref.watch(inkNotebookPagesProvider(widget.notebookId));
    final pages = pagesAsync.value ?? const <InkNotePageRecord>[];
    // Açık sayfa listeden düştüyse (başka cihazda silindi) en yakın sayfaya geç.
    if (_pendingId != null && pages.any((p) => p.id == _pendingId)) {
      _pageId = _pendingId;
      _pendingId = null;
    }
    InkNotePageRecord? current;
    if (_pageId != null && pages.isNotEmpty) {
      current = pages.where((p) => p.id == _pageId).firstOrNull;
      if (current == null && _pendingId == null) {
        current = pages.first;
        _pageId = current
            .id; // işlemler (sil/taşı/çoğalt) gösterilen sayfaya uygulanır
      } else {
        current ??=
            pages.first; // bekleyen sayfa gelene kadar yedek: ilk sayfa kalır
      }
    }
    if (pagesAsync.hasValue && pages.isEmpty && nb != null && !nb.deleted)
      _ensureAfterFrame();
    var shown = pages;
    final order = _order;
    if (order != null) {
      final byId = {for (final p in pages) p.id: p};
      final sameSet =
          order.length == pages.length && order.every(byId.containsKey);
      if (!sameSet ||
          [for (final p in pages) p.id].join('|') == order.join('|')) {
        _order = null;
      } else {
        shown = [for (final id in order) byId[id]!];
      }
    }
    if (current != null && _keyFor != current.id) {
      _keyFor = current.id;
      _editorKey = GlobalKey<NotePageEditorState>();
    }
    final title = nb == null || nb.title.isEmpty ? 'Adsız defter' : nb.title;
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final i = current == null ? -1 : pages.indexOf(current);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        titleSpacing: 0,
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          _PagePill(
            index: i,
            count: pages.length,
            onPrev: i > 0 ? () => setState(() => _pageId = pages[i - 1].id) : null,
            // Son sayfada ileri oku yeni sayfa ekler.
            onNext: i < 0
                ? null
                : i < pages.length - 1
                ? () => setState(() => _pageId = pages[i + 1].id)
                : () => _add(pages, afterCurrent: false),
            isLast: i == pages.length - 1,
            infinite: current != null && isInfinitePage(current.height),
            onAdd: current == null ? null : () => _add(pages, afterCurrent: true),
          ),
          const FocusModeButton(),
          if (wide) ...[
            IconButton(
              key: const Key('note-tags-btn'),
              tooltip: 'Etiketler ve kişiler',
              icon: const Icon(Icons.sell_outlined),
              onPressed: () => _tagsPanel(current),
            ),
            IconButton(
              key: const Key('note-strip-toggle'),
              tooltip: _strip ? 'Sayfa şeridini gizle' : 'Sayfa şeridini göster',
              icon: Icon(_strip ? Icons.view_sidebar : Icons.view_sidebar_outlined),
              onPressed: () => setState(() => _strip = !_strip),
            ),
          ],
          PopupMenuButton<String>(
            key: const Key('note-page-menu'),
            tooltip: 'Sayfa işlemleri',
            enabled: current != null,
            onSelected: (v) => switch (v) {
              'style' => _pageStyle(current!),
              'add' => _add(pages, afterCurrent: false),
              'insert' => _add(pages, afterCurrent: true),
              'dup' => _duplicate(),
              'del' => _delete(pages),
              'up' => _move(pages, -1),
              'down' => _move(pages, 1),
              'size' => _pageSize(current!),
              'tags' => _tagsPanel(current),
              'strip' => setState(() => _strip = !_strip),
              'totext' => _pageToText(current!),
              'seltext' => _selectionToText(current!),
              'nbtext' => _notebookText(),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'style',
                key: Key('note-page-style'),
                child: Text('Şablon ve arka plan…'),
              ),
              if (!wide) ...[
                const PopupMenuItem(
                  value: 'tags',
                  key: Key('note-tags-menu'),
                  child: Text('Etiketler ve kişiler'),
                ),
                PopupMenuItem(
                  value: 'strip',
                  key: const Key('note-strip-menu'),
                  child: Text(_strip ? 'Sayfa şeridini gizle' : 'Sayfa şeridini göster'),
                ),
              ],
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'totext',
                key: const Key('note-page-totext'),
                child: Text(
                  ref.read(handwritingAvailableProvider)
                      ? 'Sayfayı metne çevir'
                      : 'Sayfa metnini göster',
                ),
              ),
              if (ref.read(handwritingAvailableProvider) &&
                  (_editorKey.currentState?.session.hasSelection ?? false))
                const PopupMenuItem(
                  value: 'seltext',
                  key: Key('note-sel-totext'),
                  child: Text('Seçimi metne çevir'),
                ),
              const PopupMenuItem(
                value: 'nbtext',
                key: Key('note-nb-text'),
                child: Text('Defterin metin kopyası'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'add',
                key: Key('note-page-add'),
                child: Text('Sona sayfa ekle'),
              ),
              const PopupMenuItem(
                value: 'insert',
                key: Key('note-page-insert'),
                child: Text('Bundan sonra sayfa ekle'),
              ),
              const PopupMenuItem(
                value: 'dup',
                key: Key('note-page-dup'),
                child: Text('Sayfayı çoğalt'),
              ),
              const PopupMenuItem(
                value: 'up',
                key: Key('note-page-up'),
                child: Text('Sayfayı öne al'),
              ),
              const PopupMenuItem(
                value: 'down',
                key: Key('note-page-down'),
                child: Text('Sayfayı arkaya al'),
              ),
              const PopupMenuItem(
                value: 'size',
                key: Key('note-page-size'),
                child: Text('Sayfa boyutu…'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'del',
                key: Key('note-page-del'),
                child: Text('Sayfayı sil'),
              ),
            ],
          ),
        ],
      ),
      body: current == null
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<bool>(
              valueListenable:
                  TabletFocus.maybeOf(context) ?? ValueNotifier(false),
              builder: (context, focus, _) {
                final showStrip =
                    _strip && !focus; // odak modu şeridi de gizler
                return Row(
                  children: [
                    if (showStrip)
                      _PageStrip(
                        pages: shown,
                        withText: ref.watch(pageTextsProvider).value?.keys.toSet() ?? const {},
                        currentId: current!.id,
                        onTap: (p) => setState(() => _pageId = p.id),
                        onAdd: () => _add(pages, afterCurrent: false),
                        onReorder: (from, to) => _reorderStrip(shown, from, to),
                      ),
                    if (showStrip) const VerticalDivider(width: 1),
                    Expanded(
                      child: NotePageEditor(
                        key: _editorKey,
                        page: current!,
                        tools: _tools,
                        stylusOnlyOverride: widget.stylusOnlyOverride,
                        onGrow: (h) => _repo.setPageSize(current!.id, current.width, h),
                        onTranscribe: () => _pageToText(current!),
                        spacing: _spacing,
                        onSpacing: (f) => setState(() => _spacing = f),
                        onBackground: (c) =>
                            _guard(() => _repo.setPageBackground(current!.id, c)),
                        onTemplate: (t) =>
                            _guard(() => _repo.setPageTemplate(current!.id, t)),
                        onTemplateAll: (t) => _guard(
                          () => _repo.setNotebookPagesTemplate(
                            widget.notebookId,
                            t,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  /// Sayfayı metne çevir (kayıtlı metin varsa önce onu gösterir).
  Future<void> _pageToText(InkNotePageRecord p) async {
    await _editorKey.currentState?.flush(); // bekleyen çizgiler kayda geçsin
    if (!mounted) return;
    await showPageTextSheet(context, page: p);
  }

  /// Kement seçimini metne çevir (kaydedilmez; kopyalanır).
  Future<void> _selectionToText(InkNotePageRecord p) async {
    final session = _editorKey.currentState?.session;
    if (session == null || !session.hasSelection) {
      _msg('Önce kement ile çizgi seç.');
      return;
    }
    final ids = {for (final o in session.selectionOriginals) o.id};
    await _editorKey.currentState?.flush();
    if (!mounted) return;
    await showPageTextSheet(context, page: p, selectedIds: ids);
  }

  Future<void> _notebookText() async {
    await _editorKey.currentState?.flush();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => NotebookTextScreen(notebookId: widget.notebookId)),
    );
  }

  void _tagsPanel(InkNotePageRecord? current) => showInkTagsPanel(
    context,
    notebookId: widget.notebookId,
    pageId: current?.id,
  );

  /// Sayfa menüsünden: yuvadaki "Sayfa" penceresinin aynısı, ortada pencere olarak.
  Future<void> _pageStyle(InkNotePageRecord p) => showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: PageStylePanel(
          control: PageStyleControl(
            template: p.template,
            background: p.background,
            spacing: _spacing,
            onTemplate: (t) => _guard(() => _repo.setPageTemplate(p.id, t)),
            onTemplateAll: (t) => _guard(
              () => _repo.setNotebookPagesTemplate(widget.notebookId, t),
            ),
            onBackground: (c) => _guard(() => _repo.setPageBackground(p.id, c)),
            onSpacing: (f) => setState(() => _spacing = f),
          ),
        ),
      ),
    ),
  );

  /// Sayfa boyutu diyalogu; küçültme çizgi kırpacaksa depo engeller (mesaj gösterilir).
  Future<void> _pageSize(InkNotePageRecord p) async {
    final media = MediaQuery.sizeOf(context);
    final kind = await showDialog<PageSizeKind>(
      context: context,
      builder: (_) =>
          PageSizeDialog(initial: pageSizeKindOf(p.width, p.height)),
    );
    if (kind == null || !mounted) return;
    final d = pageDimensions(
      kind,
      aspect: screenAspect(media.width, media.height),
    );
    await _guard(() async {
      await _editorKey.currentState?.flush();
      // Sonsuza çevirirken mevcut yükseklik küçültülmez (çizgi kaybı yok).
      final h = kind == PageSizeKind.infinite && p.height > d.height
          ? p.height
          : d.height;
      await _repo.setPageSize(p.id, d.width, h);
    });
  }
}

/// Üst çubukta: önceki / "2 / 5" / sonraki ve "+" (sayfa ekle). Son sayfada sonraki oku
/// "yeni sayfa" olur.
class _PagePill extends StatelessWidget {
  const _PagePill({
    required this.index,
    required this.count,
    required this.onPrev,
    required this.onNext,
    required this.isLast,
    required this.onAdd,
    this.infinite = false,
  });

  /// Geçerli sayfa sonsuz (aşağı kayan): göstergede "Sonsuz" yazar.
  final bool infinite;
  final int index;
  final int count;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool isLast;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    const dense = VisualDensity(horizontal: -2, vertical: -2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('note-page-prev'),
          visualDensity: dense,
          tooltip: 'Önceki sayfa',
          icon: const Icon(Icons.chevron_left),
          onPressed: onPrev,
        ),
        Text(
          '${index + 1} / $count${infinite ? ' · Sonsuz' : ''}',
          key: const Key('note-page-indicator'),
        ),
        IconButton(
          key: const Key('note-page-next'),
          visualDensity: dense,
          tooltip: isLast ? 'Yeni sayfa ekle' : 'Sonraki sayfa',
          icon: Icon(isLast ? Icons.note_add_outlined : Icons.chevron_right),
          onPressed: onNext,
        ),
        IconButton(
          key: const Key('note-page-add-top'),
          visualDensity: dense,
          tooltip: 'Bundan sonra yeni sayfa ekle',
          icon: const Icon(Icons.add),
          onPressed: onAdd,
        ),
      ],
    );
  }
}

/// Sayfa boyutu seçici (A4 dikey / ekrana tam / sonsuz aşağı kayan).
class PageSizeDialog extends StatefulWidget {
  const PageSizeDialog({super.key, required this.initial});
  final PageSizeKind initial;

  @override
  State<PageSizeDialog> createState() => _PageSizeDialogState();
}

class _PageSizeDialogState extends State<PageSizeDialog> {
  late PageSizeKind _kind = widget.initial;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sayfa boyutu'),
    content: PageSizePicker(
      kind: _kind,
      onChanged: (k) => setState(() => _kind = k),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Vazgeç'),
      ),
      FilledButton(
        key: const Key('page-size-ok'),
        onPressed: () => Navigator.pop(context, _kind),
        child: const Text('Tamam'),
      ),
    ],
  );
}

/// Boyut seçenekleri (yeni defter diyaloğunda da kullanılır).
class PageSizePicker extends StatelessWidget {
  const PageSizePicker({
    super.key,
    required this.kind,
    required this.onChanged,
  });
  final PageSizeKind kind;
  final ValueChanged<PageSizeKind> onChanged;

  @override
  Widget build(BuildContext context) => RadioGroup<PageSizeKind>(
    groupValue: kind,
    onChanged: (k) {
      if (k != null) onChanged(k);
    },
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final k in PageSizeKind.values)
          RadioListTile<PageSizeKind>(
            key: Key('page-size-${k.key}'),
            dense: true,
            value: k,
            title: Text(k.label),
          ),
      ],
    ),
  );
}

/// Yan şerit: sayfa küçük resimleri (sürükleyerek sırala), sona ekle düğmesi.
class _PageStrip extends StatelessWidget {
  const _PageStrip({
    required this.pages,
    required this.currentId,
    required this.onTap,
    required this.onAdd,
    required this.onReorder,
    this.withText = const {},
  });
  final List<InkNotePageRecord> pages;

  /// Kayıtlı el yazısı metni olan sayfalar ("Aa" rozeti).
  final Set<String> withText;
  final String currentId;
  final ValueChanged<InkNotePageRecord> onTap;
  final VoidCallback onAdd;
  final void Function(int from, int to) onReorder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: const Key('note-page-strip'),
      width: 112,
      child: Column(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              itemCount: pages.length,
              onReorderItem: onReorder,
              buildDefaultDragHandles: true,
              itemBuilder: (context, i) {
                final p = pages[i];
                return InkWell(
                  key: ValueKey(p.id),
                  onTap: () => onTap(p),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            Container(
                              key: Key('note-thumb-${p.id}'),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: p.id == currentId
                                      ? cs.primary
                                      : cs.outlineVariant,
                                  width: 2,
                                ),
                              ),
                              child: AspectRatio(
                                // Sonsuz sayfada yalnız üst kısım (A4 oranında) görünür.
                                aspectRatio: p.width /
                                    (isInfinitePage(p.height) ? a4PageHeight : p.height),
                                child: _PageThumb(page: p),
                              ),
                            ),
                            if (withText.contains(p.id))
                              Positioned(
                                right: 2,
                                top: 2,
                                child: Container(
                                  key: Key('note-thumb-text-${p.id}'),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: cs.primaryContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'Aa',
                                    style: Theme.of(context).textTheme.labelSmall,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Text(
                          '${i + 1}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(6),
            child: FilledButton.tonalIcon(
              key: const Key('note-strip-add'),
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Yeni sayfa'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Küçük resim: şablon + sayfanın çizgileri. Çizgiler akışta TEK abonelikle izlenir
/// (State'te), sonuç bir kez `ui.Picture`'a kaydedilir (yeniden boyamada outline hesabı yok);
/// ardışık güncellemeler [_ThumbState.delay] ile geciktirilir.
class _PageThumb extends ConsumerStatefulWidget {
  const _PageThumb({required this.page});
  final InkNotePageRecord page;

  @override
  ConsumerState<_PageThumb> createState() => _ThumbState();
}

class _ThumbState extends ConsumerState<_PageThumb> {
  /// Peş peşe çizgi değişikliklerinde yeniden çözme/çizme bekleme süresi.
  static const delay = Duration(milliseconds: 400);

  StreamSubscription<List<InkStroke>>? _sub;
  Timer? _timer;
  List<InkStroke>? _pending;
  bool _first = true;
  ui.Picture? _picture;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _sub?.cancel();
    _timer?.cancel();
    _first = true;
    _pending = null;
    final p = widget.page;
    _sub = ref
        .read(inkStrokeRepositoryProvider)
        .watchPage(
          NotePageOwner(p.id, p.pageNo),
          attemptNo: 0,
          layer: 0,
          noQuestion: true,
        )
        .listen(_onData);
  }

  void _onData(List<InkStroke> strokes) {
    if (_first) {
      _first = false;
      _apply(strokes);
      return;
    }
    _pending = strokes;
    _timer ??= Timer(delay, () {
      _timer = null;
      final d = _pending;
      _pending = null;
      if (d != null && mounted) _apply(d);
    });
  }

  void _apply(List<InkStroke> strokes) {
    final old = _picture;
    _picture = _record(strokes);
    setState(() {});
    old?.dispose();
  }

  ui.Picture _record(List<InkStroke> strokes) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    for (final s in strokes) {
      final t = parseToolColumn(s.tool);
      final kind = penProfiles.keys.where((k) => k.name == t.name).firstOrNull;
      final brush = InkBrush(
        tool: kind == PenKind.highlighter ? InkTool.highlighter : InkTool.pen,
        color: s.color,
        width: s.width,
        kind: kind,
        hardness: t.hardness,
      );
      final pts = [
        for (final p in s.points)
          InkPoint(
            x: p.x,
            y: p.y,
            pressure: p.pressure,
            tilt: p.tilt,
            tMs: p.t.toDouble(),
          ),
      ];
      c.drawPath(
        inkOutlinePath(pts, brush, complete: true),
        inkPaintFor(brush),
      );
    }
    return rec.endRecording();
  }

  @override
  void didUpdateWidget(_PageThumb old) {
    super.didUpdateWidget(old);
    if (old.page.id != widget.page.id ||
        old.page.pageNo != widget.page.pageNo) {
      _listen();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _picture?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _ThumbPainter(widget.page, _picture),
      size: Size.infinite,
    ),
  );
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.page, this.strokes);
  final InkNotePageRecord page;
  final ui.Picture? strokes;

  @override
  void paint(Canvas canvas, Size size) {
    // Sonsuz sayfada küçük resim yalnız üst A4 kadarını gösterir.
    final inf = isInfinitePage(page.height);
    final shownH = inf ? a4PageHeight : page.height;
    PageTemplatePainter(
      template: page.template,
      background: page.background,
      pageWidth: page.width,
      pageHeight: shownH,
      infinite: inf,
    ).paint(canvas, size);
    final pic = strokes;
    if (pic == null) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / page.width, size.height / shownH);
    canvas.drawPicture(pic);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThumbPainter old) =>
      old.page != page || !identical(old.strokes, strokes);
}
