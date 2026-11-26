import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import '../../features/curriculum/domain/curriculum.dart';
import '../../features/library/domain/library.dart';
import '../../features/library/domain/progress.dart';
import '../../features/library/library_providers.dart';
import '../../features/question_bank/domain/question_card.dart';
import '../../features/question_bank/domain/quick_mark.dart';
import '../../features/question_bank/question_bank_providers.dart';
import '../widgets/desktop_page.dart';
import 'optic_entry.dart';

/// Optik sayfasında seçili test (düğüm kimliği). Kitaplar sayfasındaki
/// "Optik gir" bunu doldurup bölümü değiştirir.
class OpticTarget extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? nodeId) => state = nodeId;
}

final opticTargetProvider = NotifierProvider<OpticTarget, String?>(OpticTarget.new);

/// Kitap testinin cevaplarını klavyeyle hızlı gir: A–E (anahtarla) ya da D/Y/B
/// (anahtarsız); her tuştan sonra sonraki soruya geçilir. Kayıt telefondakiyle
/// aynı yoldan yapılır: `QuickMarkQuestions` (defter kartları) ve test sonucu.
class DesktopOpticPage extends ConsumerStatefulWidget {
  const DesktopOpticPage({super.key});

  @override
  ConsumerState<DesktopOpticPage> createState() => _DesktopOpticPageState();
}

class _DesktopOpticPageState extends ConsumerState<DesktopOpticPage> {
  final _gridFocus = FocusNode(debugLabel: 'optik-izgara');
  final _keyCtrl = TextEditingController();
  Book? _book;
  ContentNode? _test;
  OpticEntry? _entry;
  bool _saving = false;
  String? _message;
  String? _loadedFor;

  @override
  void dispose() {
    _gridFocus.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  QuickMarkContext _context(Book book, ContentNode test) => QuickMarkContext(
        origin: QuestionOrigin.book,
        subject: subjectKey(book.examType, book.subject),
        sourceName: book.title,
        bookId: book.id,
        contentNodeId: test.id,
        mebNodeId: effectiveMeb(book, test.id),
        testLabel: nodeLabel(book, test.id),
        linkByTest: true,
      );

  Future<void> _load(Book book, ContentNode test) async {
    final marks = await ref.read(quickMarkProvider).existingMarks(_context(book, test));
    if (!mounted) return;
    setState(() {
      _book = book;
      _test = test;
      _entry = OpticEntry(total: test.questionCount!, initial: marks, answerKey: parseAnswerKey(_keyCtrl.text));
      _message = null;
    });
    _gridFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final entry = _entry;
    if (entry == null || (e is! KeyDownEvent && e is! KeyRepeatEvent)) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && k == LogicalKeyboardKey.keyS) {
      _save();
      return KeyEventResult.handled;
    }
    if (ctrl || HardwareKeyboard.instance.isAltPressed || HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    var handled = true;
    setState(() {
      if (k == LogicalKeyboardKey.arrowLeft) {
        entry.move(-1);
      } else if (k == LogicalKeyboardKey.arrowRight) {
        entry.move(1);
      } else if (k == LogicalKeyboardKey.arrowUp) {
        entry.move(-10);
      } else if (k == LogicalKeyboardKey.arrowDown) {
        entry.move(10);
      } else if (k == LogicalKeyboardKey.tab) {
        entry.toggleMode();
      } else if (k == LogicalKeyboardKey.backspace) {
        entry.press('Backspace');
      } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
        entry.press('Enter');
      } else if (k == LogicalKeyboardKey.space) {
        entry.press(' ');
      } else {
        final ch = e.character;
        handled = ch != null && ch.isNotEmpty && entry.press(ch);
      }
    });
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  Future<void> _save() async {
    final book = _book, test = _test, entry = _entry;
    if (book == null || test == null || entry == null || _saving) return;
    setState(() => _saving = true);
    try {
      final ctx = _context(book, test);
      final summary = await ref.read(quickMarkProvider)(ctx, total: entry.total, marks: entry.marks);
      // Şıkla girildiyse cevaplar kartlara da yazılır.
      final repo = ref.read(questionCardRepositoryProvider);
      if (entry.answerKey.isNotEmpty) {
        for (final c in await repo.findLinked(contentNodeId: test.id)) {
          final no = c.questionNo;
          if (no == null || no > entry.total || c.status == QuestionStatus.correct) continue;
          final key = entry.keyOf(no);
          if (key == null) continue;
          await repo.update(c.copyWith(correctAnswer: () => key, givenAnswer: () => c.status == QuestionStatus.wrong ? entry.given[no] : null));
        }
      }
      await ref.read(testProgressRepositoryProvider).save(TestResult(
            nodeId: test.id,
            bookId: book.id,
            solvedAt: ref.read(clockProvider)(),
            correct: entry.correct,
            wrong: entry.wrong,
            blank: entry.blank,
            total: entry.total,
          ));
      if (mounted) setState(() => _message = '${summary.message} Net: ${entry.net.toStringAsFixed(2)}');
    } catch (e) {
      if (mounted) setState(() => _message = 'Kaydedilemedi: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final books = ref.watch(libraryProvider).value ?? const <Book>[];
    final target = ref.watch(opticTargetProvider);

    // Kitaplar sayfasından gelen hedef: testi ve kitabı bul, yükle.
    if (target != null && target != _loadedFor) {
      _loadedFor = target;
      for (final b in books) {
        final t = findNode(b, target);
        if (t != null && t.questionCount != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Hedef bir kez kullanılır; sayfaya sonra dönünce eski test yeniden açılmaz.
            ref.read(opticTargetProvider.notifier).set(null);
            _load(b, t);
          });
          break;
        }
      }
    }

    final tests = _book == null ? const <ContentNode>[] : [for (final l in progressLeaves(_book!)) if (l.questionCount != null) l];
    final entry = _entry;
    return DesktopPage(
      title: 'Optik',
      subtitle: 'A–E / D-Y-B ile gir · ←→↑↓ gez · Boşluk boş · Geri sil · Tab kip · Ctrl+S kaydet',
      actions: [
        FilledButton.icon(
          key: const ValueKey('optik-kaydet'),
          onPressed: entry == null || _saving ? null : _save,
          icon: const Icon(Icons.check),
          label: const Text('Kaydet (Ctrl+S)'),
        ),
      ],
      child: books.isEmpty
          ? const Center(child: Text('Önce Kitaplar bölümünden bir kitap ekle.'))
          : Focus(
              focusNode: _gridFocus,
              onKeyEvent: _onKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 300,
                        child: DropdownButtonFormField<Book>(
                          key: const ValueKey('optik-kitap'),
                          initialValue: _book,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Kitap'),
                          items: [for (final b in books) DropdownMenuItem(value: b, child: Text(b.title, overflow: TextOverflow.ellipsis))],
                          onChanged: (b) => setState(() {
                            _book = b;
                            _test = null;
                            _entry = null;
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 360,
                        child: DropdownButtonFormField<ContentNode>(
                          key: ValueKey('optik-test:${_book?.id}'),
                          initialValue: _test,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: tests.isEmpty && _book != null ? 'Soru sayısı bilinen test yok' : 'Test'),
                          items: [
                            for (final t in tests)
                              DropdownMenuItem(value: t, child: Text('${nodeLabel(_book!, t.id)} (${t.questionCount})', overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: _book == null ? null : (t) => t == null ? null : _load(_book!, t),
                        ),
                      ),
                    ],
                  ),
                  if (entry != null) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('optik-anahtar'),
                      controller: _keyCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Cevap anahtarı (isteğe bağlı: ABCDE… yapıştır)',
                        helperText: 'Anahtar varsa A–E ile işaretlediğin şık girilir, durum kendiliğinden bulunur.',
                      ),
                      onChanged: (v) => setState(() => entry.setKey(parseAnswerKey(v))),
                      onSubmitted: (_) => _gridFocus.requestFocus(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        SegmentedButton<EntryMode>(
                          key: const ValueKey('optik-kip'),
                          segments: const [
                            ButtonSegment(value: EntryMode.status, label: Text('D / Y / B')),
                            ButtonSegment(value: EntryMode.choice, label: Text('A–E şık')),
                          ],
                          selected: {entry.mode},
                          onSelectionChanged: (v) => setState(() {
                            if (v.first != entry.mode) entry.toggleMode();
                            _gridFocus.requestFocus();
                          }),
                        ),
                        const Spacer(),
                        Text('Doğru ${entry.correct}   Yanlış ${entry.wrong}   Boş ${entry.blank}   Net ${entry.net.toStringAsFixed(2)}',
                            key: const ValueKey('optik-sayac'), style: theme.textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (var n = 1; n <= entry.total; n++) _cell(theme, entry, n)],
                    ),
                    if (_message != null)
                      Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!, key: const ValueKey('optik-mesaj'))),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Text('Bir kitap ve test seç.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _cell(ThemeData theme, OpticEntry entry, int n) {
    final s = entry.marks[n];
    final selected = entry.cursor == n;
    final scheme = theme.colorScheme;
    final bg = switch (s) {
      QuestionStatus.wrong => scheme.errorContainer,
      QuestionStatus.blank => scheme.tertiaryContainer,
      _ => scheme.surfaceContainerHighest,
    };
    final label = switch (s) {
      QuestionStatus.wrong => entry.given[n] ?? 'Y',
      QuestionStatus.blank => 'B',
      _ => entry.keyOf(n) ?? '',
    };
    return InkWell(
      key: ValueKey('hucre:$n'),
      onTap: () {
        setState(() => entry.select(n));
        _gridFocus.requestFocus();
      },
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 3 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$n', style: theme.textTheme.labelSmall),
            Text(label, style: theme.textTheme.titleMedium?.copyWith(color: s == null ? scheme.outline : null)),
          ],
        ),
      ),
    );
  }
}
