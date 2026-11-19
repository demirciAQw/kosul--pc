import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import '../../features/curriculum/domain/yks.dart';
import '../../features/library/domain/library.dart';
import '../../features/library/domain/progress.dart';
import '../../features/library/library_providers.dart';
import '../../features/library/presentation/library_sheet.dart';
import '../widgets/desktop_page.dart';
import '../desktop_providers.dart';
import 'book_tree_edit.dart';
import 'optic_page.dart';

class DesktopBookSelection extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final desktopBookSelectionProvider = NotifierProvider<DesktopBookSelection, String?>(DesktopBookSelection.new);

/// Kitaplar: kitap ekle (şablon dosyası, hazır şablon, elle), bölüm ve test
/// ağacını düzenle, test sonucunu işaretle. İş kuralı telefondakiyle aynı:
/// `LibraryRepository`, `ImportBookTemplate`, `TestProgressRepository`.
class DesktopBooksPage extends ConsumerWidget {
  const DesktopBooksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(bookProgressProvider);
    final selectedId = ref.watch(desktopBookSelectionProvider);
    final theme = Theme.of(context);
    return DesktopPage(
      title: 'Kitaplar',
      actions: [
        MenuAnchor(
          builder: (context, controller, _) => FilledButton.icon(
            key: const ValueKey('kitap-ekle'),
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.add),
            label: const Text('Kitap ekle'),
          ),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.edit_outlined),
              onPressed: () => showNewBookDialog(context, ref),
              child: const Text('Elle yeni kitap'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.upload_file_outlined),
              onPressed: () => importBookTemplateFlow(context, ref),
              child: const Text('Şablon dosyası (JSON) seç'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.library_books_outlined),
              onPressed: () => _pickBundled(context, ref),
              child: const Text('Hazır şablonlardan'),
            ),
          ],
        ),
      ],
      child: progress.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Kitaplar okunamadı: $e')),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Henüz kitap yok. Kitap ekle ile şablon seç ya da elle oluştur.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            );
          }
          final book = list.where((p) => p.book.id == selectedId).firstOrNull?.book;
          return LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 860;
            final listPane = ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final p = list[i];
                final pct = p.totalLeaves == 0 ? 0.0 : p.doneLeaves / p.totalLeaves;
                return ListTile(
                  key: ValueKey('kitap-satir:${p.book.id}'),
                  selected: p.book.id == selectedId,
                  title: Text(p.book.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${p.book.examType} ${p.book.subject} · ${p.doneLeaves}/${p.totalLeaves} bölüm'),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: pct, minHeight: 4),
                    ],
                  ),
                  isThreeLine: true,
                  onTap: () => ref.read(desktopBookSelectionProvider.notifier).select(p.book.id),
                );
              },
            );
            final detail = book == null
                ? Center(child: Text('Soldan bir kitap seç.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)))
                : BookEditor(key: ValueKey(book.id), book: book, showBack: !wide);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [SizedBox(width: 340, child: listPane), const VerticalDivider(width: 1), Expanded(child: detail)],
              );
            }
            return book == null ? listPane : detail;
          });
        },
      ),
    );
  }

  Future<void> _pickBundled(BuildContext context, WidgetRef ref) async {
    final templates = await ref.read(bundledTemplatesProvider.future);
    if (!context.mounted) return;
    final picked = await showDialog<BundledTemplate>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Hazır şablon'),
        children: [
          SizedBox(
            width: 480,
            height: 420,
            child: ListView(
              children: [
                for (final t in templates)
                  ListTile(
                    title: Text(t.title),
                    subtitle: Text('${t.shelf} · ${t.subtitle}'),
                    onTap: () => Navigator.pop(ctx, t),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null && context.mounted) await importBundledTemplateFlow(context, ref, picked);
  }
}

/// Elle yeni kitap: ad, yayınevi, sınav, ders, sayfa sayısı. Bölümler sonra eklenir.
Future<void> showNewBookDialog(BuildContext context, WidgetRef ref) async {
  final title = TextEditingController();
  final publisher = TextEditingController();
  final pages = TextEditingController(text: '200');
  var exam = 'TYT';
  String? subject;
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final subjects = [for (final s in Yks.all) if (s.examType == exam) s.name];
        return AlertDialog(
          title: const Text('Yeni kitap'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(key: const ValueKey('kitap-ad'), controller: title, autofocus: true, decoration: InputDecoration(labelText: 'Kitap adı *', errorText: error)),
                TextField(controller: publisher, decoration: const InputDecoration(labelText: 'Yayınevi')),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: exam,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Sınav'),
                        items: [for (final e in const ['TYT', 'AYT', 'YDT']) DropdownMenuItem(value: e, child: Text(e))],
                        onChanged: (v) => setState(() {
                          exam = v!;
                          subject = null;
                        }),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('ders:$exam'),
                        initialValue: subject,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Ders *'),
                        items: [for (final s in subjects) DropdownMenuItem(value: s, child: Text(s))],
                        onChanged: (v) => setState(() => subject = v),
                      ),
                    ),
                  ],
                ),
                TextField(controller: pages, decoration: const InputDecoration(labelText: 'Sayfa sayısı')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
            FilledButton(
              key: const ValueKey('kitap-olustur'),
              onPressed: () {
                if (title.text.trim().isEmpty || subject == null || (int.tryParse(pages.text.trim()) ?? 0) < 1) {
                  setState(() => error = 'Ad, ders ve sayfa sayısı gerekli');
                } else {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Oluştur'),
            ),
          ],
        );
      },
    ),
  );
  if (ok == true) {
    final book = Book(
      id: ref.read(idGeneratorProvider).next(),
      title: title.text.trim(),
      publisher: publisher.text.trim().isEmpty ? null : publisher.text.trim(),
      examType: exam,
      subject: subject!,
      pageCount: int.parse(pages.text.trim()),
      avgQuestionsPerPage: 0.5,
      createdAt: ref.read(clockProvider)(),
    );
    await ref.read(libraryRepositoryProvider).save(book);
    ref.read(desktopBookSelectionProvider.notifier).select(book.id);
  }
}

/// Seçili kitabın başlığı, ağacı ve test sonuçları.
class BookEditor extends ConsumerWidget {
  const BookEditor({super.key, required this.book, required this.showBack});
  final Book book;
  final bool showBack;

  Future<void> _save(WidgetRef ref, List<ContentNode> roots) =>
      ref.read(libraryRepositoryProvider).save(book.copyWith(roots: roots));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final results = ref.watch(testResultsProvider).value ?? const <String, TestResult>{};
    final rows = <Widget>[];
    void walk(List<ContentNode> nodes, int depth) {
      for (final n in nodes) {
        rows.add(_NodeRow(book: book, node: n, depth: depth, result: results[n.id], onSave: (roots) => _save(ref, roots)));
        walk(n.children, depth + 1);
      }
    }

    walk(book.roots, 0);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref.read(desktopBookSelectionProvider.notifier).select(null),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Liste'),
            ),
          ),
        Row(
          children: [
            Expanded(child: Text(book.title, style: theme.textTheme.titleLarge)),
            OutlinedButton.icon(
              key: const ValueKey('kitap-adi-duzenle'),
              onPressed: () => _rename(context, ref),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Adı'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('kitap-sil'),
              onPressed: () => _delete(context, ref),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Sil'),
            ),
          ],
        ),
        Text('${book.examType} ${book.subject} · ${book.publisher ?? 'yayınevi yok'} · ${book.pageCount} sayfa'),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('Bölümler ve testler', style: theme.textTheme.titleSmall),
            const Spacer(),
            FilledButton.tonalIcon(
              key: const ValueKey('unite-ekle'),
              onPressed: () => _addNode(context, ref, null, 0),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Ünite ekle'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Henüz bölüm yok.')),
        ...rows,
      ],
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController(text: book.title);
    final publisher = TextEditingController(text: book.publisher ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kitap adı'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(key: const ValueKey('ad'), controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Ad')),
            TextField(controller: publisher, decoration: const InputDecoration(labelText: 'Yayınevi')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await ref.read(libraryRepositoryProvider).rename(book.id,
          title: title.text.trim(), publisher: publisher.text.trim().isEmpty ? null : publisher.text.trim());
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kitap silinsin mi?'),
        content: Text('“${book.title}” ve bölüm ağacı silinir. Defterdeki sorular durur. Bu işlem geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('kitap-sil-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) {
      ref.read(desktopBookSelectionProvider.notifier).select(null);
      await ref.read(libraryRepositoryProvider).delete(book.id);
    }
  }

  Future<void> _addNode(BuildContext context, WidgetRef ref, String? parentId, int depth) async {
    final r = await showNodeDialog(context, title: parentId == null ? 'Yeni ünite' : 'Yeni alt başlık / test');
    if (r == null) return;
    final node = ContentNode(
      id: ref.read(idGeneratorProvider).next(),
      level: NodeLevel.fromDepth(depth),
      title: r.title,
      questionCount: r.questionCount,
      pageStart: r.pageStart,
      pageEnd: r.pageEnd,
    );
    await _save(ref, addChildTo(book.roots, parentId, node));
  }
}

class NodeEdit {
  const NodeEdit(this.title, this.questionCount, this.pageStart, this.pageEnd);
  final String title;
  final int? questionCount;
  final int? pageStart;
  final int? pageEnd;
}

/// Başlık düzenleme: ad, test soru sayısı, sayfa aralığı.
Future<NodeEdit?> showNodeDialog(BuildContext context, {required String title, ContentNode? node}) async {
  final name = TextEditingController(text: node?.title ?? '');
  final count = TextEditingController(text: node?.questionCount?.toString() ?? '');
  final from = TextEditingController(text: node?.pageStart?.toString() ?? '');
  final to = TextEditingController(text: node?.pageEnd?.toString() ?? '');
  String? error;
  return showDialog<NodeEdit>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(key: const ValueKey('dugum-ad'), controller: name, autofocus: true, decoration: InputDecoration(labelText: 'Ad *', errorText: error)),
              TextField(key: const ValueKey('dugum-soru'), controller: count, decoration: const InputDecoration(labelText: 'Testteki soru sayısı (test ise)')),
              Row(children: [
                Expanded(child: TextField(controller: from, decoration: const InputDecoration(labelText: 'İlk sayfa'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: to, decoration: const InputDecoration(labelText: 'Son sayfa'))),
              ]),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
            key: const ValueKey('dugum-kaydet'),
            onPressed: () {
              final c = int.tryParse(count.text.trim());
              final a = int.tryParse(from.text.trim()), b = int.tryParse(to.text.trim());
              if (name.text.trim().isEmpty) {
                setState(() => error = 'Bir ad yaz');
              } else if (count.text.trim().isNotEmpty && (c == null || c < 1)) {
                setState(() => error = 'Soru sayısı en az 1');
              } else if ((a != null || b != null) && (a == null || b == null || a < 1 || b < a)) {
                setState(() => error = 'Sayfa aralığı geçersiz');
              } else {
                Navigator.pop(ctx, NodeEdit(name.text.trim(), c, a, b));
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    ),
  );
}

class _NodeRow extends ConsumerWidget {
  const _NodeRow({required this.book, required this.node, required this.depth, required this.result, required this.onSave});

  final Book book;
  final ContentNode node;
  final int depth;
  final TestResult? result;
  final Future<void> Function(List<ContentNode> roots) onSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLeaf = node.children.isEmpty;
    final status = result == null
        ? null
        : result!.hasCounts
            ? '${result!.correct ?? 0}D ${result!.wrong ?? 0}Y ${result!.blank ?? 0}B'
            : 'çözüldü';
    return Padding(
      padding: EdgeInsets.only(left: depth * 24.0),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: ListTile(
          key: ValueKey('dugum:${node.id}'),
          dense: true,
          leading: Icon(isLeaf ? Icons.quiz_outlined : Icons.folder_outlined, size: 20),
          title: Text(node.title),
          subtitle: Text([
            node.level.label,
            if (node.questionCount != null) '${node.questionCount} soru',
            if (node.hasPages) 's. ${node.pageStart}–${node.pageEnd}',
          ].join(' · ')),
          trailing: Wrap(
            spacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (status != null) Chip(label: Text(status), visualDensity: VisualDensity.compact),
              IconButton(
                key: ValueKey('alt-ekle:${node.id}'),
                tooltip: 'Alt başlık ya da test ekle',
                icon: const Icon(Icons.add, size: 18),
                onPressed: depth >= 2 ? null : () => _add(context, ref),
              ),
              IconButton(tooltip: 'Yukarı', icon: const Icon(Icons.arrow_upward, size: 18), onPressed: () => onSave(moveNode(book.roots, node.id, -1))),
              IconButton(tooltip: 'Aşağı', icon: const Icon(Icons.arrow_downward, size: 18), onPressed: () => onSave(moveNode(book.roots, node.id, 1))),
              PopupMenuButton<String>(
                key: ValueKey('menu:${node.id}'),
                onSelected: (v) => _menu(context, ref, v),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'duzenle', child: Text('Düzenle')),
                  if (isLeaf) ...[
                    if (node.questionCount != null) const PopupMenuItem(value: 'optik', child: Text('Optik gir')),
                    const PopupMenuItem(value: 'cozuldu', child: Text('Çözüldü işaretle')),
                    const PopupMenuItem(value: 'sonuc', child: Text('Sonuç gir (D/Y/B)')),
                    if (result != null) const PopupMenuItem(value: 'temizle', child: Text('Çözülmedi yap')),
                  ],
                  const PopupMenuItem(value: 'sil', child: Text('Sil')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final r = await showNodeDialog(context, title: 'Yeni alt başlık / test');
    if (r == null) return;
    final child = ContentNode(
      id: ref.read(idGeneratorProvider).next(),
      level: NodeLevel.fromDepth(depth + 1),
      title: r.title,
      questionCount: r.questionCount,
      pageStart: r.pageStart,
      pageEnd: r.pageEnd,
    );
    await onSave(addChildTo(book.roots, node.id, child));
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, String action) async {
    final progress = ref.read(testProgressRepositoryProvider);
    final now = ref.read(clockProvider)();
    switch (action) {
      case 'duzenle':
        final r = await showNodeDialog(context, title: 'Başlığı düzenle', node: node);
        if (r == null) return;
        await onSave(replaceNode(
          book.roots,
          node.id,
          (n) => editNode(
            n,
            title: r.title,
            questionCount: r.questionCount,
            clearQuestionCount: r.questionCount == null,
            pageStart: r.pageStart,
            pageEnd: r.pageEnd,
            clearPages: r.pageStart == null,
          ),
        ));
      case 'optik':
        ref.read(opticTargetProvider.notifier).set(node.id);
        ref.read(desktopSectionProvider.notifier).select(DesktopSection.optic);
      case 'cozuldu':
        await progress.save(TestResult(nodeId: node.id, bookId: book.id, solvedAt: now, total: node.questionCount));
      case 'sonuc':
        final r = await _askCounts(context);
        if (r == null) return;
        await progress.save(TestResult(
          nodeId: node.id,
          bookId: book.id,
          solvedAt: now,
          correct: r.$1,
          wrong: r.$2,
          blank: r.$3,
          total: node.questionCount ?? (r.$1 + r.$2 + r.$3),
        ));
      case 'temizle':
        await progress.clear(node.id);
      case 'sil':
        final under = idsUnder(node);
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Başlık silinsin mi?'),
            content: Text(under.length == 1
                ? '“${node.title}” silinir. Bu başlığa bağlı sorular defterde kalır.'
                : '“${node.title}” ve altındaki ${under.length - 1} başlık silinir. Bağlı sorular defterde kalır.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
              FilledButton(key: const ValueKey('dugum-sil-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
            ],
          ),
        );
        if (ok != true) return;
        // Sorular silinmez, yalnızca bu başlıktan ayrılır (yetim bağ kalmasın).
        final db = ref.read(appDatabaseProvider);
        for (final id in under) {
          await db.customStatement('UPDATE question_cards SET content_node_id = NULL WHERE content_node_id = ?', [id]);
        }
        await onSave(removeNodeFrom(book.roots, node.id));
    }
  }

  Future<(int, int, int)?> _askCounts(BuildContext context) {
    final d = TextEditingController(), y = TextEditingController(), b = TextEditingController();
    return showDialog<(int, int, int)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sonuç'),
        content: SizedBox(
          width: 360,
          child: Row(children: [
            Expanded(child: TextField(key: const ValueKey('sonuc-d'), controller: d, autofocus: true, decoration: const InputDecoration(labelText: 'Doğru'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(key: const ValueKey('sonuc-y'), controller: y, decoration: const InputDecoration(labelText: 'Yanlış'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(key: const ValueKey('sonuc-b'), controller: b, decoration: const InputDecoration(labelText: 'Boş'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
            key: const ValueKey('sonuc-kaydet'),
            onPressed: () => Navigator.pop(ctx, (int.tryParse(d.text) ?? 0, int.tryParse(y.text) ?? 0, int.tryParse(b.text) ?? 0)),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }
}
