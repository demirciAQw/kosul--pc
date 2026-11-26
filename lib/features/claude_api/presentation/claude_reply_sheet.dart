import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../anlik/anlik_providers.dart';
import '../claude_providers.dart';
import '../data/api_key_store.dart';
import '../domain/claude_error.dart';

/// Notta `((etiket))` ve `@kişi` ayrıştırılır; Claude yanıtı bunları yanlışlıkla
/// içerebilir. Metin bozulmadan etkisiz kılınır (görünmez genişlik yok karakteri).
String neutralizeMentions(String s) => s.replaceAll('((', '(​(').replaceAll('@', '@​');

String claudeNoteBody(String reply, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${now.year}-${two(now.month)}-${two(now.day)}';
  return neutralizeMentions('Claude yanıtı – $date\n\n${reply.trim()}');
}

/// Gönderim onayı: gönderilecek metnin AYNISI gösterilir. true = gönder.
Future<bool> confirmClaudeSend(BuildContext context, String text) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      key: const Key('claude-confirm'),
      title: const Text('Claude\'a gönderilsin mi?'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Bu metin Anthropic\'e gönderilecek; sağlık verisi yalnız rapor ayarı açıksa dahil.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(c).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(text, key: const Key('claude-confirm-text'), style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
        FilledButton(key: const Key('claude-confirm-send'), onPressed: () => Navigator.pop(c, true), child: const Text('Gönder')),
      ],
    ),
  );
  return ok == true;
}

/// Onay + akışlı yanıt. Anahtar yoksa kullanıcıyı Ayarlar'a yönlendiren ileti.
Future<void> sendReportToClaude(BuildContext context, WidgetRef ref, String prompt) async {
  final messenger = ScaffoldMessenger.of(context);
  final ApiKeyStore store = ref.read(apiKeyStoreProvider);
  try {
    if (!await store.exists()) {
      messenger.showSnackBar(const SnackBar(content: Text('Önce Ayarlar > Claude API\'den anahtarı kaydet.')));
      return;
    }
  } on ApiKeyStoreException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  if (!context.mounted) return;
  if (!await confirmClaudeSend(context, prompt)) return;
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ClaudeReplySheet(prompt: prompt),
  );
}

class ClaudeReplySheet extends ConsumerStatefulWidget {
  const ClaudeReplySheet({super.key, required this.prompt});
  final String prompt;

  @override
  ConsumerState<ClaudeReplySheet> createState() => _ClaudeReplySheetState();
}

class _ClaudeReplySheetState extends ConsumerState<ClaudeReplySheet> {
  final _text = StringBuffer();
  bool _running = false;
  bool _done = false;
  bool _saved = false;
  String? _notice;
  ClaudeApiException? _error;
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _run++; // gelen akış yok sayılır
    super.dispose();
  }

  Future<void> _start() async {
    final run = ++_run;
    setState(() {
      _running = true;
      _done = false;
      _error = null;
      _notice = null;
      _text.clear();
    });
    try {
      final key = await ref.read(apiKeyStoreProvider).read();
      if (key == null) {
        if (mounted && run == _run) {
          setState(() => _error = const ClaudeApiException(ClaudeErrorKind.invalidKey));
        }
        return;
      }
      final reply = await ref.read(claudeClientProvider).ask(key, widget.prompt, onText: (d) {
        if (!mounted || run != _run) return;
        setState(() => _text.write(d));
      });
      if (!mounted || run != _run) return;
      setState(() {
        _done = true;
        if (reply.refused) {
          _notice = 'Claude bu isteği yanıtlamadı${reply.stopCategory == null ? '' : ' (${reply.stopCategory})'}.';
        } else if (reply.truncated) {
          _notice = 'Yanıt kesildi (en çok uzunluğa ulaşıldı).';
        }
      });
    } on ClaudeApiException catch (e) {
      if (mounted && run == _run) setState(() => _error = e);
    } on ApiKeyStoreException catch (e) {
      if (mounted && run == _run) setState(() => _notice = e.message);
    } finally {
      if (mounted && run == _run) setState(() => _running = false);
    }
  }

  Future<void> _copy() async {
    final m = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _text.toString()));
    m.showSnackBar(const SnackBar(content: Text('Yanıt kopyalandı.')));
  }

  Future<void> _saveNote() async {
    final m = ScaffoldMessenger.of(context);
    try {
      await ref.read(saveAnlikProvider)(body: claudeNoteBody(_text.toString(), DateTime.now()));
      if (mounted) setState(() => _saved = true);
      m.showSnackBar(const SnackBar(content: Text('Not olarak kaydedildi.')));
    } on Exception {
      m.showSnackBar(const SnackBar(content: Text('Not kaydedilemedi.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = _text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('Claude yanıtı', style: theme.textTheme.titleLarge)),
            if (_running) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: hasText
                  ? SelectableText(_text.toString(), key: const Key('claude-reply-text'))
                  : Text(_running ? 'Claude yanıtlıyor…' : '', style: theme.textTheme.bodySmall),
            ),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_notice!, key: const Key('claude-reply-notice'), style: TextStyle(color: theme.colorScheme.tertiary)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!.message, key: const Key('claude-reply-error'), style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (_error?.retryable ?? false)
              FilledButton.icon(
                key: const Key('claude-retry'),
                onPressed: _running ? null : _start,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Yeniden dene'),
              ),
            OutlinedButton.icon(
              key: const Key('claude-copy'),
              onPressed: hasText ? _copy : null,
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Kopyala'),
            ),
            OutlinedButton.icon(
              key: const Key('claude-save-note'),
              onPressed: hasText && _done && !_saved ? _saveNote : null,
              icon: const Icon(Icons.note_add_outlined),
              label: Text(_saved ? 'Kaydedildi' : 'Not olarak kaydet'),
            ),
          ]),
        ],
      ),
    );
  }
}
