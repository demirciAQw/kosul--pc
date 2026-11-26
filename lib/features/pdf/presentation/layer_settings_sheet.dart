import 'package:flutter/material.dart';

import '../../notes/presentation/note_tool_settings.dart';
import '../domain/page_layer.dart';
import 'layer_nav_settings.dart';
import 'pdf_layer_state.dart';

/// Katman ayarları (üst çubuk katman düğmesinin ve katman/bölge düğmelerinin uzun basışı):
/// "Katman türü" ve [PdfLayerNavSettings].
Future<void> showPdfLayerSettings(BuildContext context, PdfLayerState state, NoteToolSettings tools) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Katman ayarları', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text('Katman türü', style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Üst çubuktaki katman düğmesine ve soldaki "+" düğmesine basınca hangisinin ekleneceğini belirler.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: state,
              builder: (_, _) => SegmentedButton<PdfLayerKind>(
                key: const Key('layer-type'),
                segments: [
                  for (final k in PdfLayerKind.values) ButtonSegment(value: k, label: Text(k.label)),
                ],
                selected: {state.addType},
                onSelectionChanged: (s) => state.setAddType(s.first),
              ),
            ),
            const Divider(height: 28),
            PdfLayerNavSettings(state: state, tools: tools),
          ],
        ),
      ),
    ),
  );
}
