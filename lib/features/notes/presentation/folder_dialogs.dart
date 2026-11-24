import 'package:flutter/material.dart';

import '../domain/ink_folder.dart';
import 'folder_nav.dart';
import 'notebooks_screen.dart' show notebookCoverColors;

typedef FolderDialogResult = ({String name, int color});

/// Yeni klasör / klasör düzenleme: ad ve renk.
Future<FolderDialogResult?> showFolderDialog(
  BuildContext context, {
  InkFolderRecord? initial,
}) => showDialog<FolderDialogResult>(
  context: context,
  builder: (_) => _FolderDialog(initial: initial),
);

class _FolderDialog extends StatefulWidget {
  const _FolderDialog({this.initial});
  final InkFolderRecord? initial;

  @override
  State<_FolderDialog> createState() => _FolderDialogState();
}

class _FolderDialogState extends State<_FolderDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late int _color = widget.initial?.color ?? notebookCoverColors[1];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  FolderDialogResult get _result {
    final n = _name.text.trim();
    return (name: n.isEmpty ? 'Adsız klasör' : n, color: _color);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Yeni klasör' : 'Klasörü düzenle'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('folder-name-field'),
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Klasör adı'),
            onSubmitted: (_) => Navigator.pop(context, _result),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in notebookCoverColors)
                InkWell(
                  key: Key('folder-color-${c.toRadixString(16)}'),
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: Color(c),
                    child: _color == c
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Vazgeç'),
      ),
      FilledButton(
        key: const Key('folder-dialog-ok'),
        onPressed: () => Navigator.pop(context, _result),
        child: const Text('Tamam'),
      ),
    ],
  );
}

/// Klasör seçici ("Taşı…"). Dönüş `null`: vazgeçildi; `(id: null)`: ana düzey (kök).
Future<({String? id})?> showFolderPicker(
  BuildContext context, {
  required List<InkFolderRecord> folders,
  String? currentId,
  String title = 'Nereye taşınsın?',
}) {
  final choices = folderChoices(folders);
  return showDialog<({String? id})>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              key: const Key('folder-pick-root'),
              leading: const Icon(Icons.home_outlined),
              title: const Text('Defterler (ana düzey)'),
              selected: currentId == null,
              onTap: () => Navigator.pop(ctx, (id: null)),
            ),
            for (final c in choices)
              ListTile(
                key: Key('folder-pick-${c.folder.id}'),
                contentPadding: EdgeInsets.only(
                  left: 16.0 + c.depth * 20,
                  right: 16,
                ),
                leading: Icon(Icons.folder, color: Color(c.folder.color)),
                title: Text(
                  c.folder.name.isEmpty ? 'Adsız klasör' : c.folder.name,
                ),
                selected: currentId == c.folder.id,
                onTap: () => Navigator.pop(ctx, (id: c.folder.id)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Vazgeç'),
        ),
      ],
    ),
  );
}

/// Klasör silme onayı; içindekilerin üst düzeye çıkacağını söyler.
Future<bool> confirmDeleteFolder(
  BuildContext context,
  InkFolderRecord f, {
  required int subfolders,
}) async {
  final name = f.name.isEmpty ? 'Adsız klasör' : f.name;
  final parts = [
    if (f.notebookCount > 0) '${f.notebookCount} defter',
    if (subfolders > 0) '$subfolders klasör',
  ];
  final inside = parts.isEmpty
      ? 'Klasör boş.'
      : 'İçindeki ${parts.join(' ve ')} SİLİNMEZ; bir üst düzeye çıkar.';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Klasör silinsin mi?'),
      content: Text(
        '"$name" listeden kalkar. $inside Silinenler\'den geri getirebilirsin.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          key: const Key('folder-delete-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Sil'),
        ),
      ],
    ),
  );
  return ok == true;
}
