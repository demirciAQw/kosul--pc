import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/huawei_zip_parser.dart';
import '../health_providers.dart';

/// Huawei Sağlık "Verilerini iste" ZIP'i (ya da açılmış klasör): önce YAPI RAPORU
/// (yalnız dosya/alan adları), sonra tahmine dayalı ayrıştırma, önizleme, onay.
class HuaweiImportScreen extends ConsumerStatefulWidget {
  const HuaweiImportScreen({super.key});

  @override
  ConsumerState<HuaweiImportScreen> createState() => _HuaweiImportScreenState();
}

class _HuaweiImportScreenState extends ConsumerState<HuaweiImportScreen> {
  List<HuaweiFile>? _files;
  HuaweiParseResult? _result;
  String? _report;
  String? _error;
  bool _busy = false;
  String? _done;

  Future<void> _load(Future<List<HuaweiFile>> Function() read) async {
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
      _files = null;
      _result = null;
      _report = null;
    });
    try {
      final files = await read();
      final structure = describeHuaweiStructure(files);
      if (!mounted) return;
      setState(() {
        _files = files;
        _report = structureReportText(structure);
        _result = parseHuaweiFiles(files);
      });
    } on FileSystemException catch (e) {
      _error = 'Dosya okunamadı: ${e.message}';
    } catch (e) {
      _error = 'ZIP açılamadı: $e. Şifreli ZIP desteklenmez; Huawei\'nin gönderdiği şifreyle önce açıp klasörü seç.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickZip() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final path = r?.files.single.path;
    if (path == null) return;
    await _load(() => ref.read(huaweiImportServiceProvider).readZip(File(path)));
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Açılmış Huawei veri klasörünü seç');
    if (path == null) return;
    await _load(() => ref.read(huaweiImportServiceProvider).readFolder(Directory(path)));
  }

  Future<void> _import() async {
    final r = _result;
    if (r == null || r.isEmpty) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(huaweiImportServiceProvider).import(r);
      if (mounted) setState(() => _done = '$n günün verisi kaydedildi. Aynı dosyayı tekrar almak çift kayıt yapmaz.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Huawei verisi içe aktar')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Huawei Sağlık > Ben > Gizlilik > "Verilerini iste" ile gelen ZIP\'i seç. DİKKAT: Huawei bu dosyanın '
            'iç yapısını belgelemiyor; Koçum şemayı BİLMİYOR ve olası alan adlarını tahmin eder. Önce yapı raporuna '
            'bak; hiçbir şey bulunamazsa raporu kopyalayıp göster, ayrıştırıcı ona göre uyarlanır. Stres verisi '
            'dosyada olmayabilir.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              key: const Key('huawei-pick-zip'),
              onPressed: _busy ? null : _pickZip,
              icon: const Icon(Icons.folder_zip_outlined),
              label: const Text('ZIP seç'),
            ),
            OutlinedButton.icon(
              key: const Key('huawei-pick-folder'),
              onPressed: _busy ? null : _pickFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Klasör seç'),
            ),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, key: const Key('huawei-error'), style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (r != null) ...[
            const SizedBox(height: 16),
            Text('Önizleme', style: theme.textTheme.titleMedium),
            Text(r.preview(), key: const Key('huawei-preview')),
            if (r.isEmpty) ...[
              const SizedBox(height: 4),
              Text(r.notes.join('\n'), key: const Key('huawei-why')),
            ] else
              for (final n in r.notes) Text(n, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('huawei-import'),
              onPressed: _busy || r.isEmpty || _done != null ? null : _import,
              child: const Text('İçe aktar'),
            ),
            if (_done != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_done!, key: const Key('huawei-done'))),
          ],
          if (_report != null) ...[
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: Text('Yapı raporu (${_files?.length ?? 0} dosya)', style: theme.textTheme.titleMedium)),
              TextButton.icon(
                key: const Key('huawei-copy'),
                icon: const Icon(Icons.copy),
                label: const Text('Kopyala'),
                onPressed: () async {
                  final m = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: _report!));
                  m.showSnackBar(const SnackBar(content: Text('Yapı raporu kopyalandı (değer yok, yalnız ad).')));
                },
              ),
            ]),
            Text('Yalnız dosya ve alan adları; kişisel DEĞER içermez.', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            SelectableText(_report!, key: const Key('huawei-report'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ],
      ),
    );
  }
}
