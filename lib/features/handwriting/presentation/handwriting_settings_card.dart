import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/handwriting_recognizer.dart';
import '../handwriting_providers.dart';
import 'model_download.dart';

/// Ayarlar: "El yazısı tanıma" kartı. Tanıma olmayan cihazda (masaüstü) görünmez.
class HandwritingSettingsCard extends ConsumerWidget {
  const HandwritingSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(handwritingAvailableProvider)) return const SizedBox.shrink();
    final st = ref.watch(handwritingModelProvider);
    final ctl = ref.read(handwritingModelProvider.notifier);
    final theme = Theme.of(context);
    final downloaded = st.status == HandwritingModelStatus.downloaded;
    final status = switch (st.status) {
      null => 'Kontrol ediliyor…',
      HandwritingModelStatus.downloaded => 'Türkçe model: indirildi',
      HandwritingModelStatus.notDownloaded => 'Türkçe model: indirilmedi',
      HandwritingModelStatus.unsupported => 'Bu cihazda desteklenmiyor',
    };
    return Card(
      key: const Key('hw-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.text_fields_rounded),
              const SizedBox(width: 12),
              Expanded(child: Text('El yazısı tanıma', style: theme.textTheme.titleMedium)),
            ]),
            const SizedBox(height: 4),
            Text(
              'Defter sayfalarındaki kalem yazını düz yazıya çevirir. Metin ayrı kaydedilir; çizgilerin değişmez.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(status, key: const Key('hw-status')),
            if (st.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(st.error!, key: const Key('hw-error'), style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 8),
            if (st.busy) ...[
              const LinearProgressIndicator(key: Key('hw-progress')),
              const SizedBox(height: 4),
              Text('İşleniyor… (ilerleme yüzdesi gösterilmez)', style: theme.textTheme.bodySmall),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('hw-cancel'),
                  onPressed: ctl.cancelWaiting,
                  child: const Text('Beklemeyi bırak'),
                ),
              ),
            ] else if (st.status != HandwritingModelStatus.unsupported && st.status != null)
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (!downloaded)
                  FilledButton.icon(
                    key: const Key('hw-download'),
                    onPressed: () => confirmAndDownloadModel(context, ref),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Türkçe modeli indir (~20 MB, internet gerekir)'),
                  ),
                if (downloaded)
                  OutlinedButton.icon(
                    key: const Key('hw-delete'),
                    onPressed: () => _confirmDelete(context, ctl),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Modeli sil'),
                  ),
              ]),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, HandwritingModelController ctl) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Model silinsin mi?'),
        content: const Text('Kayıtlı metinlerin ve çizgilerin silinmez. Yeniden metne çevirmek için modeli tekrar indirmen gerekir.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const Key('hw-delete-confirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) await ctl.delete();
  }
}
