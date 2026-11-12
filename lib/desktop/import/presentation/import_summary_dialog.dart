import 'package:flutter/material.dart';

import '../../../app/palette.dart';
import '../../../core/utils/formatters.dart';
import '../domain/import_models.dart';

/// İçe aktarma sonrası özet: tablo tablo yeni / güncellenen / telefonda silinen.
class ImportSummaryDialog extends StatelessWidget {
  const ImportSummaryDialog({super.key, required this.summary});

  final ImportSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final exported = summary.exportedAt;
    return AlertDialog(
      icon: const Icon(Icons.download_done),
      title: const Text('Telefon verisi alındı'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${summary.source}${exported == null ? '' : ' · telefonda ${formatShortDate(exported)}'}',
                style: muted,
              ),
              const SizedBox(height: 12),
              ImportSummaryTable(summary: summary),
              const SizedBox(height: 12),
              Text('Fotoğraflar: ${summary.photosAdded} yeni, ${summary.photosSkipped} zaten vardı.'),
              const SizedBox(height: 6),
              Text(
                'Çakışma yok: bilgisayarda bu verilerde düzenleme yapılmadığı için telefondaki hâli esas alındı.',
                style: muted,
              ),
              if (summary.totalMissing > 0) ...[
                const SizedBox(height: 6),
                Text(
                  'Telefonda silinen ${summary.totalMissing} kayıt bilgisayarda duruyor. '
                  'Ayarlar → Telefonda silinenler bölümünden silebilirsin.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: KocumColors.amber),
                ),
              ],
              for (final w in summary.warnings) ...[
                const SizedBox(height: 6),
                Text(w, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tamam'))],
    );
  }
}

/// Değişen ya da dolu tablolar; önem sırasıyla.
class ImportSummaryTable extends StatelessWidget {
  const ImportSummaryTable({super.key, required this.summary});

  final ImportSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = [
      for (final name in tableLabels.keys)
        if (summary.table(name) case final t? when t.total > 0 || t.missingIds.isNotEmpty) t,
    ];
    if (rows.isEmpty) return const Text('Yedekte kayıt yok.');
    TableRow row(List<String> cells, {bool header = false}) => TableRow(children: [
          for (final (i, c) in cells.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
              child: Text(
                c,
                textAlign: i == 0 ? TextAlign.start : TextAlign.end,
                style: header ? theme.textTheme.labelMedium : theme.textTheme.bodyMedium,
              ),
            ),
        ]);
    return Table(
      columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(), 2: FlexColumnWidth(), 3: FlexColumnWidth(1.4)},
      border: TableBorder(horizontalInside: BorderSide(color: theme.dividerColor)),
      children: [
        row(const ['', 'Yeni', 'Güncellenen', 'Telefonda silinen'], header: true),
        for (final t in rows)
          row([tableLabel(t.table), '${t.added}', '${t.updated}', '${t.missingIds.length}']),
      ],
    );
  }
}
