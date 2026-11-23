import 'package:flutter/material.dart';

import '../domain/page_layer.dart';
import 'layer_overlay.dart';

/// Panelden okuyucuya dönen istek.
sealed class LayersPanelAction {
  const LayersPanelAction();
}

/// Yeni filigran temizleme katmanı: kapsam [scope] (bu sayfa / bölge / tüm sayfalar).
class AddWatermarkAction extends LayersPanelAction {
  const AddWatermarkAction(this.scope, {this.secondLayer = false});
  final PdfLayerScope scope;
  final bool secondLayer;
}

/// Yeni örtü katmanı (bölge ya da tüm sayfa).
class AddCoverAction extends LayersPanelAction {
  const AddCoverAction(this.scope);
  final PdfLayerScope scope;
}

/// Var olan katmanın ayarını düzenle.
class EditLayerAction extends LayersPanelAction {
  const EditLayerAction(this.layer);
  final PdfPageLayer layer;
}

String layerScopeLabel(PdfPageLayer l) => switch (l.scope) {
      PdfLayerScope.thisPage => 'Bu sayfa',
      PdfLayerScope.allPages => 'Tüm sayfalar',
      PdfLayerScope.region => 'Seçili bölge',
      PdfLayerScope.regionAllPages => 'Bölge, tüm sayfalar',
    };

/// "Filigran / Katmanlar" panelini alttan sheet olarak açar. Sonuç, okuyucunun
/// yapacağı iş ([LayersPanelAction]) ya da null.
Future<LayersPanelAction?> showPdfLayersPanel(BuildContext context, {required PdfLayersHub hub, required int page}) {
  return showModalBottomSheet<LayersPanelAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => PdfLayersPanel(hub: hub, page: page),
  );
}

class PdfLayersPanel extends StatefulWidget {
  const PdfLayersPanel({super.key, required this.hub, required this.page});
  final PdfLayersHub hub;

  /// 0'dan.
  final int page;

  @override
  State<PdfLayersPanel> createState() => _PdfLayersPanelState();
}

class _PdfLayersPanelState extends State<PdfLayersPanel> {
  PdfLayersHub get hub => widget.hub;
  int get page => widget.page;

  /// Son silinen katman: panelde "Geri al" satırı (iletiler sheet'in altında kalır).
  PdfPageLayer? _deleted;

  Future<void> _confirmDelete(BuildContext context, PdfPageLayer l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Katman silinsin mi?'),
        content: Text('"${l.name}" kaldırılır. PDF dosyası değişmez; sonra geri alabilirsin.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(key: const Key('layer-del-confirm'), onPressed: () => Navigator.pop(c, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true) return;
    await hub.repository.softDelete(l.id);
    if (mounted) setState(() => _deleted = l);
  }

  Future<void> _undoDelete() async {
    final l = _deleted;
    if (l == null) return;
    await hub.repository.restore(l.id);
    if (mounted) setState(() => _deleted = null);
  }

  Future<void> _move(PdfPageLayer l, int delta) async {
    final ids = [for (final x in hub.listFor(page)) x.id];
    final i = ids.indexOf(l.id), j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return;
    ids.insert(j, ids.removeAt(i));
    await hub.repository.reorder(ids);
  }

  Future<void> _second(BuildContext context) async {
    final a = await showDialog<LayersPanelAction>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('2. katman ekle'),
        children: [
          SimpleDialogOption(
            key: const Key('second-wm-region'),
            onPressed: () => Navigator.pop(c, const AddWatermarkAction(PdfLayerScope.region, secondLayer: true)),
            child: const Text('Başka bölgede filigran temizle'),
          ),
          SimpleDialogOption(
            key: const Key('second-wm-tone'),
            onPressed: () => Navigator.pop(c, const AddWatermarkAction(PdfLayerScope.thisPage, secondLayer: true)),
            child: const Text('Başka tonla filigran temizle (tüm sayfa)'),
          ),
          SimpleDialogOption(
            key: const Key('second-cover'),
            onPressed: () => Navigator.pop(c, const AddCoverAction(PdfLayerScope.region)),
            child: const Text('Örtü ekle (renk + saydamlık)'),
          ),
        ],
      ),
    );
    if (a != null && context.mounted) Navigator.pop(context, a);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: ValueListenableBuilder<List<PdfPageLayer>>(
          valueListenable: hub.layers,
          builder: (context, _, _) {
            final list = hub.listFor(page);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Filigran / Katmanlar', style: t.titleLarge),
                const SizedBox(height: 4),
                Text('Sayfa ${page + 1}. PDF dosyası değişmez; katmanlar yalnızca görünümdür.', style: t.bodySmall),
                ValueListenableBuilder<bool>(
                  valueListenable: hub.showOriginal,
                  builder: (_, v, _) => SwitchListTile(
                    key: const Key('layers-show-original'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Orijinali göster'),
                    subtitle: const Text('Katmanları geçici gizler'),
                    value: v,
                    onChanged: (x) => hub.showOriginal.value = x,
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: list.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(child: Text('Bu sayfada katman yok.', key: Key('layers-empty'))),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (var i = 0; i < list.length; i++) _tile(context, list[i], i, list.length),
                          ],
                        ),
                ),
                if (_deleted != null)
                  ListTile(
                    key: const Key('layer-deleted-row'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_outline),
                    title: Text('"${_deleted!.name}" silindi.'),
                    trailing: TextButton(key: const Key('layer-undo'), onPressed: _undoDelete, child: const Text('Geri al')),
                  ),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Text('Filigranı temizle', style: t.titleSmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonal(
                      key: const Key('layers-add-page'),
                      onPressed: () => Navigator.pop(context, const AddWatermarkAction(PdfLayerScope.thisPage)),
                      child: const Text('Tüm sayfa'),
                    ),
                    FilledButton.tonal(
                      key: const Key('layers-add-region'),
                      onPressed: () => Navigator.pop(context, const AddWatermarkAction(PdfLayerScope.region)),
                      child: const Text('Seçili bölge'),
                    ),
                    FilledButton.tonal(
                      key: const Key('layers-add-all'),
                      onPressed: () => Navigator.pop(context, const AddWatermarkAction(PdfLayerScope.allPages)),
                      child: const Text('Tüm sayfalarda'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('layers-add-second'),
                  onPressed: () => _second(context),
                  icon: const Icon(Icons.layers_outlined),
                  label: const Text('2. katman ekle'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, PdfPageLayer l, int i, int n) {
    return ListTile(
      key: Key('layer-${l.id}'),
      contentPadding: EdgeInsets.zero,
      leading: IconButton(
        key: Key('layer-eye-${l.id}'),
        tooltip: l.visible ? 'Gizle' : 'Göster',
        icon: Icon(l.visible ? Icons.visibility : Icons.visibility_off),
        onPressed: () => hub.repository.setVisible(l.id, !l.visible),
      ),
      title: Text(l.name, style: l.visible ? null : TextStyle(color: Theme.of(context).disabledColor)),
      subtitle: Text('${l.kind.label} · ${layerScopeLabel(l)}'),
      onTap: () => Navigator.pop(context, EditLayerAction(l)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('layer-up-${l.id}'),
            tooltip: 'Üste al',
            icon: const Icon(Icons.arrow_upward),
            onPressed: i == n - 1 ? null : () => _move(l, 1),
          ),
          IconButton(
            key: Key('layer-down-${l.id}'),
            tooltip: 'Alta al',
            icon: const Icon(Icons.arrow_downward),
            onPressed: i == 0 ? null : () => _move(l, -1),
          ),
          IconButton(
            key: Key('layer-del-${l.id}'),
            tooltip: 'Sil',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, l),
          ),
        ],
      ),
    );
  }
}
