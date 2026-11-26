import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// Pano araç çubuğu (üstte, yatay kaydırılır: telefonda taşmaz).
class BoardToolbar extends StatelessWidget {
  const BoardToolbar({
    super.key,
    required this.zoom,
    required this.linkMode,
    required this.onLinkMode,
    required this.onArrange,
    required this.onFit,
    required this.onNewPage,
    required this.onSearch,
    required this.onZoomReset,
  });

  /// Ölçek (1 = %100).
  final ValueListenable<double> zoom;
  final bool linkMode;
  final ValueChanged<bool> onLinkMode;
  final VoidCallback onArrange;
  final VoidCallback onFit;
  final VoidCallback onNewPage;
  final ValueChanged<String> onSearch;
  final VoidCallback onZoomReset;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 170,
              height: 40,
              child: TextField(
                key: const Key('board-search'),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: 'Sayfa ara',
                  border: OutlineInputBorder(),
                ),
                onChanged: onSearch,
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              key: const Key('board-new'),
              onPressed: onNewPage,
              icon: const Icon(Icons.add),
              label: const Text('Yeni sayfa'),
            ),
            TextButton.icon(
              key: const Key('board-arrange'),
              onPressed: onArrange,
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: const Text('Otomatik düzenle'),
            ),
            TextButton.icon(
              key: const Key('board-fit'),
              onPressed: onFit,
              icon: const Icon(Icons.fit_screen_outlined),
              label: const Text('Sığdır'),
            ),
            ValueListenableBuilder<double>(
              valueListenable: zoom,
              builder: (_, z, __) => TextButton(
                key: const Key('board-zoom'),
                onPressed: onZoomReset,
                child: Text('%${(z * 100).round()}'),
              ),
            ),
            const SizedBox(width: 8),
            const Text('Bağlantı modu'),
            Switch(key: const Key('board-link-mode'), value: linkMode, onChanged: onLinkMode),
          ],
        ),
      ),
    );
  }
}
