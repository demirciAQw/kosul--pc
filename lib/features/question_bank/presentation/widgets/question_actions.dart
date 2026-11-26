import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../pdf/domain/solve.dart';
import '../../../pdf/pdf_providers.dart';
import '../../domain/question_card.dart';
import '../../question_bank_providers.dart';

/// Bir soru kartında yapılabilen eylemler (görüntüleyici, ayrıntı, kart menüsü).
enum QuestionAction { edit, openPdf, solve, select, delete }

const kPdfMissingHint = 'PDF bu cihazda yok';

/// Bir eylemin o kart için görünümü: etiket, simge, açık mı.
class QuestionActionEntry {
  const QuestionActionEntry(this.action, this.label, this.icon, {this.enabled = true, this.hint});
  final QuestionAction action;
  final String label;
  final IconData icon;
  final bool enabled;
  final String? hint;
}

/// Kartın PDF'i bu cihazda var mı. PDF'siz kartta `null` (düğme hiç çıkmaz).
bool? questionPdfAvailable(WidgetRef ref, QuestionCard card) {
  if (!card.hasPdfAnchor) return null;
  return ref.watch(pdfAvailableProvider(card.pdfDocumentId!)).value ?? false;
}

/// Kart için eylem listesi (saf: durum dışarıdan verilir).
List<QuestionActionEntry> questionActionEntries(
  QuestionCard card, {
  required bool? pdfAvailable,
  required bool selected,
}) {
  final canSolve = solveSpaceOf(hasPdfAnchor: card.hasPdfAnchor, hasImage: card.questionImage != null) !=
      SolveSpace.none;
  return [
    const QuestionActionEntry(QuestionAction.edit, 'Düzenle', Icons.edit_outlined),
    if (pdfAvailable != null)
      QuestionActionEntry(
        QuestionAction.openPdf,
        'PDF\'te aç',
        Icons.picture_as_pdf_outlined,
        enabled: pdfAvailable,
        hint: pdfAvailable ? null : kPdfMissingHint,
      ),
    if (canSolve) const QuestionActionEntry(QuestionAction.solve, 'Çiz / Çöz', Icons.draw_outlined),
    QuestionActionEntry(
      QuestionAction.select,
      selected ? 'Seçimden çıkar' : 'Seç',
      selected ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
    ),
    const QuestionActionEntry(QuestionAction.delete, 'Sil', Icons.delete_outline_rounded),
  ];
}

/// Onaylı silme. Silindiyse `true`.
Future<bool> confirmDeleteQuestion(BuildContext context, WidgetRef ref, QuestionCard card) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Soruyu sil?'),
      content: const Text('Soru, çözümü ve fotoğrafları kalıcı olarak silinir.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Vazgeç')),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Sil')),
      ],
    ),
  );
  if (ok != true) return false;
  await ref.read(deleteQuestionCardProvider).call(card.id);
  // Silinen kart seçimde kalmasın ("n soru seçili" ve toplu eylem yanlış sayar).
  if (ref.read(questionSelectionProvider).contains(card.id)) {
    ref.read(questionSelectionProvider.notifier).toggle(card.id);
  }
  return true;
}

/// Eylemi yürütür. `delete` ve `select` dışındakiler gezinir. Silme sonucu
/// `true` döner (çağıran ekran kendini toparlar).
Future<bool> performQuestionAction(
  BuildContext context,
  WidgetRef ref,
  QuestionCard card,
  QuestionAction action,
) async {
  switch (action) {
    case QuestionAction.edit:
      unawaited(context.push(AppRoutes.editQuestion(card.id)));
    case QuestionAction.openPdf:
      final b = card.pdfBox;
      if (card.pdfDocumentId == null || card.pdfPage == null || b == null) return false;
      unawaited(context.push(AppRoutes.pdfReaderAt(card.pdfDocumentId!, card.pdfPage!, b.left, b.top, b.right, b.bottom,
          questionId: card.id)));
    case QuestionAction.solve:
      unawaited(context.push(AppRoutes.questionSolve(card.id)));
    case QuestionAction.select:
      ref.read(questionSelectionProvider.notifier).toggle(card.id);
    case QuestionAction.delete:
      return confirmDeleteQuestion(context, ref, card);
  }
  return false;
}

/// Üstte açık, YAZILI eylem çubuğu: tek satır; dar ekranda yatay kayar (taşmaz).
class QuestionActionBar extends ConsumerWidget implements PreferredSizeWidget {
  const QuestionActionBar({super.key, required this.card, required this.onAction, this.keyPrefix = 'act'});

  final QuestionCard card;

  /// Eylem seçilince çağrılır (ekran kendi akışını yürütür).
  final void Function(QuestionAction action) onAction;
  final String keyPrefix;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(questionSelectionProvider).contains(card.id);
    final entries = questionActionEntries(card, pdfAvailable: questionPdfAvailable(ref, card), selected: selected);
    final theme = Theme.of(context);
    return SizedBox(
      height: 52,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _button(theme, entries[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(ThemeData theme, QuestionActionEntry e) {
    final button = FilledButton.tonalIcon(
      key: Key('$keyPrefix-${_keyName(e.action)}'),
      onPressed: e.enabled ? () => onAction(e.action) : null,
      icon: Icon(e.icon, size: 18),
      label: Text(e.label),
      style: e.action == QuestionAction.delete ? FilledButton.styleFrom(foregroundColor: theme.colorScheme.error) : null,
    );
    return e.hint == null ? button : Tooltip(message: e.hint!, triggerMode: TooltipTriggerMode.tap, child: button);
  }
}

String _keyName(QuestionAction a) => switch (a) {
      QuestionAction.edit => 'edit',
      QuestionAction.openPdf => 'open-pdf',
      QuestionAction.solve => 'solve',
      QuestionAction.select => 'select',
      QuestionAction.delete => 'delete',
    };

/// Kart menüsü (⋮ ve uzun basış): aynı eylemler, PDF yoksa devre dışı + ipucu.
List<PopupMenuEntry<QuestionAction>> questionMenuItems(List<QuestionActionEntry> entries) => [
      for (final e in entries)
        PopupMenuItem<QuestionAction>(
          key: Key('menu-${_keyName(e.action)}'),
          value: e.action,
          enabled: e.enabled,
          child: Row(
            children: [
              Icon(e.icon, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(e.hint == null ? e.label : '${e.label} (${e.hint})')),
            ],
          ),
        ),
    ];
