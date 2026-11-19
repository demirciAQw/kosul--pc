import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import '../../core/utils/formatters.dart';
import '../../features/curriculum/curriculum_providers.dart';
import '../../features/curriculum/domain/curriculum.dart';
import '../../features/curriculum/domain/yks.dart';
import '../../features/library/domain/library.dart';
import '../../features/library/library_providers.dart';
import '../../features/study_session/domain/study_session.dart';
import '../../features/study_session/presentation/session_coverage.dart';
import '../../features/study_session/presentation/widgets/topic_selection_view.dart';
import '../../features/study_session/study_session_providers.dart';
import '../widgets/desktop_page.dart';

/// Çalışma oturumu (bilgisayar): sayaç pencere içindedir. Telefonun bildirim
/// kronometresine ve servisine hiç dokunulmaz (`sessionChronometerProvider`
/// bu sayfada okunmaz). Süre her zaman başlangıç damgasından hesaplanır.
class DesktopSessionsPage extends ConsumerStatefulWidget {
  const DesktopSessionsPage({super.key});

  @override
  ConsumerState<DesktopSessionsPage> createState() => _DesktopSessionsPageState();
}

class _DesktopSessionsPageState extends ConsumerState<DesktopSessionsPage> {
  Timer? _tick;
  bool _bookMode = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(runningSessionProvider).value != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _start(List<SessionItemDraft> drafts) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(startStudySessionProvider).call(drafts);
    } on StudySessionException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _finish(StudySession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Oturum bitsin mi?'),
        content: Text('Geçen süre: ${formatDuration(s.elapsedAt(ref.read(clockProvider)()))}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Çalışmaya devam et')),
          FilledButton(key: const ValueKey('oturum-bitir-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Bitir')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(finishStudySessionProvider).call(s.id);
    // Çalışılan testler hemen kitap haritasına düşer (telefondaki akışla aynı).
    await _markCoverage(ref, s);
    if (s.hasQuestionWork) {
      if (mounted) await showSessionResultsDialog(context, ref, s);
    } else {
      // Konu anlatımı, video, tekrar: girilecek sonuç yok, oturum tamamlanır.
      await ref.read(submitSessionResultsProvider).call(s.id, const []);
    }
  }

  Future<void> _cancel(StudySession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Oturum iptal edilsin mi?'),
        content: const Text('Süre kaydedilmez. Bu işlem geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('oturum-iptal-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('İptal et')),
        ],
      ),
    );
    if (ok == true) await ref.read(cancelStudySessionProvider).call(s.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = ref.watch(runningSessionProvider).value;
    final pending = ref.watch(pendingSessionsProvider).value ?? const <StudySession>[];
    final history = ref.watch(sessionHistoryProvider).value ?? const <StudySession>[];
    final now = ref.watch(clockProvider)();
    return DesktopPage(
      title: 'Oturumlar',
      subtitle: running == null ? 'Çalışmaya başla; süre pencerede sayılır' : 'Oturum sürüyor',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (running != null)
            Card(
              key: const ValueKey('suren-oturum'),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatDuration(running.elapsedAt(now)), key: const ValueKey('sayac'), style: theme.textTheme.displayMedium),
                    const SizedBox(height: 8),
                    for (final i in running.items) Text('• ${i.label}${i.pages.isEmpty ? '' : ' (s. ${i.pageSpec})'}'),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        FilledButton.icon(key: const ValueKey('oturum-bitir'), onPressed: () => _finish(running), icon: const Icon(Icons.stop_rounded), label: const Text('Bitir')),
                        const SizedBox(width: 12),
                        OutlinedButton(key: const ValueKey('oturum-iptal'), onPressed: () => _cancel(running), child: const Text('İptal')),
                      ],
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Row(
              children: [
                Text('Yeni oturum', style: theme.textTheme.titleMedium),
                const Spacer(),
                SegmentedButton<bool>(
                  key: const ValueKey('oturum-kip'),
                  segments: const [
                    ButtonSegment(value: true, label: Text('Kitaptan'), icon: Icon(Icons.menu_book_outlined)),
                    ButtonSegment(value: false, label: Text('Kitapsız'), icon: Icon(Icons.edit_note_rounded)),
                  ],
                  selected: {_bookMode},
                  onSelectionChanged: (v) => setState(() => _bookMode = v.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 460,
              child: Card(
                child: _bookMode
                    ? TopicSelectionView(actionLabel: 'BAŞLA', actionIcon: Icons.play_arrow_rounded, busy: _busy, onSubmit: _start)
                    : _FreeForm(busy: _busy, onStart: _start),
              ),
            ),
          ],
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Sonuç bekleyenler', style: theme.textTheme.titleMedium),
            for (final s in pending)
              Card(
                key: ValueKey('bekleyen:${s.id}'),
                child: ListTile(
                  title: Text(_title(s)),
                  subtitle: Text('${formatShortDate(s.startedAt)} · ${formatDuration(s.elapsedAt(now))}'),
                  trailing: FilledButton.tonal(
                    key: ValueKey('sonuc-gir:${s.id}'),
                    onPressed: () => showSessionResultsDialog(context, ref, s),
                    child: const Text('Sonuçları gir'),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Text('Geçmiş', style: theme.textTheme.titleMedium),
          if (history.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Henüz oturum yok.')),
          for (final s in history.where((s) => s.status != SessionStatus.running).take(40))
            ListTile(
              key: ValueKey('gecmis:${s.id}'),
              dense: true,
              title: Text(_title(s)),
              subtitle: Text('${formatShortDate(s.startedAt)} · ${formatDuration(s.elapsedAt(now))}'
                  '${s.totalSolved > 0 ? ' · ${s.totalSolved} soru' : ''}'),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(key: ValueKey('sure:${s.id}'), tooltip: 'Süreyi düzelt', icon: const Icon(Icons.timer_outlined, size: 18), onPressed: () => _editTime(s)),
                  IconButton(key: ValueKey('sil:${s.id}'), tooltip: 'Sil', icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => _delete(s)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _title(StudySession s) => s.items.isEmpty ? 'Oturum' : s.items.map((i) => i.testLabel).take(2).join(', ');

  Future<void> _editTime(StudySession s) async {
    final c = TextEditingController(text: '${s.elapsedAt(ref.read(clockProvider)()).inMinutes}');
    final minutes = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Süreyi düzelt'),
        content: TextField(key: const ValueKey('sure-dk'), controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Süre (dakika)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('sure-kaydet'), onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())), child: const Text('Kaydet')),
        ],
      ),
    );
    if (minutes == null || !mounted) return;
    try {
      await ref.read(studySessionRepositoryProvider).updateTimes(s.id, startedAt: s.startedAt, endedAt: s.startedAt.add(Duration(minutes: minutes)));
    } on StudySessionException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(StudySession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Oturum silinsin mi?'),
        content: const Text('Süre ve sonuçlar silinir. Defterdeki sorular durur. Bu işlem geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('oturum-sil-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) await ref.read(studySessionRepositoryProvider).deleteFinished(s.id);
  }
}

/// Soru çözülen maddeler için doğru / yanlış / boş sayıları.
Future<void> showSessionResultsDialog(BuildContext context, WidgetRef ref, StudySession s) async {
  final items = [for (final i in s.items) if (i.hasQuestions) i];
  final fields = {
    for (final i in items) i.id: [for (final v in [i.correct, i.wrong, i.blank]) TextEditingController(text: v == null ? '' : '$v')],
  };
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Sonuçlar'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final i in items) ...[
                  Text(i.testLabel, style: Theme.of(ctx).textTheme.titleSmall),
                  Row(
                    children: [
                      for (final (n, label) in const ['Doğru', 'Yanlış', 'Boş'].indexed)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: TextField(
                              key: ValueKey('${['d', 'y', 'b'][n]}:${i.id}'),
                              controller: fields[i.id]![n],
                              decoration: InputDecoration(labelText: label),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (error != null) Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Sonra')),
          FilledButton(
            key: const ValueKey('sonuc-kaydet'),
            onPressed: () {
              final bad = fields.values.any((f) => f.any((c) => c.text.trim().isNotEmpty && (int.tryParse(c.text.trim()) ?? -1) < 0));
              if (bad) {
                setState(() => error = 'Sayılar negatif olamaz.');
              } else {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;
  int n(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
  await ref.read(submitSessionResultsProvider).call(s.id, [
    for (final i in items) ItemResult(itemId: i.id, correct: n(fields[i.id]![0]), wrong: n(fields[i.id]![1]), blank: n(fields[i.id]![2])),
  ]);
  await _markCoverage(ref, s);
}

/// Bu oturumda çalışılan testleri kitap haritasında "çözüldü" yapar; daha önce
/// sonucu olanlara dokunmaz.
Future<void> _markCoverage(WidgetRef ref, StudySession s) => ref.read(testProgressRepositoryProvider).saveIfAbsent(
      sessionCoverage(
        session: s,
        books: ref.read(libraryProvider).value ?? const <Book>[],
        now: ref.read(clockProvider)(),
      ),
    );

/// Kitapsız oturum: ders (zorunlu), konu ve ne yapılacağı.
class _FreeForm extends ConsumerStatefulWidget {
  const _FreeForm({required this.busy, required this.onStart});
  final bool busy;
  final ValueChanged<List<SessionItemDraft>> onStart;

  @override
  ConsumerState<_FreeForm> createState() => _FreeFormState();
}

class _FreeFormState extends ConsumerState<_FreeForm> {
  final _note = TextEditingController();
  String? _subject;
  String? _topicId;
  StudyActivity _activity = StudyActivity.lecture;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curriculum = ref.watch(curriculumProvider).value ?? const <CurriculumNode>[];
    final books = ref.watch(libraryProvider).value ?? const <Book>[];
    final subjects = allSubjectKeys(extra: [for (final n in curriculum) n.subjectLabel, for (final b in books) subjectKey(b.examType, b.subject)]);
    final topics = _subject == null ? const <CurriculumNode>[] : depthFirst(curriculum.where((n) => n.subjectLabel == _subject));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Video, konu anlatımı, PDF test ya da okul ödevi: kitap seçmeden başlat. Süre yine derse göre analize sayılır.'),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('serbest-ders'),
          initialValue: _subject,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Ders *'),
          items: [for (final s in subjects) DropdownMenuItem(value: s, child: Text(s))],
          onChanged: (v) => setState(() {
            _subject = v;
            _topicId = null;
          }),
        ),
        DropdownButtonFormField<String?>(
          key: ValueKey('serbest-konu:$_subject'),
          initialValue: _topicId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Konu'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Seçilmedi')),
            for (final t in topics) DropdownMenuItem(value: t.id, child: Text('${'  ' * t.depth}${t.title}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _topicId = v),
        ),
        DropdownButtonFormField<StudyActivity>(
          initialValue: _activity,
          decoration: const InputDecoration(labelText: 'Ne yapacaksın?'),
          items: [for (final a in StudyActivity.values) DropdownMenuItem(value: a, child: Text(a.label))],
          onChanged: (v) => setState(() => _activity = v!),
        ),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Not (isteğe bağlı)')),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('serbest-basla'),
            onPressed: widget.busy || _subject == null
                ? null
                : () {
                    final topic = topics.where((t) => t.id == _topicId).firstOrNull;
                    final what = topic?.title ?? _subject!;
                    final note = _note.text.trim();
                    widget.onStart([
                      SessionItemDraft(
                        label: note.isEmpty ? '${_activity.label}: $what' : '$note ($what)',
                        pages: const [],
                        subject: _subject,
                        mebNodeId: topic?.id,
                        activity: _activity,
                      ),
                    ]);
                  },
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('BAŞLA'),
          ),
        ),
      ],
    );
  }
}
