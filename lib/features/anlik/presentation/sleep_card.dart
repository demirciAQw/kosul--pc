import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/palette.dart';
import '../../../app/widgets/tone_icon.dart';
import '../../../core/utils/formatters.dart';
import '../../health/presentation/sleep_watch_row.dart';
import '../anlik_providers.dart';
import '../domain/anlik.dart';
import '../domain/anlik_search.dart';
import 'anlik_screens.dart';

/// Ana ekranda tek dokunuşla Yattım / Kalktım. Son kayda göre doğru düğme
/// çıkar; kayıt anında yapılır, "Geri al" ile geri alınır.
class SleepCard extends ConsumerWidget {
  const SleepCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final awake = ref.watch(sleepIsAwakeProvider);
    final notes = ref.watch(anlikNotesProvider).value ?? const <AnlikNote>[];
    final nights = sleepNights(notes);
    final last = nights.isEmpty ? null : nights.last;
    final lastText = last == null
        ? 'Uykunu tek dokunuşla kaydet'
        : last.wake == null
            ? 'Yattın: ${formatShortDate(last.bed)}'
            : 'Son gece: ${formatApproxDuration(last.length!.inSeconds.toDouble())}';
    return Card(
      child: Column(children: [
        ListTile(
          key: const ValueKey('uyku-karti'),
          leading: ToneIcon(awake ? Icons.bedtime_outlined : Icons.wb_sunny_outlined, color: KocumColors.blue),
          title: Text(awake ? 'Yattım' : 'Kalktım'),
          subtitle: Text(lastText),
          trailing: const Icon(Icons.touch_app_outlined),
          onTap: () async {
            final messenger = ScaffoldMessenger.of(context);
            final repo = ref.read(anlikRepositoryProvider);
            final note = await ref.read(saveAnlikProvider)(body: '', kind: awake ? AnlikKind.yattim : AnlikKind.kalktim);
            showSavedSnack(messenger, awake ? 'İyi geceler! Yattın.' : 'Günaydın! Kalktın.', () => repo.deleteNote(note.id));
          },
        ),
        const SleepWatchRow(),
      ]),
    );
  }
}
