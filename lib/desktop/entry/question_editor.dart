import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/di/core_providers.dart';
import '../../core/media/crop_screen.dart';
import '../../features/curriculum/curriculum_providers.dart';
import '../../features/curriculum/domain/curriculum.dart';
import '../../features/curriculum/domain/yks.dart';
import '../../features/question_bank/domain/question_card.dart';
import '../../features/question_bank/presentation/widgets/media_image.dart';
import '../../features/question_bank/question_bank_providers.dart';
import '../widgets/file_drop_zone.dart';
import 'image_tools.dart';

/// Soru ekle / düzenle (bilgisayar). İş kuralı telefondakiyle aynıdır:
/// `SaveQuestionCard` ve `UpdateQuestionCard` kullanılır. Metin okuma
/// (ML Kit) bilgisayarda yapılmaz; fotoğraf telefona gidince orada okunur.
Future<QuestionCard?> showDesktopQuestionEditor(BuildContext context, {QuestionCard? card}) =>
    showDialog<QuestionCard>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 760),
          child: DesktopQuestionEditor(card: card),
        ),
      ),
    );

class DesktopQuestionEditor extends ConsumerStatefulWidget {
  const DesktopQuestionEditor({super.key, this.card});
  final QuestionCard? card;

  @override
  ConsumerState<DesktopQuestionEditor> createState() => _DesktopQuestionEditorState();
}

class _DesktopQuestionEditorState extends ConsumerState<DesktopQuestionEditor> {
  late QuestionStatus _status;
  String? _subject;
  String? _mebNodeId;
  MistakeReason? _reason;
  late int _difficulty;
  late bool _starred;
  late bool _written;
  String? _correct;
  String? _given;
  String? _questionImage; // geçici (yeni seçilen) yol
  String? _solutionImage;
  bool _clearQuestion = false;
  bool _clearSolution = false;
  String? _error;
  bool _saving = false;

  late final _source = TextEditingController(text: widget.card?.sourceName ?? '');
  late final _topic = TextEditingController(text: widget.card?.topicText ?? '');
  late final _reasonNote = TextEditingController(text: widget.card?.reasonNote ?? '');
  late final _solution = TextEditingController(text: widget.card?.solutionText ?? '');
  late final _note = TextEditingController(text: widget.card?.note ?? '');
  late final _questionNo = TextEditingController(text: widget.card?.questionNo?.toString() ?? '');
  late final _testLabel = TextEditingController(text: widget.card?.testLabel ?? '');
  late final _writtenCorrect = TextEditingController(text: widget.card?.hasWrittenAnswer == true ? widget.card?.correctAnswer ?? '' : '');
  late final _writtenGiven = TextEditingController(text: widget.card?.hasWrittenAnswer == true ? widget.card?.givenAnswer ?? '' : '');

  @override
  void initState() {
    super.initState();
    final c = widget.card;
    _status = c?.status ?? QuestionStatus.wrong;
    _subject = c?.subject;
    _mebNodeId = c?.mebNodeId;
    _reason = c?.reason;
    _difficulty = c?.difficulty ?? 5;
    _starred = c?.isStarred ?? false;
    _written = c?.hasWrittenAnswer ?? false;
    _correct = _written ? null : c?.correctAnswer;
    _given = _written ? null : c?.givenAnswer;
  }

  @override
  void dispose() {
    for (final c in [_source, _topic, _reasonNote, _solution, _note, _questionNo, _testLabel, _writtenCorrect, _writtenGiven]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<Directory> _tempDir() async => Directory(p.join((await getTemporaryDirectory()).path, 'kocum_giris'));

  Future<void> _pick({required bool solution}) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image, dialogTitle: 'Fotoğrafı seç');
    final path = r?.files.single.path;
    if (path != null) _setImage(path, solution: solution);
  }

  void _setImage(String path, {required bool solution}) => setState(() {
        if (solution) {
          _solutionImage = path;
          _clearSolution = false;
        } else {
          _questionImage = path;
          _clearQuestion = false;
        }
      });

  Future<void> _crop({required bool solution}) async {
    final path = solution ? _solutionImage : _questionImage;
    if (path == null) return;
    final out = await CropScreen.open(context, sourcePath: path, title: solution ? 'Çözümü kırp' : 'Soruyu kırp');
    if (out == null || !mounted) return;
    final dir = await _tempDir();
    final saved = await writeCropAsPng(out, dir, 'kirpilan_${DateTime.now().microsecondsSinceEpoch}');
    if (mounted) _setImage(saved, solution: solution);
  }

  QuestionDraft _draft() {
    final c = widget.card;
    final written = _written;
    String? clean(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
    return QuestionDraft(
      status: _status,
      origin: c?.origin ?? QuestionOrigin.independent,
      sourceName: clean(_source.text) ?? unknownSourceName,
      questionImagePath: _questionImage,
      solutionImagePath: _solutionImage,
      solutionText: clean(_solution.text),
      bookId: c?.bookId,
      contentNodeId: c?.contentNodeId,
      sessionId: c?.sessionId,
      mebNodeId: _mebNodeId,
      subject: _subject,
      testTotalQuestions: c?.testTotalQuestions,
      reason: _status == QuestionStatus.correct ? null : _reason,
      reasonNote: _reason == MistakeReason.other ? clean(_reasonNote.text) : null,
      topicText: clean(_topic.text),
      correctAnswer: written ? clean(_writtenCorrect.text) : _correct,
      givenAnswer: written ? clean(_writtenGiven.text) : _given,
      writtenAnswer: written,
      avgSecondsPerQuestion: c?.avgSecondsPerQuestion,
      difficulty: _difficulty,
      isStarred: _starred,
      note: clean(_note.text),
      questionNo: int.tryParse(_questionNo.text.trim()),
      testLabel: clean(_testLabel.text),
      sessionItemId: c?.sessionItemId,
      mockExamId: c?.mockExamId,
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final draft = _draft();
    final issues = draft.validate();
    if (issues.isNotEmpty) {
      setState(() => _error = issues.map((i) => i.message).join(' '));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final c = widget.card;
      final saved = c == null
          ? await ref.read(saveQuestionCardProvider)(draft)
          : await ref.read(updateQuestionCardProvider)(c, draft,
              clearQuestionImage: _clearQuestion, clearSolutionImage: _clearSolution);
      // Kırpılan geçici dosyalar (kullanıcının kendi dosyaları değil) silinir.
      final media = ref.read(mediaStorageProvider);
      await media.discardTemp(_questionImage);
      await media.discardTemp(_solutionImage);
      if (mounted) Navigator.pop(context, saved);
    } on QuestionDraftInvalid catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = 'Kaydedilemedi: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final curriculum = ref.watch(curriculumProvider).value ?? const <CurriculumNode>[];
    final subjects = {...Yks.all.map((s) => s.key), if (_subject != null) _subject!}.toList();
    final topics = depthFirst([for (final n in curriculum) if (n.subjectLabel == _subject) n]);
    final card = widget.card;

    return CallbackShortcutsLike(
      onSave: _save,
      onCancel: () => _saving ? null : Navigator.maybePop(context),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            child: Row(
              children: [
                Expanded(child: Text(card == null ? 'Soru ekle' : 'Soruyu düzenle', style: theme.textTheme.titleLarge)),
                IconButton(tooltip: 'Kapat (Esc)', onPressed: _saving ? null : () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 360,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        children: [
                          Icon(Icons.phone_android, size: 16, color: theme.colorScheme.outline),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('Fotoğraftaki yazının okunması telefonda yapılacak.',
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _PhotoBox(
                        key: const ValueKey('foto-soru'),
                        title: 'Soru fotoğrafı',
                        picked: _questionImage,
                        stored: _clearQuestion ? null : card?.questionImage,
                        onPick: () => _pick(solution: false),
                        onDrop: (path) => _setImage(path, solution: false),
                        onCrop: () => _crop(solution: false),
                        onClear: () => setState(() {
                          _questionImage = null;
                          _clearQuestion = true;
                        }),
                      ),
                      const SizedBox(height: 16),
                      _PhotoBox(
                        key: const ValueKey('foto-cozum'),
                        title: 'Çözüm fotoğrafı',
                        picked: _solutionImage,
                        stored: _clearSolution ? null : card?.solutionImage,
                        onPick: () => _pick(solution: true),
                        onDrop: (path) => _setImage(path, solution: true),
                        onCrop: () => _crop(solution: true),
                        onClear: () => setState(() {
                          _solutionImage = null;
                          _clearSolution = true;
                        }),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      SegmentedButton<QuestionStatus>(
                        key: const ValueKey('durum'),
                        segments: [for (final s in QuestionStatus.values) ButtonSegment(value: s, label: Text(s.label))],
                        selected: {_status},
                        onSelectionChanged: (v) => setState(() => _status = v.first),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              key: const ValueKey('ders'),
                              initialValue: _subject,
                              isExpanded: true,
                              decoration: const InputDecoration(labelText: 'Ders *'),
                              items: [for (final s in subjects) DropdownMenuItem(value: s, child: Text(s))],
                              onChanged: (v) => setState(() {
                                _subject = v;
                                _mebNodeId = null;
                              }),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String?>(
                              key: ValueKey('konu:$_subject'),
                              initialValue: topics.any((t) => t.id == _mebNodeId) ? _mebNodeId : null,
                              isExpanded: true,
                              decoration: const InputDecoration(labelText: 'MEB konusu'),
                              items: [
                                const DropdownMenuItem(value: null, child: Text('Seçilmedi')),
                                for (final t in topics)
                                  DropdownMenuItem(value: t.id, child: Text('${'  ' * t.depth}${t.title}', overflow: TextOverflow.ellipsis)),
                              ],
                              onChanged: (v) => setState(() => _mebNodeId = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(key: const ValueKey('konu-metin'), controller: _topic, decoration: const InputDecoration(labelText: 'Serbest konu (isteğe bağlı)')),
                      if (_status != QuestionStatus.correct) ...[
                        const SizedBox(height: 8),
                        DropdownButtonFormField<MistakeReason?>(
                          key: const ValueKey('neden'),
                          initialValue: _reason,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Neden'),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('Seçilmedi')),
                            for (final r in MistakeReason.values) DropdownMenuItem(value: r, child: Text(r.label)),
                          ],
                          onChanged: (v) => setState(() => _reason = v),
                        ),
                        if (_reason == MistakeReason.other)
                          TextField(controller: _reasonNote, decoration: const InputDecoration(labelText: 'Nedenin açıklaması')),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('Zorluk'),
                          Expanded(
                            child: Slider(
                              key: const ValueKey('zorluk'),
                              min: 1,
                              max: 10,
                              divisions: 9,
                              value: _difficulty.toDouble(),
                              label: '$_difficulty',
                              onChanged: (v) => setState(() => _difficulty = v.round()),
                            ),
                          ),
                          SizedBox(width: 24, child: Text('$_difficulty')),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Açık uçlu soru (yazılı cevap)'),
                        value: _written,
                        onChanged: (v) => setState(() => _written = v),
                      ),
                      if (_written) ...[
                        TextField(controller: _writtenCorrect, decoration: const InputDecoration(labelText: 'Doğru cevap')),
                        if (_status == QuestionStatus.wrong)
                          TextField(controller: _writtenGiven, decoration: const InputDecoration(labelText: 'Verdiğim cevap')),
                      ] else ...[
                        _Choices(label: 'Doğru şık', value: _correct, onChanged: (v) => setState(() => _correct = v)),
                        if (_status == QuestionStatus.wrong)
                          _Choices(label: 'İşaretlediğim şık', value: _given, onChanged: (v) => setState(() => _given = v)),
                      ],
                      const SizedBox(height: 8),
                      TextField(controller: _solution, minLines: 2, maxLines: 6, decoration: const InputDecoration(labelText: 'Çözüm metni')),
                      const SizedBox(height: 8),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Daha fazla'),
                        children: [
                          TextField(controller: _source, decoration: const InputDecoration(labelText: 'Kaynak (kitap, deneme…)')),
                          Row(
                            children: [
                              Expanded(child: TextField(controller: _testLabel, decoration: const InputDecoration(labelText: 'Test'))),
                              const SizedBox(width: 12),
                              SizedBox(width: 120, child: TextField(controller: _questionNo, decoration: const InputDecoration(labelText: 'Soru no'))),
                            ],
                          ),
                          TextField(controller: _note, minLines: 1, maxLines: 4, decoration: const InputDecoration(labelText: 'Not')),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Güzel soru'),
                            value: _starred,
                            onChanged: (v) => setState(() => _starred = v ?? false),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (_error != null)
                  Expanded(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)))
                else
                  const Spacer(),
                TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Vazgeç')),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey('soru-kaydet'),
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: const Text('Kaydet (Ctrl+S)'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ctrl+S kaydeder; Esc penceresi Dialog'un kendi davranışıdır.
class CallbackShortcutsLike extends StatelessWidget {
  const CallbackShortcutsLike({super.key, required this.onSave, required this.onCancel, required this.child});
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyS, control: true): _SaveIntent(),
          SingleActivator(LogicalKeyboardKey.escape): _CancelIntent(),
        },
        child: Actions(
          actions: {
            _SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) {
              onSave();
              return null;
            }),
            _CancelIntent: CallbackAction<_CancelIntent>(onInvoke: (_) {
              onCancel();
              return null;
            }),
          },
          child: Focus(autofocus: true, child: child),
        ),
      );
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}

class _Choices extends StatelessWidget {
  const _Choices({required this.label, required this.value, required this.onChanged});
  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 130, child: Text(label)),
            for (final c in const ['A', 'B', 'C', 'D', 'E'])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  key: ValueKey('$label:$c'),
                  label: Text(c),
                  selected: value == c,
                  onSelected: (s) => onChanged(s ? c : null),
                ),
              ),
          ],
        ),
      );
}

class _PhotoBox extends StatelessWidget {
  const _PhotoBox({
    super.key,
    required this.title,
    required this.picked,
    required this.stored,
    required this.onPick,
    required this.onDrop,
    required this.onCrop,
    required this.onClear,
  });

  final String title;
  final String? picked; // yeni seçilen (mutlak yol)
  final String? stored; // kayıtlı (göreli yol)
  final VoidCallback onPick;
  final void Function(String path) onDrop;
  final VoidCallback onCrop;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final has = picked != null || stored != null;
    return FileDropZone(
      extensions: imageExtensions,
      onFiles: (paths) => onDrop(paths.first),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            AspectRatio(
              aspectRatio: 4 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: picked != null
                      ? Image.file(File(picked!), fit: BoxFit.contain, cacheWidth: 900)
                      : stored != null
                          ? MediaImage(stored!, fit: BoxFit.contain, cacheWidth: 900)
                          : Center(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text('Fotoğrafı buraya sürükle\nya da Dosya seç', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                              ),
                            ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(onPressed: onPick, icon: const Icon(Icons.folder_open, size: 18), label: const Text('Dosya seç')),
                if (picked != null) OutlinedButton.icon(onPressed: onCrop, icon: const Icon(Icons.crop, size: 18), label: const Text('Kırp')),
                if (has) TextButton(onPressed: onClear, child: const Text('Kaldır')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
