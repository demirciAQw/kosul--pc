import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/palette.dart';
import '../../../app/widgets/tone_icon.dart';
import '../../../core/utils/formatters.dart';
import '../data/phone_sync_store.dart';
import '../data/sync_client.dart';
import '../domain/network_rules.dart';
import '../domain/sync_protocol.dart';
import '../sync_providers.dart';
import 'send_controller.dart';

/// Araçlar → Bilgisayara gönder: aynı Wi-Fi'daki bilgisayardaki Koçum'a
/// (Linux) eşleşme ve gönderme.
class SendToComputerScreen extends ConsumerWidget {
  const SendToComputerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final computer = ref.watch(pairedComputerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Bilgisayarla eşitle')),
      body: computer.when(
        data: (c) => c == null ? const _PairView() : _SendView(computer: c),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Eşleşme bilgisi okunamadı: $e')),
      ),
    );
  }
}

const _footer = 'Yalnızca aynı ağdaki eşleşmiş tek bilgisayara gider; İnternet ya da bulut kullanılmaz. '
    'Anahtar ağdan hiç geçmez; fotoğraflar ve veriler şifrelenmeden gider, bu yüzden okul ya da kafe gibi '
    'ortak Wi-Fi\'da kullanma.';

// ───────────── Eşleşme ─────────────

class _PairView extends ConsumerStatefulWidget {
  const _PairView();

  @override
  ConsumerState<_PairView> createState() => _PairViewState();
}

class _PairViewState extends ConsumerState<_PairView> {
  bool _searching = false;
  bool _pairing = false;
  List<DiscoveredComputer>? _found;
  String? _error;

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await ref.read(sendControllerProvider.notifier).discover();
      if (!mounted) return;
      setState(() {
        _found = found;
        if (found.isEmpty) {
          _error = 'Bilgisayar bulunamadı. İkisi aynı Wi-Fi\'da mı, bilgisayarda kablosuz alma açık mı? '
              'Bulunamazsa adresi elle yaz (bilgisayarda Ayarlar → Kablosuz alma\'da yazar).';
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeSyncError(e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _manual() async {
    final text = await showDialog<String>(context: context, builder: (_) => const _AddressDialog());
    if (text == null || !mounted) return;
    final address = parseComputerAddress(text, defaultPort: syncDefaultPort);
    if (address == null) {
      setState(() => _error = 'Geçerli bir yerel ağ adresi yaz (ör. 192.168.1.20).');
      return;
    }
    await _pairWith(address.host, address.port);
  }

  Future<void> _pairWith(String host, int port) async {
    final code = await showDialog<String>(context: context, builder: (_) => const _CodeDialog());
    if (code == null || !mounted) return;
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final computer = await ref.read(sendControllerProvider.notifier).pair(host: host, port: port, code: code);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Eşleşti: ${computer.name}')));
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeSyncError(e));
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _searching || _pairing;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bilgisayarla eşleş', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('1. Bilgisayarda Koçum → Ayarlar → Kablosuz alma\'yı aç.\n'
                    '2. "Telefon eşleştir"e bas; ekranda 6 haneli kod çıkar.\n'
                    '3. Burada bilgisayarı seç ve kodu yaz.'),
                const SizedBox(height: 8),
                Text(
                  'Telefon yalnızca bir bilgisayarla, bilgisayar yalnızca bir telefonla eşleşir. '
                  'Yalnızca Linux\'taki Koçum kabul edilir.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: busy ? null : () => unawaited(_search()),
          icon: const Icon(Icons.search),
          label: Text(_searching ? 'Aranıyor…' : 'Bilgisayarı ara'),
        ),
        TextButton(
          onPressed: busy ? null : () => unawaited(_manual()),
          child: const Text('Adresi elle yaz'),
        ),
        if (busy) const LinearProgressIndicator(),
        for (final c in _found ?? const <DiscoveredComputer>[])
          Card(
            child: ListTile(
              leading: const ToneIcon(Icons.computer, color: KocumColors.blue),
              title: Text(c.name),
              subtitle: Text(c.address),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => unawaited(_pairWith(c.host, c.port)),
            ),
          ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(error, style: TextStyle(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 16),
        Text(_footer, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Bilgisayarın adresi'),
        content: TextField(
          controller: _text,
          autofocus: true,
          keyboardType: TextInputType.url,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]'))],
          decoration: const InputDecoration(hintText: '192.168.1.20', helperText: 'Bilgisayarda Ayarlar → Kablosuz alma'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('Devam')),
        ],
      );
}

class _CodeDialog extends StatefulWidget {
  const _CodeDialog();

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Eşleştirme kodu'),
        content: TextField(
          controller: _text,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 28, letterSpacing: 6),
          decoration: const InputDecoration(hintText: '000000', helperText: 'Bilgisayar ekranındaki 6 haneli kod'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('Eşleş')),
        ],
      );
}

// ───────────── Gönderme ─────────────

class _SendView extends ConsumerWidget {
  const _SendView({required this.computer});

  final PairedComputer computer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final send = ref.watch(sendControllerProvider);
    final controller = ref.read(sendControllerProvider.notifier);
    final last = computer.lastSentAt;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: ListTile(
            leading: const ToneIcon(Icons.computer, color: KocumColors.blue),
            title: Text(computer.name),
            subtitle: Text(
              '${computer.address}\nSon gönderim: ${last == null ? 'henüz yok' : formatShortDate(last)}',
            ),
            isThreeLine: true,
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: send.busy ? null : () => unawaited(controller.send()),
          icon: const Icon(Icons.send),
          label: const Text('Eşitle'),
        ),
        const SizedBox(height: 12),
        if (send.busy) ...[
          LinearProgressIndicator(value: send.total > 0 ? send.done / send.total : null),
          const SizedBox(height: 8),
        ],
        if (send.message case final message?)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (send.stage == SendStage.done) const Icon(Icons.check_circle, color: KocumColors.correct),
              if (send.stage == SendStage.failed) Icon(Icons.error_outline, color: theme.colorScheme.error),
              if (!send.busy) const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ],
          ),
        const SizedBox(height: 16),
        Text(
          'İlk eşitlemede tam yedek bilgisayarla birleşir (telefondaki kayıtlar kazanır). Sonrasında yalnızca '
          'değişiklikler iki yöne gider; fotoğraflar da. Aynı satır iki yerde değişirse yeni olan kazanır, '
          'kaybeden sürüm Çakışmalar\'da kalır. Hiçbir şey sessizce silinmez. Bağlantı koparsa yeniden eşitle.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(_footer, style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: send.busy ? null : () => unawaited(_confirmUnpair(context, ref)),
            icon: const Icon(Icons.link_off),
            label: const Text('Eşleşmeyi kaldır'),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmUnpair(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eşleşme kaldırılsın mı?'),
        content: Text(
          'Telefon artık ${computer.name} adlı bilgisayara gönderemez. Telefondaki ve bilgisayardaki veriler '
          'silinmez. Bilgisayarda da Ayarlar → Kablosuz alma → Eşleşmeyi kaldır yap.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaldır')),
        ],
      ),
    );
    if (ok == true) await ref.read(sendControllerProvider.notifier).unpair();
  }
}
