import 'package:flutter/material.dart';

import '../../notes/presentation/note_tool_dock.dart' show NoteToolSizeSection;
import '../../notes/presentation/note_tool_settings.dart';
import 'pdf_layer_state.dart';

/// Soldaki katman hapının ve bölge düğmesinin ayarları: "Numarayı göster",
/// "Bölge seçme düğmesini göster" ve kalem boyutu (ortak boyut bileşeni).
class PdfLayerNavSettings extends StatelessWidget {
  const PdfLayerNavSettings({super.key, required this.state, required this.tools});

  final PdfLayerState state;
  final NoteToolSettings tools;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Katman gezinme', style: Theme.of(context).textTheme.titleSmall),
        ListenableBuilder(
          listenable: state,
          builder: (_, _) => SwitchListTile(
            key: const Key('layer-show-number'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Numarayı göster'),
            value: state.showNumber,
            onChanged: state.setShowNumber,
          ),
        ),
        ListenableBuilder(
          listenable: state,
          builder: (_, _) => SwitchListTile(
            key: const Key('layer-show-region-button'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Bölge seçme düğmesini göster'),
            value: state.regionButtonVisible,
            onChanged: state.setRegionVisible,
          ),
        ),
        const SizedBox(height: 4),
        Text('Kalem boyutu', style: Theme.of(context).textTheme.labelLarge),
        NoteToolSizeSection(tools: tools),
      ],
    );
  }
}
