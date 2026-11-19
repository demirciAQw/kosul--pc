import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../../features/curriculum/domain/yks.dart';
import '../../features/mock_exam/data/karne_pdf_reader.dart';
import '../../features/mock_exam/domain/karne_import.dart';
import '../../features/mock_exam/domain/karne_parser.dart';
import '../../features/mock_exam/domain/mock_exam.dart';
import '../../features/mock_exam/mock_exam_providers.dart';
import '../widgets/desktop_page.dart';

class DesktopExamSelection extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final desktopExamSelectionProvider = NotifierProvider<DesktopExamSelection, String?>(DesktopExamSelection.new);

/// Denemeler: elle deneme gir, karne PDF'lerini içe aktar, sonuçları düzenle.
/// İş kuralı telefondakiyle aynı: `SaveMockExam`, `ImportKarne`, `planKarneImport`.
class DesktopExamsPage extends ConsumerWidget {
  const DesktopExamsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mockExamsProvider);
    final selectedId = ref.watch(desktopExamSelectionProvider);
    final theme = Theme.of(context);
    return DesktopPage(
      title: 'Denemeler',
      actions: [
        OutlinedButton.icon(
          key: const ValueKey('karne-ice-aktar'),
          onPressed: () => importKarnePdfs(context, ref),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('Karne PDF içe aktar'),
        ),
        FilledButton.icon(
          key: const ValueKey('deneme-ekle'),
          onPressed: () => showExamDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Deneme ekle'),
        ),
      ],
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Denemeler okunamadı: $e')),
        data: (exams) {
          if (exams.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Henüz deneme yok. Elle gir ya da karne PDF\'ini içe aktar.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            );
          }
          final exam = exams.where((e) => e.id == selectedId).firstOrNull;
          return LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 860;
            final list = ListView.builder(
              itemCount: exams.length,
              itemBuilder: (_, i) {
                final e = exams[i];
                return ListTile(
                  key: ValueKey('deneme-satir:${e.id}'),
                  selected: e.id == selectedId,
                  title: Text(e.title),
                  subtitle: Text('${e.kind.label} · ${formatDate(e.takenOn)} · ${e.correct}D ${e.wrong}Y ${e.blank}B'),
                  trailing: Text('${formatNet(e.net)} net', style: theme.textTheme.titleSmall),
                  onTap: () => ref.read(desktopExamSelectionProvider.notifier).select(e.id),
                );
              },
            );
            final detail = exam == null
                ? Center(child: Text('Soldan bir deneme seç.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)))
                : _ExamDetail(exam: exam, showBack: !wide);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [SizedBox(width: 380, child: list), const VerticalDivider(width: 1), Expanded(child: detail)],
              );
            }
            return exam == null ? list : detail;
          });
        },
      ),
    );
  }
}

class _ExamDetail extends ConsumerWidget {
  const _ExamDetail({required this.exam, required this.showBack});
  final MockExam exam;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref.read(desktopExamSelectionProvider.notifier).select(null),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Liste'),
            ),
          ),
        Row(
          children: [
            Expanded(child: Text(exam.title, style: theme.textTheme.titleLarge)),
            OutlinedButton.icon(
              key: const ValueKey('deneme-duzenle'),
              onPressed: () => showExamDialog(context, ref, existing: exam),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Düzenle'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('deneme-sil'),
              onPressed: () => _delete(context, ref),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Sil'),
            ),
          ],
        ),
        Text('${exam.kind.label} · ${formatDate(exam.takenOn)}${exam.durationMinutes == null ? '' : ' · ${exam.durationMinutes} dk'}'),
        const SizedBox(height: 8),
        Text('${exam.correct} doğru · ${exam.wrong} yanlış · ${exam.blank} boş · ${formatNet(exam.net)} net', style: theme.textTheme.titleMedium),
        if (exam.note != null) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(exam.note!)),
        const SizedBox(height: 12),
        DataTable(
          columns: const [
            DataColumn(label: Text('Ders')),
            DataColumn(label: Text('Soru'), numeric: true),
            DataColumn(label: Text('D'), numeric: true),
            DataColumn(label: Text('Y'), numeric: true),
            DataColumn(label: Text('B'), numeric: true),
            DataColumn(label: Text('Net'), numeric: true),
          ],
          rows: [
            for (final s in exam.sections)
              DataRow(cells: [
                DataCell(Text(s.name)),
                DataCell(Text('${s.questionCount}')),
                DataCell(Text('${s.correct}')),
                DataCell(Text('${s.wrong}')),
                DataCell(Text('${s.blank}')),
                DataCell(Text(formatNet(s.net))),
              ]),
          ],
        ),
      ],
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deneme silinsin mi?'),
        content: Text('“${exam.title}” silinir. Ona bağlı, fotoğraf ya da çözüm eklemediğin hızlı sorular da silinir; '
            'emek verdiğin sorular defterde kalır.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('deneme-sil-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) {
      ref.read(desktopExamSelectionProvider.notifier).select(null);
      await ref.read(mockExamRepositoryProvider).delete(exam.id);
    }
  }
}

// ───────────── Elle deneme girişi ─────────────

class _SectionFields {
  _SectionFields(this.subject, int count, {int correct = 0, int wrong = 0, int blank = 0})
      : count = TextEditingController(text: '$count'),
        correct = TextEditingController(text: '$correct'),
        wrong = TextEditingController(text: '$wrong'),
        blank = TextEditingController(text: '$blank');

  final String subject;
  final TextEditingController count, correct, wrong, blank;

  int _n(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
  MockSectionDraft toDraft() =>
      MockSectionDraft(subject: subject, questionCount: _n(count), correct: _n(correct), wrong: _n(wrong), blank: _n(blank));
}

/// Deneme ekle / düzenle. Sonuçlar ders ders D/Y/B olarak girilir; net kendiliğinden.
Future<void> showExamDialog(BuildContext context, WidgetRef ref, {MockExam? existing}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
        child: _ExamForm(existing: existing),
      ),
    ),
  );
}

class _ExamForm extends ConsumerStatefulWidget {
  const _ExamForm({this.existing});
  final MockExam? existing;

  @override
  ConsumerState<_ExamForm> createState() => _ExamFormState();
}

class _ExamFormState extends ConsumerState<_ExamForm> {
  late MockKind _kind;
  String _field = 'Sayısal';
  late DateTime _date;
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _minutes = TextEditingController(text: widget.existing?.durationMinutes?.toString() ?? '');
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late List<_SectionFields> _rows;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? MockKind.tyt;
    _date = e?.takenOn ?? DateTime.now();
    _rows = e != null
        ? [for (final s in e.sections) _SectionFields(s.subject, s.questionCount, correct: s.correct, wrong: s.wrong, blank: s.blank)]
        : _preset();
  }

  List<_SectionFields> _preset() => [for (final s in presetSections(_kind, aytField: _field)) _SectionFields(s.subject, s.questionCount)];

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref.read(saveMockExamProvider)(MockExamDraft(
        id: widget.existing?.id,
        title: _title.text,
        kind: _kind,
        takenOn: _date,
        durationMinutes: int.tryParse(_minutes.text.trim()),
        note: _note.text,
        sections: [for (final r in _rows) r.toDraft()],
      ));
      ref.read(desktopExamSelectionProvider.notifier).select(saved.id);
      if (mounted) Navigator.pop(context);
    } on MockExamException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _saving = false);
  }

  void _addBranch() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Ders ekle'),
        children: [
          SizedBox(
            width: 360,
            height: 360,
            child: ListView(children: [
              for (final s in Yks.all)
                if (!_rows.any((r) => r.subject == s.key))
                  ListTile(title: Text(s.key), subtitle: Text('${s.questions} soru'), onTap: () => Navigator.pop(ctx, s.key)),
            ]),
          ),
        ],
      ),
    );
    if (picked != null) setState(() => _rows.add(_SectionFields(picked, Yks.byKey(picked)?.questions ?? 20)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final net = _rows.fold<double>(0, (a, r) => a + netOf(r._n(r.correct), r._n(r.wrong)));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
          child: Row(children: [
            Expanded(child: Text(widget.existing == null ? 'Deneme ekle' : 'Denemeyi düzenle', style: theme.textTheme.titleLarge)),
            IconButton(onPressed: _saving ? null : () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(width: 280, child: TextField(key: const ValueKey('deneme-ad'), controller: _title, decoration: const InputDecoration(labelText: 'Deneme adı'))),
                  if (widget.existing == null)
                    SegmentedButton<MockKind>(
                      key: const ValueKey('deneme-tur'),
                      segments: [for (final k in MockKind.values) ButtonSegment(value: k, label: Text(k.label))],
                      selected: {_kind},
                      onSelectionChanged: (v) => setState(() {
                        _kind = v.first;
                        _rows = _preset();
                      }),
                    ),
                  if (widget.existing == null && _kind == MockKind.ayt)
                    DropdownButton<String>(
                      value: _field,
                      items: [for (final f in Yks.aytFields.keys) DropdownMenuItem(value: f, child: Text(f))],
                      onChanged: (v) => setState(() {
                        _field = v!;
                        _rows = _preset();
                      }),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
                      if (d != null) setState(() => _date = d);
                    },
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(formatDate(_date)),
                  ),
                  SizedBox(width: 120, child: TextField(controller: _minutes, decoration: const InputDecoration(labelText: 'Süre (dk)'))),
                ],
              ),
              const SizedBox(height: 16),
              Table(
                columnWidths: const {0: FlexColumnWidth(3), 1: FixedColumnWidth(80), 2: FixedColumnWidth(80), 3: FixedColumnWidth(80), 4: FixedColumnWidth(80), 5: FixedColumnWidth(70)},
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(children: [
                    for (final h in const ['Ders', 'Soru', 'Doğru', 'Yanlış', 'Boş', 'Net']) Padding(padding: const EdgeInsets.all(6), child: Text(h, style: theme.textTheme.labelLarge)),
                  ]),
                  for (final (i, r) in _rows.indexed)
                    TableRow(children: [
                      Padding(padding: const EdgeInsets.all(6), child: Row(children: [
                        Expanded(child: Text(r.subject)),
                        if (_kind == MockKind.branch || widget.existing != null)
                          IconButton(tooltip: 'Dersi çıkar', icon: const Icon(Icons.close, size: 16), onPressed: () => setState(() => _rows.removeAt(i))),
                      ])),
                      _num(r.count, 'soru:${r.subject}'),
                      _num(r.correct, 'dogru:${r.subject}'),
                      _num(r.wrong, 'yanlis:${r.subject}'),
                      _num(r.blank, 'bos:${r.subject}'),
                      Padding(padding: const EdgeInsets.all(6), child: Text(formatNet(netOf(r._n(r.correct), r._n(r.wrong))))),
                    ]),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: _addBranch, icon: const Icon(Icons.add), label: const Text('Ders ekle')),
              ),
              const SizedBox(height: 8),
              TextField(controller: _note, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Not')),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Text('Toplam net: ${formatNet(net)}', key: const ValueKey('deneme-net'), style: theme.textTheme.titleSmall),
            const SizedBox(width: 16),
            if (_error != null) Expanded(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))) else const Spacer(),
            TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Vazgeç')),
            const SizedBox(width: 8),
            FilledButton.icon(key: const ValueKey('deneme-kaydet'), onPressed: _saving ? null : _save, icon: const Icon(Icons.check), label: const Text('Kaydet')),
          ]),
        ),
      ],
    );
  }

  Widget _num(TextEditingController c, String key) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: TextField(key: ValueKey(key), controller: c, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true), onChanged: (_) => setState(() {})),
      );
}

// ───────────── Karne PDF içe aktarma ─────────────

/// PDF'leri seç → oku → önizleme (adı değiştir, kartları ekle/ekleme) → kaydet.
/// Birden çok dosya seçilirse sırayla önizlenir.
Future<void> importKarnePdfs(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final List<KarneFile> files;
  try {
    files = await pickKarneFiles();
  } on Exception catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Dosya açılamadı: $e')));
    return;
  }
  for (final f in files) {
    if (!context.mounted) return;
    final KarneImportPlan plan;
    try {
      plan = planKarneImport(parseKarne(await readKarneWords(f.bytes)));
    } on KarneFormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${f.name}: ${e.message}')));
      continue;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${f.name}: okunamadı ($e)')));
      continue;
    }
    if (!context.mounted) return;
    final go = await showKarnePreview(context, ref, plan);
    if (go == false) break; // "Vazgeç": kalan dosyalar da bırakılır
  }
}

/// Önizleme ve kayıt. true: kaydedildi ya da atlandı (sonraki dosya), false: durdur.
Future<bool> showKarnePreview(BuildContext context, WidgetRef ref, KarneImportPlan plan) async {
  final title = TextEditingController(text: plan.data.title);
  var addMistakes = true;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Karne önizleme'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(key: const ValueKey('karne-ad'), controller: title, decoration: const InputDecoration(labelText: 'Deneme adı')),
              const SizedBox(height: 12),
              Text('${plan.kind.label} · ${plan.data.date == null ? 'tarih yok' : formatDate(plan.data.date!)} · ${formatNet(plan.net)} net'),
              Text('${plan.sections.length} ders; ${plan.wrongCount} yanlış, ${plan.blankCount} boş soru'),
              if (plan.skipped.isNotEmpty) Text('Girilmeyen bölüm: ${plan.skipped.join(', ')}'),
              CheckboxListTile(
                key: const ValueKey('karne-kartlar'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Yanlış ve boşları deftere ekle'),
                value: addMistakes,
                onChanged: (v) => setState(() => addMistakes = v ?? true),
              ),
              Text(plan.note, style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('karne-kaydet'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
        ],
      ),
    ),
  );
  final name = title.text.trim();
  if (result != true) return false;
  if (!context.mounted) return false;
  return _saveKarne(context, ref, plan, name.isEmpty ? null : name, addMistakes);
}

Future<bool> _saveKarne(BuildContext context, WidgetRef ref, KarneImportPlan plan, String? title, bool addMistakes,
    {bool replace = false}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final r = await ref.read(importKarneProvider).call(plan, title: title, addMistakes: addMistakes, replace: replace);
    ref.read(desktopExamSelectionProvider.notifier).select(r.exam.id);
    messenger.showSnackBar(SnackBar(
      content: Text('${r.exam.title} eklendi: ${formatNet(r.exam.net)} net${r.cards > 0 ? ', ${r.cards} soru deftere düştü' : ''}.'),
    ));
    return true;
  } on KarneDuplicateException catch (e) {
    if (!context.mounted) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bu deneme zaten kayıtlı'),
        content: Text('${e.existing.title} (${formatDate(e.existing.takenOn)}) daha önce eklenmiş. Yenisiyle değiştirilsin mi? '
            'Eskisinin fotoğraf eklemediğin soruları da silinir.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Atla')),
          FilledButton(key: const ValueKey('karne-degistir'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Değiştir')),
        ],
      ),
    );
    if (ok == true && context.mounted) return _saveKarne(context, ref, plan, title, addMistakes, replace: true);
    return true;
  } on MockExamException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return true;
  }
}
