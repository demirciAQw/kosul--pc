import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../curriculum/curriculum_providers.dart';
import '../domain/ink_notebook.dart';
import '../notes_providers.dart';
import 'konu_picker.dart';

/// Sayfa bilgisi: başlık ve bağlı MEB konusu.
Future<void> showPageInfoSheet(BuildContext context, InkNotePageRecord page) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PageInfoSheet(page: page),
    );

class PageInfoSheet extends ConsumerStatefulWidget {
  const PageInfoSheet({super.key, required this.page});
  final InkNotePageRecord page;

  @override
  ConsumerState<PageInfoSheet> createState() => _PageInfoSheetState();
}

class _PageInfoSheetState extends ConsumerState<PageInfoSheet> {
  late final _title = TextEditingController(text: widget.page.title ?? '');
  late String? _konuId = widget.page.konuId;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final r = await showKonuPicker(context, selectedId: _konuId);
    if (r == null || !mounted) return;
    final board = ref.read(inkBoardRepositoryProvider);
    if (r.id == null) {
      await board.clearPageKonu(widget.page.id);
    } else {
      await board.setPageKonu(widget.page.id, r.id);
    }
    if (mounted) setState(() => _konuId = r.id);
  }

  Future<void> _save() async {
    await ref
        .read(inkNotebookRepositoryProvider)
        .setPageTitle(widget.page.id, _title.text);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final nodes = ref.watch(curriculumProvider).value ?? const [];
    final path = konuPathLabel(_konuId, nodes);
    final others = _konuId == null
        ? null
        : ref.watch(konuPageCountsProvider).value?[_konuId];
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sayfa bilgisi', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pageinfo-title'),
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Sayfa başlığı',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            Text('Konu', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (_konuId == null)
              const Text('Bu sayfa bir konuya bağlı değil.')
            else ...[
              Text(
                path ?? 'Konu ağaçta bulunamadı ($_konuId)',
                key: const Key('pageinfo-konu-path'),
              ),
              if (others != null)
                Text(
                  'Bu konuya bağlı $others sayfa',
                  style: theme.textTheme.bodySmall,
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('pageinfo-konu-pick'),
                  onPressed: _pick,
                  icon: const Icon(Icons.account_tree_outlined),
                  label: Text(_konuId == null ? 'Konu seç' : 'Konuyu değiştir'),
                ),
                if (_konuId != null)
                  TextButton(
                    key: const Key('pageinfo-konu-clear'),
                    onPressed: () async {
                      await ref
                          .read(inkBoardRepositoryProvider)
                          .clearPageKonu(widget.page.id);
                      if (mounted) setState(() => _konuId = null);
                    },
                    child: const Text('Konuyu kaldır'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const Key('pageinfo-save'),
                onPressed: _save,
                child: const Text('Kaydet'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sayfa şeridi küçük resminin altı: sayfa numarası, varsa başlık ve konu rozeti.
class PageStripLabel extends StatelessWidget {
  const PageStripLabel({super.key, required this.page, required this.number});
  final InkNotePageRecord page;
  final int number;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    final title = page.title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$number', style: style),
        if (title != null && title.isNotEmpty)
          Text(
            title,
            key: Key('note-thumb-title-${page.id}'),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (page.konuId != null)
          Icon(
            Icons.account_tree_outlined,
            key: Key('note-thumb-konu-${page.id}'),
            size: 12,
            color: Theme.of(context).colorScheme.primary,
          ),
      ],
    );
  }
}
