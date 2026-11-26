import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../data/ink_board_repository.dart';
import '../domain/board_layout.dart';
import '../domain/board_view.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_board.dart';
import '../notes_providers.dart';
import 'board_canvas.dart';
import 'board_toolbar.dart';

/// Bağlantı renk seçenekleri.
const boardLinkColors = <int>[0xFF607D8B, 0xFFE53935, 0xFFFB8C00, 0xFF43A047, 0xFF1E88E5, 0xFF8E24AA];

/// Defterin tüm sayfaları sonsuz bir panoda kart olarak; kartlar arası bağlantılar.
class InkBoardScreen extends ConsumerStatefulWidget {
  const InkBoardScreen({super.key, required this.notebookId});
  final String notebookId;

  @override
  ConsumerState<InkBoardScreen> createState() => _InkBoardScreenState();
}

class _InkBoardScreenState extends ConsumerState<InkBoardScreen> {
  final _controller = BoardViewController();
  bool _linkMode = false;
  String _query = '';
  bool _placing = false;
  bool _manual = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  InkBoardRepository get _repo => ref.read(inkBoardRepositoryProvider);

  void _msg(String text, {String? undoLabel, Future<void> Function()? undo}) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      action: undo == null
          ? null
          : SnackBarAction(
              label: undoLabel ?? 'Geri al',
              onPressed: () async {
                try {
                  await undo();
                } catch (_) {
                  if (mounted) _msg('Geri alınamadı');
                }
              },
            ),
    ));
  }

  /// Yerleşmemiş kartları (ilk açılış, senkrondan gelen sayfalar) bir kez yerleştirir.
  void _ensurePlaced(List<BoardCard> cards) {
    if (_placing || _manual || cards.every((c) => c.placed)) return;
    _placing = true;
    Future(() async {
      try {
        if (cards.every((c) => !c.placed)) {
          await _repo.arrangeNotebook(widget.notebookId);
        } else {
          await _repo.setBoardPositions(placeUnplaced(cards));
        }
      } catch (_) {
        // Sayfa arada silinmiş olabilir; akış yenilenince yeniden denenir.
      } finally {
        _placing = false;
      }
    });
  }

  Future<void> _write(Map<String, BoardRect> before, Map<String, BoardRect> after) async {
    try {
      await _repo.setBoardPositions(after);
      _msg('Kart güncellendi', undo: () => _repo.setBoardPositions(before));
    } catch (_) {
      _controller.discardPending();
      _msg('Kaydedilemedi');
    }
  }

  Future<void> _connect(String from, String to) async {
    try {
      final existing = (ref.read(boardLinksProvider(widget.notebookId)).value ?? const <PageLinkRecord>[]).any(
        (l) => l.fromPageId == from && l.toPageId == to && l.kind == PageLinkKind.link,
      );
      final id = await _repo.addLink(from, to);
      _msg(existing ? 'Bu bağlantı zaten var' : 'Bağlandı', undo: existing ? null : () => _repo.deleteLink(id));
    } catch (_) {
      _msg('Bağlanamadı');
    }
  }

  Future<void> _connectEmpty(String from, BoardPoint at) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Yeni sayfa oluşturup bağla?'),
        content: const Text('Boş yere bıraktın. Burada yeni bir sayfa açılıp bu karta bağlansın mı?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(key: const Key('board-create-child'), onPressed: () => Navigator.pop(c, true), child: const Text('Oluştur')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _manual = true;
    try {
      final id = await _repo.createChildPage(from, 0, 0);
      await _repo.setBoardPositions({id: BoardRect(at.x - boardCardW / 2, at.y - boardCardH / 2, boardCardW, boardCardH)});
      _msg('Yeni sayfa bağlandı');
    } catch (_) {
      _msg('Oluşturulamadı');
    } finally {
      _manual = false;
    }
  }

  Future<void> _newPage(List<BoardCard> cards) async {
    _manual = true;
    try {
      final id = await ref.read(inkNotebookRepositoryProvider).addPage(widget.notebookId);
      final view = _controller.visibleRect() ?? const BoardRect(0, 0, 1000, 800);
      final taken = [for (final c in cards) c.rect()].whereType<BoardRect>();
      final seed = BoardRect(view.cx - boardCardW * 1.5 - 80, view.cy - boardCardH / 2, boardCardW, boardCardH);
      await _repo.setBoardPositions({id: freeSlotNear(seed, taken)});
    } catch (_) {
      _msg('Sayfa eklenemedi');
    } finally {
      _manual = false;
    }
  }

  Future<void> _arrange(List<BoardCard> cards) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Otomatik düzenle'),
        content: const Text('Tüm kartlar bağlantılara göre yeniden yerleştirilir. Şimdiki yerleşimi Geri al ile döndürebilirsin.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(key: const Key('board-arrange-ok'), onPressed: () => Navigator.pop(c, true), child: const Text('Düzenle')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final before = {
      for (final c in cards)
        if (c.rect() case final r?) c.pageId: r,
    };
    try {
      _controller.fitOnNextCards();
      await _repo.arrangeNotebook(widget.notebookId);
      _msg('Düzenlendi', undo: before.isEmpty ? null : () => _repo.setBoardPositions(before));
    } catch (_) {
      _msg('Düzenlenemedi');
    }
  }

  Future<void> _linkMenu(PageLinkRecord l) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(l.label.isEmpty ? 'Bağlantı' : l.label), subtitle: Text(switch (l.kind) {
              PageLinkKind.konu => 'Konu bağlantısı',
              PageLinkKind.child => 'Alt sayfa',
              PageLinkKind.link => 'Elle bağlantı',
            })),
            ListTile(key: const Key('link-label'), leading: const Icon(Icons.edit_outlined), title: const Text('Etiketi düzenle'), onTap: () => Navigator.pop(c, 'label')),
            ListTile(key: const Key('link-color'), leading: const Icon(Icons.palette_outlined), title: const Text('Renk'), onTap: () => Navigator.pop(c, 'color')),
            ListTile(key: const Key('link-delete'), leading: const Icon(Icons.delete_outline), title: const Text('Sil'), onTap: () => Navigator.pop(c, 'delete')),
          ],
        ),
      ),
    );
    if (act == null || !mounted) return;
    switch (act) {
      case 'label':
        final text = await _askLabel(l.label);
        if (text != null) await _repo.setLinkLabel(l.id, text);
      case 'color':
        final col = await showDialog<int>(
          context: context,
          builder: (c) => SimpleDialog(
            title: const Text('Renk'),
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                children: [
                  for (final k in boardLinkColors)
                    InkWell(
                      key: Key('link-color-$k'),
                      onTap: () => Navigator.pop(c, k),
                      child: CircleAvatar(backgroundColor: Color(k), radius: 20),
                    ),
                ],
              ),
            ],
          ),
        );
        if (col != null) await _repo.setLinkColor(l.id, col);
      case 'delete':
        await _repo.deleteLink(l.id);
        _msg('Bağlantı silindi', undo: () => _repo.restoreLink(l.id));
    }
  }

  Future<String?> _askLabel(String current) => showDialog<String>(context: context, builder: (c) => _LabelDialog(initial: current));

  @override
  Widget build(BuildContext context) {
    final nbId = widget.notebookId;
    final cards = ref.watch(boardCardsProvider(nbId)).value;
    final links = ref.watch(boardLinksProvider(nbId)).value ?? const <PageLinkRecord>[];
    final pages = ref.watch(inkNotebookPagesProvider(nbId)).value ?? const <InkNotePageRecord>[];
    final nb = ref.watch(inkNotebooksProvider).value?.where((n) => n.id == nbId).firstOrNull;
    if (cards != null) _ensurePlaced(cards);
    final title = nb == null || nb.title.isEmpty ? 'Pano' : 'Pano · ${nb.title}';
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        title: Text(title, overflow: TextOverflow.ellipsis),
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go(AppRoutes.inkNotebook(nbId))),
      ),
      body: cards == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                BoardToolbar(
                  zoom: _controller.zoom,
                  linkMode: _linkMode,
                  onLinkMode: (v) => setState(() => _linkMode = v),
                  onArrange: () => _arrange(cards),
                  onFit: _controller.fit,
                  onNewPage: () => _newPage(cards),
                  onSearch: (q) => setState(() => _query = q),
                  onZoomReset: _controller.resetZoom,
                ),
                Expanded(
                  child: cards.isEmpty
                      ? const Center(child: Text('Bu defterde sayfa yok'))
                      : BoardCanvas(
                          controller: _controller,
                          cards: cards,
                          pages: {for (final p in pages) p.id: p},
                          links: links,
                          linkMode: _linkMode,
                          query: _query,
                          onOpen: (id) => context.push(AppRoutes.inkNotebookAt(nbId, id)),
                          onChanged: _write,
                          onConnect: _connect,
                          onConnectEmpty: _connectEmpty,
                          onLinkTap: _linkMenu,
                        ),
                ),
              ],
            ),
    );
  }
}

class _LabelDialog extends StatefulWidget {
  const _LabelDialog({required this.initial});
  final String initial;

  @override
  State<_LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<_LabelDialog> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Etiket'),
        content: TextField(key: const Key('link-label-field'), controller: _ctl, autofocus: true, maxLength: 60),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
          FilledButton(key: const Key('link-label-ok'), onPressed: () => Navigator.pop(context, _ctl.text), child: const Text('Tamam')),
        ],
      );
}
