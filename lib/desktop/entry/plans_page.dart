import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import '../../core/utils/formatters.dart';
import '../../features/library/domain/library.dart';
import '../../features/library/library_providers.dart';
import '../../features/planning/domain/plan_import.dart';
import '../../features/planning/domain/planning.dart';
import '../../features/planning/planning_providers.dart';
import '../widgets/desktop_page.dart';

class DesktopPlanSelection extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final desktopPlanSelectionProvider = NotifierProvider<DesktopPlanSelection, String?>(DesktopPlanSelection.new);

/// Planlar: oluştur, görev ekle ve işaretle, yapay zekâ programını içe aktar.
/// İş kuralı telefondakiyle aynı: `CreatePlan`, `AddPlanTasks`, `EditPlan`,
/// `parsePlanJson`.
class DesktopPlansPage extends ConsumerWidget {
  const DesktopPlansPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(plansProvider);
    final selectedId = ref.watch(desktopPlanSelectionProvider);
    final now = ref.watch(clockProvider)();
    final theme = Theme.of(context);
    return DesktopPage(
      title: 'Planlar',
      actions: [
        OutlinedButton.icon(
          key: const ValueKey('program-ice-aktar'),
          onPressed: () => showPlanImportDialog(context, ref),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Programı içe aktar'),
        ),
        FilledButton.icon(
          key: const ValueKey('plan-olustur'),
          onPressed: () => showNewPlanDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Plan oluştur'),
        ),
      ],
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Planlar okunamadı: $e')),
        data: (plans) {
          if (plans.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Henüz plan yok. Haftalık, aylık ya da yıllık plan oluştur; ya da yapay zekânın programını içe aktar.',
                    textAlign: TextAlign.center, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            );
          }
          final plan = plans.where((p) => p.id == selectedId).firstOrNull;
          return LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 860;
            final list = ListView.builder(
              itemCount: plans.length,
              itemBuilder: (_, i) {
                final p = plans[i];
                return ListTile(
                  key: ValueKey('plan-satir:${p.id}'),
                  selected: p.id == selectedId,
                  title: Text(p.title),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p.statusText(now)} · ${p.doneCount}/${p.tasks.length} görev'),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: p.progress, minHeight: 4),
                  ]),
                  isThreeLine: true,
                  onTap: () => ref.read(desktopPlanSelectionProvider.notifier).select(p.id),
                );
              },
            );
            final detail = plan == null
                ? Center(child: Text('Soldan bir plan seç.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)))
                : _PlanDetail(plan: plan, showBack: !wide);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [SizedBox(width: 360, child: list), const VerticalDivider(width: 1), Expanded(child: detail)],
              );
            }
            return plan == null ? list : detail;
          });
        },
      ),
    );
  }
}

class _PlanDetail extends ConsumerStatefulWidget {
  const _PlanDetail({required this.plan, required this.showBack});
  final StudyPlan plan;
  final bool showBack;

  @override
  ConsumerState<_PlanDetail> createState() => _PlanDetailState();
}

class _PlanDetailState extends ConsumerState<_PlanDetail> {
  final _newTask = TextEditingController();

  @override
  void dispose() {
    _newTask.dispose();
    super.dispose();
  }

  void _say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _addTask() async {
    final t = _newTask.text.trim();
    if (t.isEmpty) return;
    _newTask.clear();
    await ref.read(addPlanTasksProvider).call(widget.plan.id, [NewPlanTaskDraft(title: t)]);
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final theme = Theme.of(context);
    final repo = ref.read(planRepositoryProvider);
    final now = ref.watch(clockProvider)();
    final hint = plan.paceHint(now);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref.read(desktopPlanSelectionProvider.notifier).select(null),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Liste'),
            ),
          ),
        Row(
          children: [
            Expanded(child: Text(plan.title, style: theme.textTheme.titleLarge)),
            OutlinedButton.icon(key: const ValueKey('plan-duzenle'), onPressed: _editPlan, icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Düzenle')),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const ValueKey('plan-tamamla'),
              onPressed: () => repo.setCompleted(plan.id, plan.isCompleted ? null : ref.read(clockProvider)()),
              child: Text(plan.isCompleted ? 'Yeniden aç' : 'Tamamladım'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(key: const ValueKey('plan-sil'), onPressed: _deletePlan, icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Sil')),
          ],
        ),
        Text('${formatDate(plan.startsOn)} – ${formatDate(plan.endsOn)} · ${plan.statusText(now)}'),
        if (hint != null) Text('Önerilen tempo: günde ${hint.toStringAsFixed(1)} görev', style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('gorev-yeni'),
                controller: _newTask,
                decoration: const InputDecoration(labelText: 'Yeni görev', hintText: 'Yaz ve Enter\'a bas'),
                onSubmitted: (_) => _addTask(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(key: const ValueKey('gorev-ekle'), onPressed: _addTask, child: const Text('Ekle')),
          ],
        ),
        const SizedBox(height: 8),
        if (plan.tasks.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Henüz görev yok.')),
        for (final t in plan.tasks)
          CheckboxListTile(
            key: ValueKey('gorev:${t.id}'),
            controlAffinity: ListTileControlAffinity.leading,
            value: t.isDone,
            onChanged: (v) => repo.setTaskDone(t.id, v ?? false),
            title: Text(t.title, style: t.isDone ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
            subtitle: t.targetQuestions == null ? null : Text('${t.targetQuestions} soru'),
            secondary: Wrap(children: [
              IconButton(key: ValueKey('gorev-ad:${t.id}'), tooltip: 'Yeniden adlandır', icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _renameTask(t)),
              IconButton(key: ValueKey('gorev-sil:${t.id}'), tooltip: 'Sil', icon: const Icon(Icons.close, size: 18), onPressed: () => _deleteTask(t)),
            ]),
          ),
      ],
    );
  }

  Future<void> _renameTask(PlanTask t) async {
    final c = TextEditingController(text: t.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Görevi yeniden adlandır'),
        content: TextField(key: const ValueKey('gorev-yeni-ad'), controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Kaydet')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) await ref.read(planRepositoryProvider).renameTask(t.id, name.trim());
  }

  Future<void> _deleteTask(PlanTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Görev silinsin mi?'),
        content: Text('“${t.title}” silinir.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('gorev-sil-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) await ref.read(planRepositoryProvider).deleteTask(t.id);
  }

  Future<void> _deletePlan() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Plan silinsin mi?'),
        content: Text('“${widget.plan.title}” ve ${widget.plan.tasks.length} görevi silinir. Bu işlem geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('plan-sil-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) {
      ref.read(desktopPlanSelectionProvider.notifier).select(null);
      await ref.read(planRepositoryProvider).delete(widget.plan.id);
    }
  }

  Future<void> _editPlan() async {
    final plan = widget.plan;
    final title = TextEditingController(text: plan.title);
    var start = plan.startsOn, end = plan.endsOn;
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Planı düzenle'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(key: const ValueKey('plan-ad'), controller: title, autofocus: true, decoration: InputDecoration(labelText: 'Ad', errorText: error)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(context: ctx, initialDate: start, firstDate: DateTime(2020), lastDate: DateTime(2100));
                      if (d != null) setState(() => start = d);
                    },
                    child: Text('Başlangıç: ${formatDate(start)}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(context: ctx, initialDate: end, firstDate: DateTime(2020), lastDate: DateTime(2100));
                      if (d != null) setState(() => end = d);
                    },
                    child: Text('Bitiş: ${formatDate(end)}'),
                  ),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
            FilledButton(key: const ValueKey('plan-kaydet'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(editPlanProvider).call(plan.id, title: title.text, startsOn: start, endsOn: end);
    } on PlanException catch (e) {
      if (mounted) _say(e.message);
    }
  }
}

/// Plan oluştur: tür (hazır tarih aralığı), ad, tarihler, ilk görevler (satır satır).
Future<void> showNewPlanDialog(BuildContext context, WidgetRef ref) async {
  final now = ref.read(clockProvider)();
  var kind = PlanKind.weekly;
  var range = kind.rangeFrom(now);
  final title = TextEditingController(text: '${kind.label} plan');
  final tasks = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Plan oluştur'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              SegmentedButton<PlanKind>(
                key: const ValueKey('plan-tur'),
                segments: [for (final k in PlanKind.values) ButtonSegment(value: k, label: Text(k.label))],
                selected: {kind},
                onSelectionChanged: (v) => setState(() {
                  kind = v.first;
                  range = kind.rangeFrom(now);
                  title.text = '${kind.label} plan';
                }),
              ),
              const SizedBox(height: 8),
              TextField(key: const ValueKey('plan-yeni-ad'), controller: title, decoration: InputDecoration(labelText: 'Ad', errorText: error)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(context: ctx, initialDate: range.start, firstDate: DateTime(2020), lastDate: DateTime(2100));
                      if (d != null) setState(() => range = (start: d, end: range.end));
                    },
                    child: Text('Başlangıç: ${formatDate(range.start)}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(context: ctx, initialDate: range.end, firstDate: DateTime(2020), lastDate: DateTime(2100));
                      if (d != null) setState(() => range = (start: range.start, end: d));
                    },
                    child: Text('Bitiş: ${formatDate(range.end)}'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              TextField(key: const ValueKey('plan-gorevler'), controller: tasks, minLines: 3, maxLines: 8, decoration: const InputDecoration(labelText: 'Görevler (her satır bir görev, isteğe bağlı)')),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('plan-olustur-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Oluştur')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  try {
    final plan = await ref.read(createPlanProvider).call(NewPlanDraft(
          title: title.text,
          startsOn: range.start,
          endsOn: range.end,
          tasks: [for (final l in tasks.text.split('\n')) if (l.trim().isNotEmpty) NewPlanTaskDraft(title: l.trim())],
        ));
    ref.read(desktopPlanSelectionProvider.notifier).select(plan.id);
  } on PlanException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Yapay zekâ programını içe aktar: JSON yapıştır → önizleme → plan olarak kaydet.
Future<void> showPlanImportDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(context: context, builder: (_) => Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700), child: const _ImportForm())));
}

class _ImportForm extends ConsumerStatefulWidget {
  const _ImportForm();

  @override
  ConsumerState<_ImportForm> createState() => _ImportFormState();
}

class _ImportFormState extends ConsumerState<_ImportForm> {
  final _text = TextEditingController();
  PlanImport? _preview;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _check() => setState(() {
        _error = null;
        _preview = null;
        try {
          _preview = parsePlanJson(_text.text, books: ref.read(libraryProvider).value ?? const <Book>[], today: ref.read(clockProvider)());
        } on PlanImportException catch (e) {
          _error = e.message;
        }
      });

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text?.isNotEmpty == true) {
      _text.text = data!.text!;
      _check();
    }
  }

  Future<void> _save() async {
    final p = _preview;
    if (p == null || _saving) return;
    setState(() => _saving = true);
    try {
      final plan = await ref.read(createPlanProvider).call(p.draft);
      ref.read(desktopPlanSelectionProvider.notifier).select(plan.id);
      if (mounted) Navigator.pop(context);
    } on Exception catch (e) {
      if (mounted) setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _preview;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Programı içe aktar', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Yapay zekânın verdiği JSON programını yapıştır. Önce önizleme gösterilir; kaydedince yeni bir plan olur.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              key: const ValueKey('program-metin'),
              controller: _text,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onChanged: (_) => setState(() => _preview = null),
              decoration: InputDecoration(hintText: '{ "format": "kocum.plan", … }', errorText: _error, errorMaxLines: 3, border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(height: 8),
          if (p != null)
            Text('${p.draft.title}: ${p.draft.tasks.length} görev, ${formatDate(p.draft.startsOn)} – ${formatDate(p.draft.endsOn)}'
                '${p.warnings.isEmpty ? '' : '\n${p.warnings.join('\n')}'}', key: const ValueKey('program-onizleme')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste, size: 18), label: const Text('Panodan yapıştır')),
              TextButton.icon(
                onPressed: () => Clipboard.setData(const ClipboardData(text: planJsonSchema)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Biçimi kopyala'),
              ),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
              if (p == null)
                FilledButton(key: const ValueKey('program-denetle'), onPressed: _check, child: const Text('Önizle'))
              else
                FilledButton(key: const ValueKey('program-kaydet'), onPressed: _saving ? null : _save, child: const Text('Plan olarak kaydet')),
            ],
          ),
        ],
      ),
    );
  }
}
