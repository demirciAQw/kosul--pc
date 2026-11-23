import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../curriculum/curriculum_providers.dart';
import '../../curriculum/domain/curriculum.dart';
import '../../curriculum/domain/yks.dart';
import '../../library/domain/library.dart';
import '../../library/library_providers.dart';
import '../../question_bank/domain/question_card.dart';
import '../data/pdf_question_service.dart';
import '../domain/pdf_engine.dart';
import '../pdf_providers.dart';

/// "Soru seç" ile kutu çizilince açılan küçük panel: Doğru / Yanlış / Boş,
/// ders ve konu (metinden öneri, düzeltilebilir), Kaydet / İptal.
class PdfQuestionPanel extends ConsumerStatefulWidget {
  const PdfQuestionPanel({
    super.key,
    required this.info,
    required this.page,
    required this.box,
    required this.onSaved,
    required this.onCancel,
  });

  final PdfOpenInfo info;

  /// 0'dan.
  final int page;
  final PdfBox box;
  final ValueChanged<QuestionCard> onSaved;
  final VoidCallback onCancel;

  @override
  ConsumerState<PdfQuestionPanel> createState() => _PdfQuestionPanelState();
}

class _PdfQuestionPanelState extends ConsumerState<PdfQuestionPanel> {
  QuestionStatus? _status;
  String? _subject;
  final _topic = TextEditingController();
  bool _subjectTouched = false;
  bool _topicTouched = false;
  bool _analyzing = true;
  bool _saving = false;
  String? _error;
  BoxAnalysis? _analysis;
  Book? _book;
  bool _hasLayers = false;
  bool _applyLayers = false; // varsayılan KAPALI: önizleme özgün sayfadan

  @override
  void initState() {
    super.initState();
    final bookId = widget.info.record.bookId;
    _book = bookId == null ? null : ref.read(bookByIdProvider(bookId));
    final b = _book;
    if (b != null) _subject = subjectKey(b.examType, b.subject);
    _analyze();
    _checkLayers();
  }

  Future<void> _checkLayers() async {
    try {
      final svc = await ref.read(pdfQuestionServiceProvider.future);
      final has = await svc.hasVisibleLayers(widget.info.record.id, widget.page);
      if (mounted && has) setState(() => _hasLayers = true);
    } catch (_) {
      // anahtar gösterilmez
    }
  }

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    try {
      final svc = await ref.read(pdfQuestionServiceProvider.future);
      final curriculum = ref.read(curriculumProvider).value ?? const <CurriculumNode>[];
      final a = await svc.analyze(
        widget.info.path!,
        widget.page,
        widget.box,
        subject: _book == null ? null : subjectKey(_book!.examType, _book!.subject),
        examType: _book?.examType ?? 'TYT',
        curriculum: curriculum,
      );
      if (!mounted) return;
      setState(() {
        _analysis = a;
        _analyzing = false;
        final s = a.suggestion;
        if (!_subjectTouched && s.subject != null) _subject = s.subject;
        if (!_topicTouched && s.topic != null) _topic.text = s.topic!;
      });
    } catch (_) {
      // Analiz önerisiz de kaydedilebilir: kullanıcı elle seçer.
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _save() async {
    final status = _status, subject = _subject;
    if (status == null || subject == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final svc = await ref.read(pdfQuestionServiceProvider.future);
      final topic = _topic.text.trim();
      final suggested = _analysis?.suggestion;
      // Önerilen MEB konusu yalnızca konu metni önerilenle aynıysa geçerlidir.
      final keepMeb = suggested != null && suggested.topic != null && suggested.topic == topic;
      final card = await svc.save(
        document: widget.info.record,
        pdfPath: widget.info.path!,
        page: widget.page,
        box: widget.box,
        status: status,
        subject: subject,
        analysis: _analysis,
        book: _book,
        topicText: topic,
        mebNodeId: keepMeb ? suggested.mebNodeId : null,
        applyLayersToPreview: _hasLayers && _applyLayers,
      );
      if (mounted) widget.onSaved(card);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Kaydedilemedi: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(libraryProvider).value ?? const <Book>[];
    final subjects = allSubjectKeys(extra: [
      for (final b in books) subjectKey(b.examType, b.subject),
      if (_subject != null) _subject!,
    ]);
    final types = _analysis?.suggestion.types ?? const <String>[];
    final theme = Theme.of(context);
    return Material(
      key: const Key('pdf-question-panel'),
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Sayfa ${widget.page + 1}: soru', style: theme.textTheme.titleSmall)),
                if (_analyzing) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                IconButton(
                  key: const Key('pdf-q-cancel'),
                  tooltip: 'İptal',
                  icon: const Icon(Icons.close),
                  onPressed: _saving ? null : widget.onCancel,
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final s in [QuestionStatus.correct, QuestionStatus.wrong, QuestionStatus.blank])
                  ChoiceChip(
                    key: Key('pdf-q-status-${s.name}'),
                    label: Text(s.label),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownMenu<String>(
                  key: ValueKey('pdf-q-subject-$_subject'),
                  width: 200,
                  label: const Text('Ders'),
                  initialSelection: _subject,
                  dropdownMenuEntries: [for (final s in subjects) DropdownMenuEntry(value: s, label: s)],
                  onSelected: (s) => setState(() {
                    _subject = s;
                    _subjectTouched = true;
                  }),
                ),
                SizedBox(
                  width: 200,
                  child: TextField(
                    key: const Key('pdf-q-topic'),
                    controller: _topic,
                    decoration: const InputDecoration(labelText: 'Konu', isDense: true),
                    onChanged: (_) => _topicTouched = true,
                  ),
                ),
                for (final t in types) Chip(label: Text(t), visualDensity: VisualDensity.compact),
              ],
            ),
            if (_hasLayers)
              SwitchListTile(
                key: const Key('pdf-q-apply-layers'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Katmanları önizlemeye uygula'),
                subtitle: const Text('Kapalıyken karta özgün sayfa kaydedilir.'),
                value: _applyLayers,
                onChanged: _saving ? null : (v) => setState(() => _applyLayers = v),
              ),
            if (_analysis != null && _analysis!.text.isEmpty && !_analyzing)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Kutuda okunabilir metin yok; ders ve konuyu sen seç.', style: theme.textTheme.bodySmall),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const Key('pdf-q-save'),
                onPressed: _status != null && _subject != null && !_saving && !_analyzing ? _save : null,
                child: Text(_saving ? 'Kaydediliyor…' : 'Kaydet'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
