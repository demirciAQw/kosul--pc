import 'package:flutter/material.dart';

import '../domain/book_analysis.dart';
import 'analysis_overlay.dart' show analysisColor;

/// "Yanlışlarım" paneli: kitabın sorularını test test listeler; süzgeç
/// (Yanlış / Boş / Hepsi); dokununca PDF'te sayfaya gider.
class PdfAnalysisPanel extends StatelessWidget {
  const PdfAnalysisPanel({
    super.key,
    required this.analysis,
    required this.filter,
    required this.onFilter,
    required this.onGo,
    required this.onClose,
  });

  final BookAnalysis analysis;
  final AnalysisFilter filter;
  final ValueChanged<AnalysisFilter> onFilter;
  final void Function(AnalysisItem item) onGo;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tests = analysis.filtered(filter);
    return Material(
      key: const Key('analysis-panel'),
      elevation: 6,
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text('Yanlışlarım', style: theme.textTheme.titleMedium)),
                IconButton(
                  key: const Key('analysis-panel-close'),
                  tooltip: 'Kapat',
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SegmentedButton<AnalysisFilter>(
              showSelectedIcon: false,
              segments: [
                for (final f in AnalysisFilter.values)
                  ButtonSegment(value: f, label: Text(f.label), tooltip: f.label, icon: null),
              ],
              selected: {filter},
              onSelectionChanged: (s) => onFilter(s.first),
            ),
          ),
          const Divider(height: 12),
          Expanded(
            child: tests.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Bu süzgeçte soru yok.',
                        key: const Key('analysis-empty'),
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final t in tests) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${t.title} (${t.items.length})', style: theme.textTheme.titleSmall),
                              if (t.path.isNotEmpty)
                                Text(
                                  t.path,
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                ),
                            ],
                          ),
                        ),
                        for (final i in t.items)
                          ListTile(
                            key: Key('analysis-item-${i.cardId}'),
                            dense: true,
                            enabled: i.pdfPage != null,
                            leading: CircleAvatar(
                              radius: 12,
                              backgroundColor: analysisColor(i.status),
                              child: Text(
                                i.questionNo?.toString() ?? '?',
                                style: const TextStyle(color: Colors.white, fontSize: 11),
                              ),
                            ),
                            title: Text(i.status.label),
                            subtitle: Text(i.pdfPage == null ? 'sayfa bilinmiyor' : 'PDF sayfa ${i.pdfPage! + 1}'),
                            onTap: i.pdfPage == null ? null : () => onGo(i),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
