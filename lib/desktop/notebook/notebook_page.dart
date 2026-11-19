import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/palette.dart';
import '../../core/utils/formatters.dart';
import '../../features/anlik/presentation/widgets/card_links.dart';
import '../../features/ocr/domain/ocr.dart';
import '../../features/ocr/ocr_providers.dart';
import '../../features/question_bank/domain/question_card.dart';
import '../../features/question_bank/domain/similar_questions.dart';
import '../../features/question_bank/presentation/widgets/media_image.dart';
import '../../features/question_bank/similar_providers.dart';
import '../widgets/desktop_page.dart';
import 'domain/notebook_table.dart';
import 'notebook_providers.dart';

const _rowHeight = 40.0;

/// Defter: solda filtreli, sıralanabilir tablo; sağda seçili sorunun ayrıntısı.
/// ↑/↓ (ve PageUp/PageDown) ile satırlar arasında gezilir.
class NotebookPage extends ConsumerStatefulWidget {
  const NotebookPage({super.key});

  @override
  ConsumerState<NotebookPage> createState() => _NotebookPageState();
}

class _NotebookPageState extends ConsumerState<NotebookPage> {
  final _scroll = ScrollController();
  final _tableFocus = FocusNode(debugLabel: 'defter-tablosu');
  late final _search = TextEditingController(text: ref.read(notebookQueryProvider).text);

  @override
  void dispose() {
    _scroll.dispose();
    _tableFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _setQuery(NotebookQuery q) => ref.read(notebookQueryProvider.notifier).set(q);

  void _select(String id) {
    ref.read(notebookSelectionProvider.notifier).select(id);
    _tableFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final delta = key == LogicalKeyboardKey.arrowDown
        ? 1
        : key == LogicalKeyboardKey.arrowUp
            ? -1
            : key == LogicalKeyboardKey.pageDown
                ? 10
                : key == LogicalKeyboardKey.pageUp
                    ? -10
                    : 0;
    if (delta == 0) return KeyEventResult.ignored;
    final rows = ref.read(notebookVisibleRowsProvider);
    if (rows.isEmpty) return KeyEventResult.handled;
    final current = rows.indexWhere((r) => r.card.id == ref.read(notebookSelectionProvider));
    final target = current < 0 ? (delta > 0 ? 0 : rows.length - 1) : current + delta;
    final next = math.max<int>(0, math.min<int>(rows.length - 1, target));
    ref.read(notebookSelectionProvider.notifier).select(rows[next].card.id);
    _reveal(next);
    return KeyEventResult.handled;
  }

  /// Seçili satır görünür alanda kalsın.
  void _reveal(int index) {
    if (!_scroll.hasClients) return;
    final top = index * _rowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + _rowHeight - view);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(notebookRowsProvider);
    final rows = ref.watch(notebookVisibleRowsProvider);
    final query = ref.watch(notebookQueryProvider);
    final selectedId = ref.watch(notebookSelectionProvider);
    final total = all.value?.length;
    return DesktopPage(
      title: 'Defter',
      subtitle: total == null ? null : '$total soru · ${rows.length} gösteriliyor',
      child: all.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Defter okunamadı: $e')),
        data: (list) => list.isEmpty
            ? const _EmptyNotebook()
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 11,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _FilterBar(
                          query: query,
                          search: _search,
                          onChanged: _setQuery,
                        ),
                        const Divider(height: 1),
                        _HeaderRow(query: query, onSort: (c) => _setQuery(query.sortBy(c))),
                        const Divider(height: 1),
                        Expanded(
                          child: rows.isEmpty
                              ? const Center(child: Text('Filtreye uyan soru yok.'))
                              : Focus(
                                  focusNode: _tableFocus,
                                  autofocus: true,
                                  onKeyEvent: _onKey,
                                  child: ListView.builder(
                                    controller: _scroll,
                                    itemExtent: _rowHeight,
                                    itemCount: rows.length,
                                    itemBuilder: (context, i) => _TableRow(
                                      row: rows[i],
                                      selected: rows[i].card.id == selectedId,
                                      onTap: () => _select(rows[i].card.id),
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 9,
                    child: _DetailPane(
                      row: list.where((r) => r.card.id == selectedId).firstOrNull,
                      onSelect: _select,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EmptyNotebook extends StatelessWidget {
  const _EmptyNotebook();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.phone_android, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('Defter boş.', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Telefondaki veriyi almak için Ayarlar → Telefondan veri al.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Filtreler ─────────────────────────

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.query, required this.search, required this.onChanged});

  final NotebookQuery query;
  final TextEditingController search;
  final ValueChanged<NotebookQuery> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(notebookOptionsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 280,
            child: TextField(
              controller: search,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: 'Ara: konu, kaynak, soru metni…',
              ),
              onChanged: (t) => onChanged(query.copyWith(text: t)),
            ),
          ),
          _Picker<String>(
            allLabel: 'Tüm dersler',
            value: query.subject,
            values: options.subjects,
            label: (s) => s,
            onChanged: (v) => onChanged(query.copyWith(subject: () => v)),
          ),
          _Picker<String>(
            allLabel: 'Tüm kaynaklar',
            value: query.source,
            values: options.sources,
            label: (s) => s,
            onChanged: (v) => onChanged(query.copyWith(source: () => v)),
          ),
          _Picker<MistakeReason>(
            allLabel: 'Tüm nedenler',
            value: query.reason,
            values: options.reasons,
            label: (r) => r.label,
            onChanged: (v) => onChanged(query.copyWith(reason: () => v)),
          ),
          for (final s in QuestionStatus.values)
            FilterChip(
              label: Text(s.label),
              avatar: _StatusDot(s),
              selected: query.statuses.contains(s),
              onSelected: (on) => onChanged(query.copyWith(
                statuses: on ? {...query.statuses, s} : ({...query.statuses}..remove(s)),
              )),
            ),
          if (query.isFiltered)
            TextButton.icon(
              onPressed: () {
                search.clear();
                onChanged(query.cleared());
              },
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('Temizle'),
            ),
        ],
      ),
    );
  }
}

class _Picker<T> extends StatelessWidget {
  const _Picker({
    required this.allLabel,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final String allLabel;
  final T? value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T?>(
          isExpanded: true,
          isDense: true,
          value: values.contains(value) ? value : null,
          items: [
            DropdownMenuItem<T?>(value: null, child: Text(allLabel)),
            for (final v in values)
              DropdownMenuItem<T?>(value: v, child: Text(label(v), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ───────────────────────── Tablo ─────────────────────────

/// Sütun genişlikleri: tarih ve durum sabit, diğerleri esnek.
Widget _cell(NotebookColumn column, Widget child) => switch (column) {
      NotebookColumn.date => SizedBox(width: 92, child: child),
      NotebookColumn.status => SizedBox(width: 92, child: child),
      NotebookColumn.subject => Expanded(flex: 3, child: child),
      NotebookColumn.topic => Expanded(flex: 4, child: child),
      NotebookColumn.source => Expanded(flex: 4, child: child),
      NotebookColumn.reason => Expanded(flex: 3, child: child),
    };

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.query, required this.onSort});

  final NotebookQuery query;
  final ValueChanged<NotebookColumn> onSort;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600);
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            for (final c in NotebookColumn.values)
              _cell(
                c,
                InkWell(
                  onTap: () => onSort(c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: Row(
                      children: [
                        Flexible(child: Text(c.label, style: style, overflow: TextOverflow.ellipsis)),
                        if (query.sort == c)
                          Icon(query.ascending ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 24),
          ],
        ),
      ),
    );
  }
}

String _shortDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

class _TableRow extends StatelessWidget {
  const _TableRow({required this.row, required this.selected, required this.onTap});

  final NotebookRow row;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme.bodyMedium;
    final muted = text?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final card = row.card;
    Widget t(String s, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(s.isEmpty ? '—' : s, maxLines: 1, overflow: TextOverflow.ellipsis, style: s.isEmpty ? muted : style ?? text),
        );
    return Material(
      color: selected ? theme.colorScheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _cell(NotebookColumn.date, t(_shortDate(card.createdAt), style: muted)),
              _cell(NotebookColumn.subject, t(card.subject)),
              _cell(NotebookColumn.topic, t(row.topic)),
              _cell(NotebookColumn.source, Tooltip(message: card.locationText, child: t(row.source))),
              _cell(
                NotebookColumn.status,
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(children: [
                    _StatusDot(card.status),
                    const SizedBox(width: 6),
                    Flexible(child: Text(card.status.label, style: text, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              ),
              _cell(NotebookColumn.reason, t(row.reason)),
              SizedBox(
                width: 24,
                child: row.deletedOnPhone
                    ? const Tooltip(
                        message: 'Telefonda silindi',
                        child: Icon(Icons.phonelink_erase, size: 16, color: KocumColors.amber),
                      )
                    : card.isStarred
                        ? const Icon(Icons.star, size: 16, color: KocumColors.star)
                        : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _statusColor(QuestionStatus s) => switch (s) {
      QuestionStatus.wrong => KocumColors.wrong,
      QuestionStatus.blank => KocumColors.blank,
      QuestionStatus.correct => KocumColors.correct,
    };

class _StatusDot extends StatelessWidget {
  const _StatusDot(this.status);

  final QuestionStatus status;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: _statusColor(status), shape: BoxShape.circle),
      );
}

// ───────────────────────── Ayrıntı ─────────────────────────

class _DetailPane extends ConsumerWidget {
  const _DetailPane({required this.row, required this.onSelect});

  final NotebookRow? row;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final r = row;
    if (r == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text('Soldan bir soru seç; ↑/↓ ile gezebilirsin.', style: muted),
          ],
        ),
      );
    }
    final card = r.card;
    final record = ref.watch(ocrRecordsProvider).value?[OcrJob.questionId(card.id)];
    final similar = ref.watch(similarQuestionsProvider(card.id));
    final solutionText = card.solutionText?.trim() ?? '';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        SelectableText(card.locationText, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Tag(card.subject),
            if (r.topic.isNotEmpty) _Tag(r.topic),
            _Tag(card.status.label, color: _statusColor(card.status)),
            if (card.reasonText != null) _Tag(card.reasonText!),
            _Tag(formatDate(card.createdAt)),
            if (card.isStarred) const _Tag('Güzel soru', color: KocumColors.star),
            if (r.deletedOnPhone) const _Tag('Telefonda silindi', color: KocumColors.amber),
          ],
        ),
        const SizedBox(height: 12),
        CardTagsSection(cardId: card.id),
        if (card.answerText != null) ...[
          const SizedBox(height: 12),
          Text(card.answerText!, style: theme.textTheme.bodyLarge),
        ],
        if (card.note != null && card.note!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          _Box(child: SelectableText(card.note!)),
        ],
        const _Heading('Soru'),
        if (card.questionImage != null) _Photo(card.questionImage!) else Text('Fotoğraf yok.', style: muted),
        if (card.solutionImage != null || solutionText.isNotEmpty) ...[
          const _Heading('Çözüm'),
          if (card.solutionImage != null) _Photo(card.solutionImage!),
          if (solutionText.isNotEmpty) ...[
            const SizedBox(height: 8),
            _Box(child: SelectableText(solutionText)),
          ],
        ],
        const _Heading('Fotoğraftan okunan metin'),
        if (record == null)
          Text(
            card.questionImage == null ? 'Fotoğraf yok.' : 'Henüz okunmadı (okuma telefonda yapılır).',
            style: muted,
          )
        else if (!record.ok)
          Text('Okunamadı.', style: muted)
        else
          _Box(child: SelectableText(record.fullText.trim().isEmpty ? '—' : record.fullText)),
        const _Heading('Benzer sorular'),
        if (similar.mistakes.isEmpty && similar.correct.isEmpty)
          Text('Benzer soru bulunamadı (benzerlik, fotoğrafı okunmuş sorular arasında aranır).', style: muted),
        if (similar.mistakes.isNotEmpty)
          _SimilarGroup('Yanlış / boş yaptıkların', similar.mistakes, theme.colorScheme.error, onSelect),
        if (similar.correct.isNotEmpty)
          _SimilarGroup('Doğru yaptıkların', similar.correct, KocumColors.correct, onSelect),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: color)),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );
}

/// Büyük fotoğraf; tıklayınca tam ekran yakınlaştırma.
class _Photo extends StatelessWidget {
  const _Photo(this.path);

  final String path;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          onTap: () => openImageZoom(context, path),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: MediaImage(path, fit: BoxFit.contain, cacheWidth: 1600),
            ),
          ),
        ),
      );
}

class _SimilarGroup extends StatelessWidget {
  const _SimilarGroup(this.title, this.items, this.color, this.onSelect);

  final String title;
  final List<SimilarMatch> items;
  final Color color;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Text('$title (${items.length})', style: theme.textTheme.labelLarge?.copyWith(color: color)),
        for (final m in items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: SizedBox.square(
              dimension: 44,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: m.card.questionImage == null
                    ? const Icon(Icons.image_not_supported_outlined)
                    : MediaImage(m.card.questionImage!, cacheWidth: 120),
              ),
            ),
            title: Text(m.card.locationText, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              m.reasons.isEmpty ? 'genel benzerlik' : m.reasons.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => onSelect(m.card.id),
          ),
      ],
    );
  }
}
