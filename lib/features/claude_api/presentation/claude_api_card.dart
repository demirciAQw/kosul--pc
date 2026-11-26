import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../claude_providers.dart';
import '../data/api_key_store.dart';
import '../domain/claude_error.dart';
import '../domain/claude_request.dart';

/// Ayarlar: "Claude API" kartı. Anahtar bir kez girilir; sonra YALNIZCA
/// `sk-ant-…` + son 4 hane görünür. Anahtar veritabanına, yedeğe, eşitlemeye girmez.
class ClaudeApiCard extends ConsumerStatefulWidget {
  const ClaudeApiCard({super.key});

  @override
  ConsumerState<ClaudeApiCard> createState() => _ClaudeApiCardState();
}

class _ClaudeApiCardState extends ConsumerState<ClaudeApiCard> {
  final _field = TextEditingController();
  bool _busy = false;
  String? _msg;

  @override
  void dispose() {
    _field.clear();
    _field.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) setState(() => _field.text = d!.text!.trim());
  }

  Future<void> _save() async {
    final key = parseApiKey(_field.text);
    if (key == null) {
      setState(() => _msg = 'Bu bir Claude API anahtarına benzemiyor (sk-ant-… ile başlamalı).');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiKeyStoreProvider).save(key);
      _field.clear(); // alandan hemen silinir
      ref.invalidate(claudeKeyMaskProvider);
      _msg = 'Anahtar bu cihaza güvenli kaydedildi.';
    } on ApiKeyStoreException catch (e) {
      _msg = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final key = await ref.read(apiKeyStoreProvider).read();
      if (key == null) {
        _msg = 'Önce anahtarı kaydet.';
      } else {
        await ref.read(claudeClientProvider).testConnection(key);
        _msg = 'Bağlantı tamam: anahtar çalışıyor.';
      }
    } on ClaudeApiException catch (e) {
      _msg = e.message;
    } on ApiKeyStoreException catch (e) {
      _msg = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Anahtarı sil'),
        content: const Text('Kayıtlı Claude API anahtarı bu cihazdan silinir. Anthropic hesabındaki anahtar etkilenmez.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiKeyStoreProvider).delete();
      ref.invalidate(claudeKeyMaskProvider);
      _msg = 'Anahtar silindi.';
    } on ApiKeyStoreException catch (e) {
      _msg = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mask = ref.watch(claudeKeyMaskProvider);
    final saved = mask.value;
    return Card(
      key: const Key('claude-api-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Claude API', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Raporu doğrudan Claude\'a gönderip yanıtı burada görmek için. Anahtar yalnızca bu cihazda, '
              'şifreli saklanır; veritabanına, yedeğe ve eşitlemeye girmez.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (mask.hasError)
              Text('${mask.error}', key: const Key('claude-key-error'), style: TextStyle(color: theme.colorScheme.error))
            else if (saved != null) ...[
              Text('Kayıtlı anahtar: $saved', key: const Key('claude-key-mask')),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonal(
                  key: const Key('claude-test'),
                  onPressed: _busy ? null : _test,
                  child: const Text('Bağlantıyı dene'),
                ),
                OutlinedButton(
                  key: const Key('claude-delete'),
                  onPressed: _busy ? null : _delete,
                  child: const Text('Anahtarı sil'),
                ),
              ]),
            ] else ...[
              TextField(
                key: const Key('claude-key-field'),
                controller: _field,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: 'API anahtarı (sk-ant-…)',
                  suffixIcon: IconButton(
                    tooltip: 'Yapıştır',
                    icon: const Icon(Icons.paste_rounded),
                    onPressed: _busy ? null : _paste,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(key: const Key('claude-save'), onPressed: _busy ? null : _save, child: const Text('Kaydet')),
            ],
            if (_msg != null) ...[
              const SizedBox(height: 8),
              Text(_msg!, key: const Key('claude-msg'), style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Text(
              'Claude bir isteği reddederse sunucu otomatik olarak başka bir modelle dener.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
