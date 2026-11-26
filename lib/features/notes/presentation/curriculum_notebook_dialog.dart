import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../curriculum/curriculum_providers.dart';
import '../../curriculum/domain/curriculum.dart';
import '../domain/ink_folder.dart';
import '../notes_providers.dart';
import 'folder_nav.dart';

/// Konu ağacından defter için seçim. [folderId]: null = ana düzey; [newFolder]: ders adıyla yeni klasör.
typedef CurriculumChoice = ({
  String examType,
  String subject,
  String? folderId,
  bool newFolder,
});

/// Seviye: ünite (0) ve konu (1) sayfa olur; bkz. `CurriculumNotebookService.maxDepth`.
const curriculumMaxDepth = 1;

/// Seçim penceresi -> oluştur -> (zaten varsa "Zaten var: aç") -> defter kimliği.
/// Dönüş null: vazgeçildi. Aynı ders için defter varsa YENİ defter açılmaz.
Future<String?> createNotebookFromCurriculumFlow(
  BuildContext context,
  WidgetRef ref, {
  String? currentFolderId,
}) async {
  final choice = await showDialog<CurriculumChoice>(
    context: context,
    builder: (_) => CurriculumNotebookDialog(initialFolderId: currentFolderId),
  );
  if (choice == null || !context.mounted) return null;
  final r = await ref
      .read(curriculumNotebookServiceProvider)
      .createNotebookFromCurriculum(
        examType: choice.examType,
        subject: choice.subject,
        maxDepth: curriculumMaxDepth,
      );
  if (!r.created) {
    if (!context.mounted) return null;
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Zaten var'),
        content: Text(
          '${choice.examType} ${choice.subject} için konu defteri zaten var. Yenisi açılmaz; mevcut defteri açabilirsin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            key: const Key('curr-open-existing'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Zaten var: aç'),
          ),
        ],
      ),
    );
    return open == true ? r.notebookId : null;
  }
  var folderId = choice.folderId;
  if (choice.newFolder) {
    folderId = await ref
        .read(inkFolderRepositoryProvider)
        .createFolder(choice.subject, parentId: currentFolderId);
  }
  if (folderId != null) {
    await ref.read(inkNotebookRepositoryProvider).moveNotebookToFolder(r.notebookId, folderId);
  }
  return r.notebookId;
}

class CurriculumNotebookDialog extends ConsumerStatefulWidget {
  const CurriculumNotebookDialog({super.key, this.initialFolderId});
  final String? initialFolderId;

  @override
  ConsumerState<CurriculumNotebookDialog> createState() =>
      _CurriculumNotebookDialogState();
}

class _CurriculumNotebookDialogState
    extends ConsumerState<CurriculumNotebookDialog> {
  String? _exam;
  String? _subject;

  /// '' ana düzey, '+' ders adıyla yeni klasör, aksi halde klasör kimliği; null = varsayılan.
  String? _folder;

  @override
  Widget build(BuildContext context) {
    final nodes =
        ref.watch(curriculumProvider).value ?? const <CurriculumNode>[];
    final folders =
        ref.watch(inkFoldersProvider).value ?? const <InkFolderRecord>[];
    final examSet = {for (final n in nodes) n.examType};
    final exams = [
      for (final e in const ['TYT', 'AYT'])
        if (examSet.contains(e)) e,
      for (final e in examSet)
        if (e != 'TYT' && e != 'AYT') e,
    ];
    if (exams.isEmpty) {
      return AlertDialog(
        title: const Text('Konu ağacından defter'),
        content: const Text('Konu ağacı henüz yüklenmedi.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Kapat'),
          ),
        ],
      );
    }
    final exam = exams.contains(_exam) ? _exam! : exams.first;
    final subjects = {
      for (final n in nodes)
        if (n.examType == exam) n.subject,
    }.toList();
    final subject = subjects.contains(_subject) ? _subject! : subjects.first;
    final chosen = depthFirst([
      for (final n in nodes)
        if (n.examType == exam &&
            n.subject == subject &&
            n.depth <= curriculumMaxDepth)
          n,
    ]);
    final units = chosen.where((n) => n.depth == 0).length;
    final folderValue = _folder ?? _defaultFolder(folders, subject);
    final choices = folderChoices(folders);
    return AlertDialog(
      title: const Text('Konu ağacından defter'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final e in exams)
                    ChoiceChip(
                      key: Key('curr-exam-$e'),
                      label: Text(e),
                      selected: e == exam,
                      onSelected: (_) => setState(() {
                        _exam = e;
                        _subject = null;
                        _folder = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final s in subjects)
                    ChoiceChip(
                      key: Key('curr-subject-$s'),
                      label: Text(s),
                      selected: s == subject,
                      onSelected: (_) => setState(() {
                        _subject = s;
                        _folder = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Klasör',
                  border: OutlineInputBorder(),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const Key('curr-folder'),
                    value: folderValue,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Ana düzey'),
                      ),
                      DropdownMenuItem(
                        value: '+',
                        child: Text('Yeni klasör: $subject'),
                      ),
                      for (final c in choices)
                        DropdownMenuItem(
                          value: c.folder.id,
                          child: Text(
                            '${'  ' * c.depth}${c.folder.name.isEmpty ? 'Adsız klasör' : c.folder.name}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _folder = v),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${chosen.length + 1} sayfa oluşturulacak: ders kapağı, $units ünite, ${chosen.length - units} konu',
                key: const Key('curr-summary'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in chosen)
                      Padding(
                        padding: EdgeInsets.only(
                          left: n.depth * 16.0,
                          top: 2,
                          bottom: 2,
                        ),
                        child: Text(
                          '${n.depth == 0 ? 'Ünite' : 'Konu'}: ${n.title}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          key: const Key('curr-ok'),
          onPressed: () => Navigator.pop<CurriculumChoice>(context, (
            examType: exam,
            subject: subject,
            folderId: folderValue == '' || folderValue == '+'
                ? null
                : folderValue,
            newFolder: folderValue == '+',
          )),
          child: const Text('Oluştur'),
        ),
      ],
    );
  }

  /// Ders adıyla klasör (bulunduğun klasörün altında) varsa o, yoksa yeni klasör.
  String _defaultFolder(List<InkFolderRecord> folders, String subject) {
    final same = childFolders(
      folders,
      widget.initialFolderId,
    ).where((f) => f.name == subject);
    return same.isEmpty ? '+' : same.first.id;
  }
}
