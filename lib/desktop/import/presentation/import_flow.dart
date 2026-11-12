import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../data/import_service.dart';
import '../import_providers.dart';
import 'import_summary_dialog.dart';

/// Süren içe aktarmanın mesajı; boştaysa null. Aynı anda tek içe aktarma olur
/// (elle ya da izlenen klasörden).
class ImportBusy extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;
}

final importBusyProvider = NotifierProvider<ImportBusy, String?>(ImportBusy.new);

/// Dosya seçiciyle ZIP ya da açılmış yedek klasörü seçip içe aktarır.
Future<void> pickAndImport(BuildContext context, WidgetRef ref, {required bool folder}) async {
  final String? path;
  if (folder) {
    path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Açılmış Koçum yedeği klasörünü seç');
  } else {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Koçum yedeğini seç (ZIP)',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    path = result?.files.single.path;
  }
  if (path == null || !context.mounted) return;
  await importBackupFrom(context, path);
}

/// Hazırla → (eski yedekse sor) → birleştir → özet. Sayfa değişse de iş
/// yarıda kalmasın diye uygulamanın sağlayıcı kabı kullanılır.
Future<void> importBackupFrom(BuildContext context, String path) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final busy = container.read(importBusyProvider.notifier);
  if (container.read(importBusyProvider) != null) return;
  final service = container.read(importServiceProvider);
  busy.set('Yedek okunuyor…');
  PreparedImport? job;
  try {
    job = await service.prepare(path);
    if (job.isOlder) {
      busy.set(null);
      if (!context.mounted) return;
      final ok = await _confirmOlder(context, job) == true;
      if (!ok) return;
    }
    busy.set('İçe aktarılıyor: ${job.label}');
    final current = job;
    job = null; // run() kendisi temizler
    final summary = await service.run(current);
    container
      ..invalidate(importHistoryProvider)
      ..invalidate(tombstonesProvider);
    busy.set(null);
    if (context.mounted) {
      await showDialog<void>(context: context, builder: (_) => ImportSummaryDialog(summary: summary));
    }
  } on Exception catch (e) {
    busy.set(null);
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.error_outline),
          title: const Text('İçe aktarılamadı'),
          content: Text('$e'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tamam'))],
        ),
      );
    }
  } finally {
    final left = job;
    if (left != null) await service.discard(left);
    busy.set(null);
  }
}

Future<bool?> _confirmOlder(BuildContext context, PreparedImport job) {
  final exported = job.exportedAt;
  final last = job.lastImported;
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.history),
      title: const Text('Bu yedek daha eski'),
      content: Text(
        'Seçtiğin yedek telefonda ${exported == null ? '?' : formatShortDate(exported)} tarihinde alınmış; '
        'bilgisayardaki veri ${last == null ? '?' : formatShortDate(last)} tarihli yedekten.\n\n'
        'Eski yedeği almak, güncel kayıtları eski hâlleriyle değiştirir ve sonradan eklenenleri '
        '"telefonda silindi" gösterir. Hiçbir kayıt silinmez.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yine de içe aktar')),
      ],
    ),
  );
}
