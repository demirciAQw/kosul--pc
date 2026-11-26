import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../handwriting_providers.dart';

/// İndirme onayı (veri kullanımı uyarısı + yalnız Wi-Fi seçeneği), onaylanırsa indirir.
/// İndirildi mi döner; vazgeçildiyse ya da hata olduysa false (hata durumda
/// [handwritingModelProvider] içinde).
Future<bool> confirmAndDownloadModel(BuildContext context, WidgetRef ref) async {
  var wifiOnly = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Türkçe el yazısı modeli indirilsin mi?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Yaklaşık 20 MB indirilir ve internet gerekir (mobil veri kullanabilir). '
              'Bir kez indirilir. Yazıyı metne çevirme cihazda yapılır; çizgiler dışarı gönderilmez.',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('hw-wifi-only'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: wifiOnly,
              onChanged: (v) => setState(() => wifiOnly = v ?? true),
              title: const Text('Yalnız Wi-Fi ile indir'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(
            key: const Key('hw-download-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('İndir'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  return ref.read(handwritingModelProvider.notifier).download(wifiOnly: wifiOnly);
}
