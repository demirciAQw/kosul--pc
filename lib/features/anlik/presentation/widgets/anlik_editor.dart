import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/core_providers.dart';
import '../../../../core/utils/formatters.dart';
import '../../anlik_providers.dart';
import '../../domain/anlik.dart';
import '../../domain/tag_tree.dart';
import 'chip_bars.dart';
import 'mention_field.dart';
import 'pickers.dart';

/// Anlık not yazma ve düzenleme formu; telefonda tam ekran, bilgisayarda
/// sağ panelde. Zorunlu alan yalnızca yazıdır; gerisi "Daha fazla" altında.
/// Kayıt tek dokunuşla olur; [onSaved] geri alma işlevini de verir.
class AnlikEditor extends ConsumerStatefulWidget {
  const AnlikEditor({
    super.key,
    this.existing,
    required this.onSaved,
    this.onCancel,
    this.autofocus = true,
    this.focusNode,
    this.linkCardId,
  });

  final AnlikNote? existing;
  final void Function(AnlikNote saved, Future<void> Function() undo) onSaved;
  final VoidCallback? onCancel;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Yeni notun bağlanacağı soru kartı (Defter'den "Bu soruya not yaz").
  final String? linkCardId;

  @override
  ConsumerState<AnlikEditor> createState() => AnlikEditorState();
}

class AnlikEditorState extends ConsumerState<AnlikEditor> {
  late final TextEditingController _body;
  late Set<String> _tags;
  late Set<String> _auto;
  late Set<String> _people;
  late DateTime _at;
  int? _mood;
  String? _error;
  bool _saving = false;
  final _dismissed = <String>{};

  @override
  void initState() {
    super.initState();
    _body = TextEditingController();
    _load(widget.existing);
  }

  /// Alanları verilen nottan (ya da boş yeni nottan) doldurur.
  void _load(AnlikNote? n) {
    _body.text = n?.body ?? '';
    _tags = {...?n?.tagIds};
    _auto = {...?n?.autoTagIds};
    _people = {...?n?.personIds};
    _at = n?.createdAt ?? ref.read(clockProvider)();
    _mood = n?.mood;
    _error = null;
    _dismissed.clear();
  }

  @override
  void didUpdateWidget(AnlikEditor old) {
    super.didUpdateWidget(old);
    // Bilgisayarda yan panel başka nota geçince form baştan kurulur.
    if (old.existing?.id != widget.existing?.id) {
      setState(() => _load(widget.existing));
    }
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  /// Kısayol (bilgisayar): Ctrl+S.
  Future<void> save() => _save();

  Future<void> _save({Set<String> approvedTags = const {}, Set<String> approvedPeople = const {}}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(anlikRepositoryProvider);
    final existing = widget.existing;
    try {
      final saved = await ref.read(saveAnlikProvider)(
        existing: existing,
        body: _body.text,
        mood: _mood,
        at: _at,
        subject: existing?.subject,
        mebNodeId: existing?.mebNodeId,
        topicText: existing?.topicText,
        tagIds: _tags,
        personIds: _people,
        linkedNoteIds: existing?.linkedNoteIds ?? const {},
        linkedCardIds: existing?.linkedCardIds ?? {if (widget.linkCardId != null) widget.linkCardId!},
        approvedTags: approvedTags,
        approvedPeople: approvedPeople,
        dismissedAutoKeys: _dismissed,
      );
      if (!mounted) return;
      widget.onSaved(saved, () => existing == null ? repo.deleteNote(saved.id) : repo.commit(note: existing));
    } on UnknownMentionsException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (await confirmUnknownMentions(context, e)) {
        await _save(
          approvedTags: {...approvedTags, ...e.tags},
          approvedPeople: {...approvedPeople, ...e.people},
        );
      }
      return;
    } on AnlikException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Kaydedilemedi: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pickDateTime() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (!mounted) return;
    setState(() => _at = DateTime(d.year, d.month, d.day, t?.hour ?? _at.hour, t?.minute ?? _at.minute));
  }

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MentionTextField(
          controller: _body,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          tagNames: [for (final t in tags) tagPathLabel(tags, t.id)],
          personNames: [for (final p in people) p.name],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 12),
        TagBar(
          selected: _tags,
          autoIds: _auto,
          onChanged: (next) => setState(() {
            for (final removed in _tags.difference(next)) {
              if (_auto.contains(removed)) {
                final t = tags.where((t) => t.id == removed).firstOrNull;
                if (t != null) _dismissed.add(t.name);
              }
            }
            _tags = next;
            _auto = _auto.intersection(next);
          }),
        ),
        const SizedBox(height: 8),
        PersonBar(selected: _people, onChanged: (v) => setState(() => _people = v)),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Daha fazla'),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: Text('${formatDate(_at)} ${_at.hour.toString().padLeft(2, '0')}:${_at.minute.toString().padLeft(2, '0')}'),
              subtitle: const Text('Zamanı değiştirmek için dokun'),
              onTap: _pickDateTime,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Ruh hâli'),
                  for (var i = 1; i <= 5; i++)
                    ChoiceChip(
                      key: ValueKey('mood:$i'),
                      label: Text('$i'),
                      selected: _mood == i,
                      onSelected: (s) => setState(() => _mood = s ? i : null),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (widget.onCancel != null) TextButton(onPressed: widget.onCancel, child: const Text('Vazgeç')),
            const Spacer(),
            FilledButton.icon(
              key: const ValueKey('anlik-kaydet'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Kaydet'),
            ),
          ],
        ),
      ],
    );
  }
}
