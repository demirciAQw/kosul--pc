import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/solve.dart';
import '../pdf_providers.dart';

/// Soru ayrıntısında "Çözüm süresi": deneme başına, çizgi zamanlarından.
/// Karttaki sn/soru (deneme sınavı ortalaması) alanından ayrıdır.
class SolveTimeSection extends ConsumerWidget {
  const SolveTimeSection({super.key, required this.questionId});
  final String questionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attempts = ref.watch(solveAttemptsProvider(questionId)).value ?? const <SolveAttempt>[];
    if (attempts.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const Key('solve-time-section'),
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Çözüm süresi', style: Theme.of(context).textTheme.titleSmall),
          for (final a in attempts)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.timer_outlined, size: 16),
              label: Text('${a.no}. deneme: ${formatSolveDuration(a.duration)}'),
            ),
        ],
      ),
    );
  }
}
