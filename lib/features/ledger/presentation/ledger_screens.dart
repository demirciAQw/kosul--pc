import 'package:flutter/material.dart';

import 'ledger_views.dart';

class ClaudeChangesScreen extends StatelessWidget {
  const ClaudeChangesScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Claude\'un değişiklikleri')),
        body: const ClaudeChangesView(),
      );
}

class ConflictsScreen extends StatelessWidget {
  const ConflictsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Çakışmalar')),
        body: const ConflictsView(),
      );
}
