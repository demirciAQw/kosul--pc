import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ink/data/ink_outline.dart';
import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../ink/domain/pen_profiles.dart';
import '../../pdf/pdf_providers.dart';
import '../data/ink_notebook_repository.dart';
import '../domain/ink_notebook.dart';
import '../notes_providers.dart';
import 'ink_tags_panel.dart';
import 'note_page_editor.dart';
import 'note_tool_settings.dart';
import 'page_template_painter.dart';

/// Defter içi: yan şeritte sayfa küçük resimleri, ortada sayfa düzenleyicisi.
/// Açılışta `ensureVisiblePage` çağrılır (senkronda tüm sayfalar silinmiş olabilir).
class InkNotebookScreen extends ConsumerStatefulWidget {
  const InkNotebookScreen({super.key, required this.notebookId, this.stylusOnlyOverride});
  final String notebookId;

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
  Object? _openError;
  bool _strip = true;
  bool _stripInit = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final id = await ref.read(inkNotebookRepositoryProvider).ensureVisiblePage(widget.notebookId);
      if (mounted) setState(() => _pageId = id);
    } catch (e) {
      if (mounted) setState(() => _openError = e);
    }
  }

  @override
  void dispose() {
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
    }
  }

  Future<void> _add(List<InkNotePageRecord> pages, {required bool afterCurrent}) => _guard(() async {
    final i = pages.indexWhere((p) => p.id == _pageId);
    final id = await _repo.addPage(widget.notebookId, index: afterCurrent && i >= 0 ? i + 1 : null);
    if (mounted) setState(() => _pageId = id);
  });

  Future<void> _duplicate() => _guard(() async {
    final cur = _pageId;
    if (cur == null) return;
    // Çoğaltma çizgileri veritabanından kopyalar: bekleyen kayıtlar önce bitmeli.
    await _editorKey.currentState?.flush();
    final id = await _repo.duplicatePage(cur);
    if (mounted) setState(() => _pageId = id);
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
        content: const Text('Sayfa defterden kalkar; çizgileri silinmez, geri alabilirsin.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
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
      final rest = [for (final p in pages) if (p.id != cur) p];
      setState(() => _pageId = rest[(i < rest.length ? i : rest.length - 1).clamp(0, rest.length - 1)].id);
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
                if (mounted) setState(() => _pageId = cur);
              },
            ),
          ),
        );
    });
  }

  Future<void> _move(List<InkNotePageRecord> pages, int delta) => _guard(() async {
    final i = pages.indexWhere((p) => p.id == _pageId);
    if (i < 0) return;
    await _repo.movePage(pages[i].id, i + delta);
  });

  @override
  Widget build(BuildContext context) {
    if (_openError != null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text('Defter açılamadı: $_openError')));
    }
    final nb = ref.watch(inkNotebooksProvider).value?.where((n) => n.id == widget.notebookId).firstOrNull;
    final pagesAsync = ref.watch(inkNotebookPagesProvider(widget.notebookId));
    final pages = pagesAsync.value ?? const <InkNotePageRecord>[];
    if (!_stripInit) {
      _stripInit = true;
      _strip = MediaQuery.sizeOf(context).width >= 600;
    }
    // Açık sayfa listeden düştüyse (başka cihazda silindi) en yakın sayfaya geç.
    InkNotePageRecord? current;
    if (_pageId != null && pages.isNotEmpty) {
      current = pages.where((p) => p.id == _pageId).firstOrNull ?? pages.first;
    }
    if (current != null && _keyFor != current.id) {
      _keyFor = current.id;
      _editorKey = GlobalKey<NotePageEditorState>();
    }
    final title = nb == null || nb.title.isEmpty ? 'Adsız defter' : nb.title;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          if (current != null)
            Center(
              child: Text(
                '${pages.indexOf(current) + 1} / ${pages.length}',
                key: const Key('note-page-indicator'),
              ),
            ),
          IconButton(
            key: const Key('note-tags-btn'),
            tooltip: 'Etiketler ve kişiler',
            icon: const Icon(Icons.sell_outlined),
            onPressed: () => showInkTagsPanel(context, notebookId: widget.notebookId, pageId: current?.id),
          ),
          IconButton(
            key: const Key('note-strip-toggle'),
            tooltip: 'Sayfalar',
            icon: Icon(_strip ? Icons.view_sidebar : Icons.view_sidebar_outlined),
            onPressed: () => setState(() => _strip = !_strip),
          ),
          PopupMenuButton<String>(
            key: const Key('note-page-menu'),
            tooltip: 'Sayfa işlemleri',
            enabled: current != null,
            onSelected: (v) => switch (v) {
              'add' => _add(pages, afterCurrent: false),
              'insert' => _add(pages, afterCurrent: true),
              'dup' => _duplicate(),
              'del' => _delete(pages),
              'up' => _move(pages, -1),
              'down' => _move(pages, 1),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'add', key: Key('note-page-add'), child: Text('Sona sayfa ekle')),
              PopupMenuItem(value: 'insert', key: Key('note-page-insert'), child: Text('Bundan sonra sayfa ekle')),
              PopupMenuItem(value: 'dup', key: Key('note-page-dup'), child: Text('Sayfayı çoğalt')),
              PopupMenuItem(value: 'up', key: Key('note-page-up'), child: Text('Sayfayı öne al')),
              PopupMenuItem(value: 'down', key: Key('note-page-down'), child: Text('Sayfayı arkaya al')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'del', key: Key('note-page-del'), child: Text('Sayfayı sil')),
            ],
          ),
        ],
      ),
      body: current == null
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                if (_strip)
                  _PageStrip(
                    pages: pages,
                    currentId: current.id,
                    onTap: (p) => setState(() => _pageId = p.id),
                    onAdd: () => _add(pages, afterCurrent: false),
                    onReorder: (from, to) => _guard(() async {
                      await _repo.movePage(pages[from].id, to);
                    }),
                  ),
                if (_strip) const VerticalDivider(width: 1),
                Expanded(
                  child: NotePageEditor(
                    key: _editorKey,
                    page: current,
                    tools: _tools,
                    stylusOnlyOverride: widget.stylusOnlyOverride,
                    onTemplate: (t) => _guard(() => _repo.setPageTemplate(current!.id, t)),
                    onTemplateAll: (t) => _guard(() => _repo.setNotebookPagesTemplate(widget.notebookId, t)),
                  ),
                ),
              ],
            ),
    );
  }
}


/// Yan şerit: sayfa küçük resimleri (sürükleyerek sırala), sona ekle düğmesi.
class _PageStrip extends StatelessWidget {
  const _PageStrip({
    required this.pages,
    required this.currentId,
    required this.onTap,
    required this.onAdd,
    required this.onReorder,
  });
  final List<InkNotePageRecord> pages;
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
                        Container(
                          key: Key('note-thumb-${p.id}'),
                          decoration: BoxDecoration(
                            border: Border.all(color: p.id == currentId ? cs.primary : cs.outlineVariant, width: 2),
                          ),
                          child: AspectRatio(aspectRatio: p.width / p.height, child: _PageThumb(page: p)),
                        ),
                        Text('${i + 1}', style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            key: const Key('note-strip-add'),
            tooltip: 'Sayfa ekle',
            icon: const Icon(Icons.add_box_outlined),
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

/// Küçük resim: şablon + sayfanın çizgileri (çizgiler değişince kendini yeniler).
class _PageThumb extends ConsumerWidget {
  const _PageThumb({required this.page});
  final InkNotePageRecord page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(inkStrokeRepositoryProvider);
    return StreamBuilder<List<InkStroke>>(
      stream: repo.watchPage(NotePageOwner(page.id, page.pageNo), attemptNo: 0, layer: 0, noQuestion: true),
      builder: (context, snap) => CustomPaint(
        painter: _ThumbPainter(page, snap.data ?? const []),
        size: Size.infinite,
      ),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.page, this.strokes);
  final InkNotePageRecord page;
  final List<InkStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    PageTemplatePainter(
      template: page.template,
      background: page.background,
      pageWidth: page.width,
      pageHeight: page.height,
    ).paint(canvas, size);
    canvas.save();
    canvas.scale(size.width / page.width, size.height / page.height);
    for (final s in strokes) {
      final kind = penProfiles.keys.where((k) => k.name == s.tool).firstOrNull;
      final brush = InkBrush(
        tool: kind == PenKind.highlighter ? InkTool.highlighter : InkTool.pen,
        color: s.color,
        width: s.width,
        kind: kind,
      );
      final pts = [
        for (final p in s.points) InkPoint(x: p.x, y: p.y, pressure: p.pressure, tilt: p.tilt, tMs: p.t.toDouble()),
      ];
      canvas.drawPath(inkOutlinePath(pts, brush, complete: true), inkPaintFor(brush));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThumbPainter old) => old.page != page || !identical(old.strokes, strokes);
}
