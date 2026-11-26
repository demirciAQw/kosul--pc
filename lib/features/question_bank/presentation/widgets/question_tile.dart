import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/tablet.dart' show isTabletContext;
import '../../../../core/text/turkish_text.dart';
import '../../../pdf/domain/solve.dart';
import '../../domain/question_card.dart';
import '../../../pdf/pdf_providers.dart';
import '../../question_bank_providers.dart';
import 'media_image.dart';
import 'question_actions.dart';
import '../../../../app/palette.dart';

Color statusColor(QuestionStatus status) => switch (status) {
      QuestionStatus.wrong => KocumColors.wrong,
      QuestionStatus.blank => KocumColors.blank,
      QuestionStatus.correct => KocumColors.correct,
    };

/// Galeri hissi: soru fotoğrafı, sağ üstte yıldız (GK), altta neden + zorluk.
class QuestionTile extends ConsumerStatefulWidget {
  const QuestionTile({super.key, required this.card, this.onOpen});
  final QuestionCard card;

  /// Galeride: soruyu tam ekran görüntüleyicide aç. Yoksa ayrıntı sayfası açılır.
  final VoidCallback? onOpen;

  @override
  ConsumerState<QuestionTile> createState() => _QuestionTileState();
}

class _QuestionTileState extends ConsumerState<QuestionTile> {
  final _menuKey = GlobalKey<PopupMenuButtonState<QuestionAction>>();

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final onOpen = widget.onOpen;
    final scheme = Theme.of(context).colorScheme;
    const onImage = TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600);
    final selection = ref.watch(questionSelectionProvider);
    final selected = selection.contains(card.id);
    final selecting = selection.isNotEmpty;
    // PDF kartı: dokunuş her zaman her zamanki gibi açar (geçmiş yazılır);
    // PDF bu cihazdaysa köşede küçük PDF simgesi sayfaya/kutuya götürür.
    final pdfId = card.hasPdfAnchor ? card.pdfDocumentId : null;
    final hasPdf = pdfId != null && (ref.watch(pdfAvailableProvider(pdfId)).value ?? false);
    final openPdf = hasPdf
        ? () {
            final b = card.pdfBox!;
            context.push(AppRoutes.pdfReaderAt(pdfId, card.pdfPage!, b.left, b.top, b.right, b.bottom));
          }
        : null;
    // Tablette köşede kalem simgesi: soruyu (fotoğraflı ya da PDF'li) çiz/çöz ekranında açar.
    final canSolve = solveSpaceOf(hasPdfAnchor: card.hasPdfAnchor, hasImage: card.questionImage != null) !=
        SolveSpace.none;
    final showSolve = canSolve && isTabletContext(context);
    final solved = ref.watch(solveSummariesProvider).value?[card.id];
    return Material(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: selected ? BorderSide(color: scheme.primary, width: 3) : BorderSide.none,
      ),
      child: InkWell(
        // Seçim modundayken dokunmak seçer; değilken soruyu açar.
        // Uzun bas: seçim başlatır (seçim modundaysa değiştirir). Eylem menüsü ⋮ düğmesinde.
        onTap: selecting
            ? () => ref.read(questionSelectionProvider.notifier).toggle(card.id)
            : (onOpen ?? () => context.push(AppRoutes.question(card.id))),
        onLongPress: () => ref.read(questionSelectionProvider.notifier).toggle(card.id),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (card.questionImage != null)
              MediaImage(card.questionImage!, cacheWidth: 400)
            else
              _NoPhoto(card: card),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 20, 8, 6),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: statusColor(card.status), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          card.reasonText ?? (card.topicText != null ? titleCaseTr(card.topicText!) : card.status.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: onImage,
                        ),
                      ),
                      if (solved != null) ...[
                        Icon(Icons.edit_rounded, size: 12, color: Colors.white, key: const Key('tile-solved-mark')),
                        const SizedBox(width: 2),
                        Text(
                          '${solved.attempts} · ${formatSolveDuration(solved.lastDuration)}',
                          style: onImage,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text('Z${card.difficulty}', style: onImage),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: card.isStarred ? 'Güzel Sorular klasöründen çıkar' : 'Güzel Sorular klasörüne ekle',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(backgroundColor: Colors.black38),
                onPressed: () =>
                    ref.read(questionCardRepositoryProvider).setStarred(card.id, !card.isStarred),
                icon: Icon(
                  card.isStarred ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: card.isStarred ? Colors.amber : Colors.white,
                ),
              ),
            ),
            if (!selecting)
              Positioned(
                top: 40,
                right: 4,
                child: PopupMenuButton<QuestionAction>(
                  key: _menuKey,
                  tooltip: 'Soru işlemleri',
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(backgroundColor: Colors.black38, visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 20),
                  itemBuilder: (_) => questionMenuItems(questionActionEntries(
                    card,
                    pdfAvailable: card.hasPdfAnchor ? hasPdf : null,
                    selected: selected,
                  )),
                  onSelected: (a) => performQuestionAction(context, ref, card, a),
                ),
              ),
            if (openPdf != null && !selecting)
              Positioned(
                top: 4,
                left: 4,
                child: IconButton(
                  key: const Key('tile-open-pdf'),
                  tooltip: 'PDF\'te göster',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(backgroundColor: Colors.black38),
                  onPressed: openPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined, color: Colors.white, size: 20),
                ),
              ),
            if (showSolve && !selecting)
              Positioned(
                top: 4,
                left: openPdf != null ? 44 : 4,
                child: IconButton(
                  key: const Key('tile-open-solve'),
                  tooltip: 'Çiz / Çöz',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(backgroundColor: Colors.black38),
                  onPressed: () => context.push(AppRoutes.questionSolve(card.id)),
                  icon: const Icon(Icons.draw_outlined, color: Colors.white, size: 20),
                ),
              ),
            if (selecting)
              Positioned(
                top: 6,
                left: 6,
                child: Icon(
                  selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  color: selected ? scheme.primary : Colors.white,
                  shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Fotoğrafsız (hızlı işaretlenmiş) kartın yer tutucusu: nerede olduğunu söyler.
class _NoPhoto extends StatelessWidget {
  const _NoPhoto({required this.card});
  final QuestionCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = statusColor(card.status);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            card.questionNo == null ? '?' : '${card.questionNo}',
            style: theme.textTheme.displaySmall?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Text(
              card.testLabel ?? card.sourceName,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Text(
            'Fotoğraf yok',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
