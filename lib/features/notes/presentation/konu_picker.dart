import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/text/turkish_text.dart';
import '../../curriculum/curriculum_providers.dart';
import '../../curriculum/domain/curriculum.dart';

/// Konu -> o konuya bağlı silinmemiş sayfa sayısı (silinmemiş defterlerde).
final konuPageCountsProvider = StreamProvider.autoDispose<Map<String, int>>((
  ref,
) {
  final db = ref.watch(appDatabaseProvider);
  return db
      .customSelect(
        'SELECT p.konu_id AS k, COUNT(*) AS c FROM ink_note_pages p JOIN ink_notebooks n ON n.id = p.notebook_id '
        'WHERE p.konu_id IS NOT NULL AND p.deleted = 0 AND n.deleted = 0 GROUP BY p.konu_id',
        readsFrom: {db.inkNotePages, db.inkNotebooks},
      )
      .watch()
      .map(
        (rows) => {for (final r in rows) r.read<String>('k'): r.read<int>('c')},
      );
});

/// "TYT Fizik › Hareket › Hız"; konu ağaçta yoksa null.
String? konuPathLabel(String? konuId, List<CurriculumNode> nodes) {
  if (konuId == null) return null;
  final byId = {for (final n in nodes) n.id: n};
  var cur = byId[konuId];
  if (cur == null) return null;
  final subject = cur.subjectLabel;
  final titles = <String>[];
  final seen = <String>{};
  while (cur != null && seen.add(cur.id)) {
    titles.add(cur.title);
    cur = cur.parentId == null ? null : byId[cur.parentId];
  }
  return [subject, ...titles.reversed].join(' › ');
}

/// Konu seçici. Dönüş `null`: vazgeçildi; `(id: null)`: bağı kaldır; `(id: x)`: konu seçildi.
Future<({String? id})?> showKonuPicker(
  BuildContext context, {
  String? selectedId,
}) => showDialog<({String? id})>(
  context: context,
  builder: (_) => KonuPickerDialog(selectedId: selectedId),
);

class KonuPickerDialog extends ConsumerStatefulWidget {
  const KonuPickerDialog({super.key, this.selectedId});
  final String? selectedId;

  @override
  ConsumerState<KonuPickerDialog> createState() => _KonuPickerDialogState();
}

class _KonuPickerDialogState extends ConsumerState<KonuPickerDialog> {
  String _q = '';

  /// Düz satır listesi: ders başlığı (String) ve konu düğümleri.
  List<Object> _rows(List<CurriculumNode> nodes) {
    final q = normalizeTr(_q);
    if (q.isNotEmpty) {
      return [
        for (final n in nodes)
          if (normalizeTr('${n.title} ${n.aliases.join(' ')} ${n.subjectLabel}')
              .contains(q))
            n,
      ];
    }
    final groups = <String, List<CurriculumNode>>{};
    for (final n in nodes) {
      (groups[n.subjectLabel] ??= []).add(n);
    }
    return [
      for (final e in groups.entries) ...[e.key, ...depthFirst(e.value)],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final nodes =
        ref.watch(curriculumProvider).value ?? const <CurriculumNode>[];
    final counts =
        ref.watch(konuPageCountsProvider).value ?? const <String, int>{};
    final rows = _rows(nodes);
    final h = MediaQuery.sizeOf(context).height;
    return AlertDialog(
      title: const Text('Konu seç'),
      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      content: SizedBox(
        width: 420,
        height: (h * 0.6).clamp(200, 520),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('konu-search'),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Konu ya da ders ara',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('Konu bulunamadı.'))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        if (r is String) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              r,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          );
                        }
                        final n = r as CurriculumNode;
                        final c = counts[n.id] ?? 0;
                        return ListTile(
                          key: Key('konu-${n.id}'),
                          dense: true,
                          contentPadding: EdgeInsets.only(
                            left: 16.0 + (_q.isEmpty ? n.depth * 16 : 0),
                            right: 16,
                          ),
                          title: Text(n.title),
                          subtitle: _q.isEmpty ? null : Text(n.subjectLabel),
                          selected: n.id == widget.selectedId,
                          trailing: c == 0
                              ? null
                              : Text(
                                  '$c sayfa',
                                  key: Key('konu-count-${n.id}'),
                                ),
                          onTap: () => Navigator.pop(context, (id: n.id)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.selectedId != null)
          TextButton(
            key: const Key('konu-clear'),
            onPressed: () => Navigator.pop(context, (id: null)),
            child: const Text('Konuyu kaldır'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Vazgeç'),
        ),
      ],
    );
  }
}
