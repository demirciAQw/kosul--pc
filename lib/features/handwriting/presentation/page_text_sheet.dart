import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notes/domain/ink_notebook.dart';
import '../data/handwriting_service.dart';
import '../data/page_text_repository.dart';
import '../domain/handwriting_recognizer.dart';
import '../handwriting_providers.dart';
import 'model_download.dart';

/// Sayfayı (ya da [selectedIds] ile kement seçimini) metne çeviren alt sayfa.
/// Kayıtlı metin varsa önce onu gösterir; tanıma yoksa (masaüstü) yalnız okur.
/// Çağırmadan önce sayfanın bekleyen çizgi kayıtları bitirilmiş olmalı (`flush`).
Future<void> showPageTextSheet(BuildContext context, {required InkNotePageRecord page, Set<String>? selectedIds}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PageTextSheet(page: page, selectedIds: selectedIds),
    );

enum _Phase { loading, needModel, downloading, recognizing, ready, error }

class PageTextSheet extends ConsumerStatefulWidget {
  const PageTextSheet({super.key, required this.page, this.selectedIds});
  final InkNotePageRecord page;

  /// Doluysa yalnız bu çizgiler okunur; sonuç kaydedilmez (yalnız kopyalanır).
  final Set<String>? selectedIds;

  @override
  ConsumerState<PageTextSheet> createState() => _PageTextSheetState();
}

class _PageTextSheetState extends ConsumerState<PageTextSheet> {
  final _text = TextEditingController();
  _Phase _phase = _Phase.loading;
  PageRecognition? _fresh; // henüz kaydedilmemiş tanıma
  PageTextRecord? _saved;
  bool _stale = false;
  bool _cancelled = false;
  bool _partial = false;
  String? _error;
  var _done = 0, _total = 0;
  bool _aborted = false; // sayfa kapandı

  bool get _selection => widget.selectedIds != null;
  bool get _canRecognize => ref.read(handwritingAvailableProvider);

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _aborted = true;
    _text.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!_selection) {
      final repo = ref.read(pageTextRepositoryProvider);
      final saved = await repo.get(widget.page.id);
      if (!mounted) return;
      if (saved != null) {
        final stale = await repo.isStale(widget.page.id);
        if (!mounted) return;
        setState(() {
          _saved = saved;
          _stale = stale;
          _text.text = saved.text;
          _phase = _Phase.ready;
        });
        return;
      }
    }
    if (!_canRecognize) {
      setState(() => _phase = _Phase.ready);
      return;
    }
    await _recognize();
  }

  Future<void> _recognize() async {
    final svc = ref.read(handwritingServiceProvider);
    setState(() {
      _phase = _Phase.recognizing;
      _error = null;
      _cancelled = false;
      _done = 0;
      _total = 0;
    });
    try {
      final status = await svc.recognizer.modelStatus();
      if (!mounted) return;
      if (status == HandwritingModelStatus.notDownloaded) {
        setState(() => _phase = _Phase.needModel);
        return;
      }
      final r = await svc.recognizePage(
        widget.page,
        onlyIds: widget.selectedIds,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() {
            _done = d;
            _total = t;
          });
        },
        isCancelled: () => _cancelled || _aborted,
      );
      if (!mounted) return;
      setState(() {
        _fresh = r;
        _partial = r.transcription.cancelled;
        _stale = false;
        _text.text = r.transcription.text;
        _phase = _Phase.ready;
      });
    } on HandwritingException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.kind == HandwritingErrorKind.modelMissing) {
          _phase = _Phase.needModel;
        } else {
          _error = e.message;
          _phase = _Phase.error;
        }
      });
    }
  }

  Future<void> _download() async {
    setState(() => _phase = _Phase.downloading);
    final ok = await confirmAndDownloadModel(context, ref);
    if (!mounted) return;
    if (ok) {
      await _recognize();
    } else {
      final err = ref.read(handwritingModelProvider).error;
      setState(() {
        _error = err;
        _phase = _Phase.needModel;
      });
    }
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final svc = ref.read(handwritingServiceProvider);
    final fresh = _fresh;
    if (fresh != null) {
      await svc.savePage(widget.page.id, fresh, editedText: _text.text);
    } else {
      await svc.texts.updateText(widget.page.id, _text.text);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Sayfa metni kaydedildi.')));
    nav.pop();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Kopyalandı.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = ref.watch(handwritingModelProvider);
    final maxH = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_selection ? 'Seçimin metni' : 'Sayfa metni', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                ..._body(theme, model),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(ThemeData theme, HandwritingModelState model) {
    switch (_phase) {
      case _Phase.loading:
        return const [Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))];
      case _Phase.needModel:
        return [
          const Text('Yazıyı metne çevirmek için Türkçe el yazısı modeli gerekir (~20 MB, bir kez indirilir).'),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('page-text-download'),
            onPressed: _download,
            icon: const Icon(Icons.download_rounded),
            label: const Text('Modeli indir'),
          ),
        ];
      case _Phase.downloading:
        return [
          if (model.busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('Model indiriliyor… (ilerleme yüzdesi gösterilmez)'),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('page-text-download-cancel'),
                onPressed: () {
                  ref.read(handwritingModelProvider.notifier).cancelWaiting();
                  setState(() => _phase = _Phase.needModel);
                },
                child: const Text('Beklemeyi bırak'),
              ),
            ),
          ] else
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
        ];
      case _Phase.recognizing:
        return [
          LinearProgressIndicator(value: _total > 0 ? _done / _total : null, key: const Key('page-text-progress')),
          const SizedBox(height: 8),
          Text(_total > 0 ? 'Satır $_done / $_total okunuyor…' : 'Satırlar aranıyor…'),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('page-text-cancel'),
              onPressed: () => setState(() => _cancelled = true),
              child: const Text('İptal'),
            ),
          ),
        ];
      case _Phase.error:
        return [
          Text(_error ?? 'Metne çevrilemedi.', key: const Key('page-text-error'), style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 12),
          if (_canRecognize)
            FilledButton(key: const Key('page-text-retry'), onPressed: _recognize, child: const Text('Yeniden dene')),
        ];
      case _Phase.ready:
        final empty = _text.text.trim().isEmpty && _fresh == null && _saved == null;
        final failed = _fresh?.transcription.failedLines ?? 0;
        return [
          if (_stale)
            _Banner(
              key: const Key('page-text-stale'),
              icon: Icons.history_rounded,
              text: 'Sayfaya sonradan çizgi eklenmiş ya da değişmiş: bu metin güncel olmayabilir.',
              color: theme.colorScheme.tertiaryContainer,
            ),
          if (_partial)
            _Banner(icon: Icons.info_outline, text: 'İptal ettin: yalnız o ana kadar okunan satırlar var.', color: theme.colorScheme.secondaryContainer),
          if (failed > 0)
            _Banner(icon: Icons.warning_amber_rounded, text: '$failed satır okunamadı (boş bırakıldı).', color: theme.colorScheme.errorContainer),
          if (empty)
            Text(
              _canRecognize
                  ? 'Okunacak yazı bulunamadı.'
                  : 'Bu sayfanın metni yok. Tabletten ya da telefondan metne çevrilip eşitlenince burada görünür.',
              key: const Key('page-text-empty'),
            )
          else ...[
            TextField(
              key: const Key('page-text-field'),
              controller: _text,
              minLines: 4,
              maxLines: 14,
              decoration: const InputDecoration(border: OutlineInputBorder(), helperText: 'Yanlış okunan yerleri düzeltebilirsin.'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(key: const Key('page-text-copy'), onPressed: _copy, icon: const Icon(Icons.copy_rounded), label: const Text('Kopyala')),
              if (!_selection)
                FilledButton.icon(
                  key: const Key('page-text-save'),
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Kaydet (sayfa metni)'),
                ),
              if (_canRecognize)
                OutlinedButton.icon(
                  key: const Key('page-text-redo'),
                  onPressed: _recognize,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Yeniden tanı'),
                ),
            ]),
          ],
          if (empty && _canRecognize) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(key: const Key('page-text-redo'), onPressed: _recognize, icon: const Icon(Icons.refresh_rounded), label: const Text('Yeniden dene')),
          ],
        ];
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]),
      );
}
