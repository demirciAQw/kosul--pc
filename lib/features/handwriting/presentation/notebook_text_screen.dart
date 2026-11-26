import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/platform.dart';
import '../../../core/text/turkish_text.dart';
import '../../notes/notes_providers.dart';
import '../data/page_text_repository.dart';
import '../domain/handwriting_recognizer.dart';
import '../domain/transcript.dart';
import '../handwriting_providers.dart';
import 'model_download.dart';

/// Defterin metin kopyası: tüm sayfaların kayıtlı el yazısı metni sırayla. Masaüstünde
/// de görünür (eşitlemeyle gelir); tanıma düğmeleri yalnız tanıma olan cihazda.
class NotebookTextScreen extends ConsumerStatefulWidget {
  const NotebookTextScreen({super.key, required this.notebookId});
  final String notebookId;

  @override
  ConsumerState<NotebookTextScreen> createState() => _NotebookTextScreenState();
}

class _NotebookTextScreenState extends ConsumerState<NotebookTextScreen> {
  bool _running = false;
  bool _cancel = false;
  int _done = 0, _total = 0;
  String? _error;

  String _title() {
    final nb = ref.read(inkNotebooksProvider).value?.where((n) => n.id == widget.notebookId).firstOrNull;
    return nb == null || nb.title.isEmpty ? 'Adsız defter' : nb.title;
  }

  String _fullText(List<({String pageId, int pageNumber, PageTextRecord? text})> entries) => assembleNotebookText([
        for (final e in entries) PageTextEntry(pageNumber: e.pageNumber, text: e.text?.text ?? ''),
      ], title: _title());

  void _msg(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _copy(String text) async {
    if (text.trim().isEmpty) return _msg('Henüz kayıtlı metin yok.');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _msg('Kopyalandı.');
  }

  /// `.txt`: telefon/tablette paylaş, masaüstünde dosya olarak kaydet.
  Future<void> _export(String text) async {
    if (text.trim().isEmpty) return _msg('Henüz kayıtlı metin yok.');
    final name = '${safeName(_title())}_metin.txt';
    try {
      if (isDesktop) {
        final path = await FilePicker.platform.saveFile(dialogTitle: 'Metin kopyasını kaydet', fileName: name);
        if (path == null) return;
        await File(path).writeAsString(text, flush: true);
        if (mounted) _msg('Kaydedildi: $path');
      } else {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/$name');
        await f.writeAsString(text, flush: true);
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'text/plain')], subject: name));
      }
    } on Exception catch (e) {
      if (mounted) _msg('Dışa aktarılamadı: $e');
    }
  }

  /// Dosya adı: Türkçe harfler sadeleşir, boşluk alt çizgi olur.
  static String safeName(String s) {
    final n = normalizeTr(s).replaceAll(' ', '_');
    return n.isEmpty ? 'defter' : (n.length > 40 ? n.substring(0, 40) : n);
  }

  Future<void> _recognizeAll(List<({String pageId, int pageNumber, PageTextRecord? text})> entries) async {
    final svc = ref.read(handwritingServiceProvider);
    final status = await svc.recognizer.modelStatus();
    if (!mounted) return;
    if (status == HandwritingModelStatus.notDownloaded) {
      final ok = await confirmAndDownloadModel(context, ref);
      if (!ok || !mounted) {
        final err = ref.read(handwritingModelProvider).error;
        if (err != null && mounted) _msg(err);
        return;
      }
    }
    final pages = {for (final p in await ref.read(inkNotebookRepositoryProvider).pages(widget.notebookId)) p.id: p};
    final todo = [for (final e in entries) if (e.text == null && pages[e.pageId] != null) pages[e.pageId]!];
    if (todo.isEmpty) return _msg('Tanınacak sayfa yok.');
    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
      _total = todo.length;
      _error = null;
    });
    var saved = 0, empty = 0;
    try {
      for (final page in todo) {
        if (_cancel || !mounted) break;
        final r = await svc.recognizePage(page, isCancelled: () => _cancel || !mounted);
        if (r.transcription.cancelled) break;
        if (r.transcription.text.trim().isEmpty) {
          empty++; // boş sayfa: kayıt açılmaz
        } else {
          await svc.savePage(page.id, r);
          saved++;
        }
        if (mounted) setState(() => _done++);
      }
    } on HandwritingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (mounted && _error == null) {
      _msg(_cancel ? 'İptal edildi: $saved sayfa kaydedildi.' : '$saved sayfa metne çevrildi${empty > 0 ? ' ($empty sayfa boş)' : ''}.');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(inkNotebooksProvider); // başlık için canlı tutulur (_title okur)
    final texts = ref.watch(notebookTextsProvider(widget.notebookId));
    final stale = ref.watch(staleTextPagesProvider(widget.notebookId)).value ?? const <String>{};
    final available = ref.watch(handwritingAvailableProvider);
    final theme = Theme.of(context);
    return texts.when(
      loading: () => Scaffold(appBar: AppBar(title: const Text('Defterin metin kopyası')), body: const Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(title: const Text('Defterin metin kopyası')), body: Center(child: Text('Okunamadı: $e'))),
      data: (entries) {
        final full = _fullText(entries);
        final missing = entries.where((e) => e.text == null).length;
        return Scaffold(
          appBar: AppBar(
            title: Text('Metin kopyası · ${_title()}', overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(key: const Key('nbtext-copy'), tooltip: 'Kopyala', icon: const Icon(Icons.copy_rounded), onPressed: () => _copy(full)),
              IconButton(key: const Key('nbtext-export'), tooltip: 'Dışa aktar (.txt)', icon: const Icon(Icons.ios_share_rounded), onPressed: () => _export(full)),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (available && missing > 0)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('$missing sayfanın metni yok.', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      if (_running) ...[
                        LinearProgressIndicator(key: const Key('nbtext-progress'), value: _total > 0 ? _done / _total : null),
                        const SizedBox(height: 4),
                        Text('Sayfa $_done / $_total'),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(key: const Key('nbtext-cancel'), onPressed: () => setState(() => _cancel = true), child: const Text('İptal')),
                        ),
                      ] else
                        FilledButton.icon(
                          key: const Key('nbtext-all'),
                          onPressed: () => _recognizeAll(entries),
                          icon: const Icon(Icons.text_fields_rounded),
                          label: const Text('Tümünü tanı'),
                        ),
                      if (_error != null) Text(_error!, key: const Key('nbtext-error'), style: TextStyle(color: theme.colorScheme.error)),
                    ]),
                  ),
                ),
              for (final e in entries) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Text('Sayfa ${e.pageNumber}', style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  if (e.text == null)
                    Text('metin yok', style: theme.textTheme.bodySmall)
                  else if (stale.contains(e.pageId))
                    Chip(
                      key: Key('nbtext-stale-${e.pageId}'),
                      visualDensity: VisualDensity.compact,
                      label: const Text('güncel değil'),
                    ),
                ]),
                if (e.text != null && e.text!.text.trim().isNotEmpty)
                  SelectableText(e.text!.text, key: Key('nbtext-page-${e.pageId}'))
                else if (e.text != null)
                  Text('(boş)', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        );
      },
    );
  }
}
