import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/palette.dart';
import '../../../app/widgets/tone_icon.dart';
import '../health_providers.dart';

/// Ana ekranda hızlı "Stresim 1-5" girişi (kaynak: manuel). 1 rahat, 5 çok stresli.
class StressCard extends ConsumerStatefulWidget {
  const StressCard({super.key});

  @override
  ConsumerState<StressCard> createState() => _StressCardState();
}

class _StressCardState extends ConsumerState<StressCard> {
  int? _last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('stres-karti'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ToneIcon(Icons.self_improvement_outlined, color: KocumColors.amber),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_last == null ? 'Stresim (1 rahat, 5 çok stresli)' : 'Kaydedildi: $_last/5',
                  style: theme.textTheme.titleSmall),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            for (var i = 1; i <= 5; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: OutlinedButton(
                    key: ValueKey('stres-$i'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: _last == i ? theme.colorScheme.secondaryContainer : null,
                    ),
                    onPressed: () async {
                      await ref.read(healthRepositoryProvider).addManualStress(i);
                      await ref.read(healthRepositoryProvider).refreshStressDays(['manuel']);
                      if (mounted) setState(() => _last = i);
                    },
                    child: Text('$i'),
                  ),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
