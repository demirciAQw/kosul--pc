import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/palette.dart';
import '../../../app/tablet.dart' show isTabletContext;
import '../../../app/widgets/tone_icon.dart';
import '../../../core/utils/formatters.dart';
import '../data/phone_sync_store.dart';
import '../data/sync_client.dart';
import '../domain/network_rules.dart';
import '../domain/sync_protocol.dart';
import '../sync_providers.dart';
import 'receive_screen.dart';
import 'send_controller.dart';

/// Ayarlar → Cihazlarla eşitle (v9.23): bu cihazın eşleşmeleri. Her cihaz hem İSTEMCİ
/// (başka cihazın kodunu girer, ona eşitler) hem ALICI (kendi ekranında kod gösterir) olabilir;
/// bilgisayar, telefon ve tablet arasında ayrı ayrı eşleşilir (en çok 4 eş).
class SendToComputerScreen extends ConsumerWidget {
  const SendToComputerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(pairedPeersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cihazlarla eşitle')),
      body: peers.when(
        data: (list) => _PeersView(peers: list),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Eşleşme bilgisi okunamadı: $e')),
      ),
    );
  }
}

const _footer = 'Yalnızca aynı ağdaki eşleşmiş cihazlara gider; İnternet ya da bulut kullanılmaz. '
    'Anahtar ağdan hiç geçmez; fotoğraflar ve veriler şifrelenmeden gider, bu yüzden okul ya da kafe gibi '
    'ortak Wi-Fi\'da kullanma.';

String _kindLabel(String kind) => switch (kind) {
      deviceKindTablet => 'tablet',
      deviceKindPhone => 'telefon',
      _ => 'bilgisayar',
    };

IconData _kindIcon(String kind) => switch (kind) {
      deviceKindTablet => Icons.tablet_android,
      deviceKindPhone => Icons.phone_android,
      _ => Icons.computer,
    };

// ───────────── Yeni eşleşme: başka cihazın kodunu gir ─────────────

class _PairSection extends ConsumerStatefulWidget {
  const _PairSection();

  @override
  ConsumerState<_PairSection> createState() => _PairSectionState();
}

class _PairSectionState extends ConsumerState<_PairSection> {
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
          _error = 'Cihaz bulunamadı. İkisi aynı Wi-Fi\'da mı, öbür cihazda kod ekranı açık mı? '
              'Bulunamazsa adresi elle yaz (öbür cihazın kod ekranında yazar).';
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
    final isTablet = isTabletContext(context);
    final suggested = await ref.read(deviceNameProvider.future);
    if (!mounted) return;
    final entry = await showDialog<({String code, String name})>(
      context: context,
      builder: (_) => _CodeDialog(isTablet: isTablet, suggestedName: suggested),
    );
    if (entry == null || !mounted) return;
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final peer = await ref
          .read(sendControllerProvider.notifier)
          .pair(host: host, port: port, code: entry.code, isTablet: isTablet, deviceName: entry.name);
      ref.invalidate(deviceNameProvider);
      if (!mounted) return;
      setState(() => _found = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Eşleşti: ${peer.name}')));
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : () => unawaited(_search()),
              icon: const Icon(Icons.search),
              label: Text(_searching ? 'Aranıyor…' : 'Cihazı ara'),
            ),
            TextButton(
              onPressed: busy ? null : () => unawaited(_manual()),
              child: const Text('Adresi elle yaz'),
            ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        for (final c in _found ?? const <DiscoveredComputer>[])
          Card(
            child: ListTile(
              leading: ToneIcon(c.platform == 'android' ? Icons.phone_android : Icons.computer, color: KocumColors.blue),
              title: Text(c.name),
              subtitle: Text('${c.address} · ${c.platform == 'android' ? 'Android cihaz' : 'bilgisayar'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => unawaited(_pairWith(c.host, c.port)),
            ),
          ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(error, style: TextStyle(color: theme.colorScheme.error)),
          ),
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
        title: const Text('Öbür cihazın adresi'),
        content: TextField(
          controller: _text,
          autofocus: true,
          keyboardType: TextInputType.url,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]'))],
          decoration: const InputDecoration(hintText: '192.168.1.20', helperText: 'Öbür cihazın ekranında yazar'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('Devam')),
        ],
      );
}

class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.isTablet, this.suggestedName});

  final bool isTablet;
  final String? suggestedName;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _text = TextEditingController();
  late final _name = TextEditingController(text: widget.suggestedName ?? (widget.isTablet ? 'Tabletim' : 'Telefonum'));

  @override
  void dispose() {
    _text.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, (code: _text.text, name: _name.text.trim().isEmpty ? 'Adsız cihaz' : _name.text.trim()));

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Eşleştirme kodu'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 28, letterSpacing: 6),
              decoration: const InputDecoration(hintText: '000000', helperText: 'Öbür cihazın ekranındaki 6 haneli kod'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              maxLength: SyncLimits.nameLength,
              decoration: InputDecoration(
                labelText: widget.isTablet ? 'Bu tabletin adı' : 'Bu telefonun adı',
                helperText: 'Öbür cihazdaki listede böyle görünür',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
          FilledButton(onPressed: _submit, child: const Text('Eşleş')),
        ],
      );
}

// ───────────── Eşleşmeler ─────────────

class _PeersView extends ConsumerWidget {
  const _PeersView({required this.peers});

  final List<PairedComputer> peers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final send = ref.watch(sendControllerProvider);
    final controller = ref.read(sendControllerProvider.notifier);
    final full = peers.length >= SyncLimits.maxPeers;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text('Eşleşmeler', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Bilgisayar, telefon ve tablet arasında ayrı ayrı eşleşebilirsin: her cihaz hem başkasının kodunu girip ona '
          'eşitler, hem kendi ekranında kod gösterip alıcı olur (Android alıcı yalnızca bu ekran açıkken çalışır). '
          'Bir değişiklik üçgenin hangi yolundan gelirse gelsin bir kez uygulanır.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (peers.isEmpty) const Text('Henüz eşleşme yok.'),
        for (final peer in peers) _PeerCard(peer: peer, busy: send.busy),
        if (peers.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(
              onPressed: send.busy ? null : () => unawaited(controller.send()),
              icon: const Icon(Icons.sync),
              label: const Text('Hepsini eşitle'),
            ),
          ),
        const SizedBox(height: 16),
        Text('Yeni eşleşme', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (full)
          Text('${SyncLimits.maxPeers} eşleşme dolu. Yeni için önce birini kaldır.', style: theme.textTheme.bodySmall)
        else ...[
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReceiveScreen())),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Bu cihazda kod göster'),
          ),
          const SizedBox(height: 4),
          Text(
            'Öbür cihaz (telefon, tablet ya da bilgisayar) bu cihaza bağlanır. Kodu öbür cihazda "başka cihazın '
            'kodunu gir" ile yaz.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Text('Başka cihazın kodunu gir', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Öbür cihazda (bilgisayarda Ayarlar → Cihaz eşleştirme; Android\'de "Bu cihazda kod göster") kodu aç, '
            'burada cihazı seç, bir ad ver ve 6 haneli kodu yaz.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          const _PairSection(),
        ],
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: ref.watch(sendPdfsProvider).value ?? false,
          onChanged: send.busy ? null : (v) => unawaited(controller.setSendPdfs(v)),
          title: const Text('PDF dosyalarını da gönder'),
          subtitle: const Text(
            'Kapalıyken yalnızca çizgiler, kutular ve notlar gider; PDF\'in kendisi gitmez '
            '(karşıda sayfa görünmez). Dosyalar büyük olabilir (en çok 300 MB); aynı dosya '
            'karşıda varsa yeniden gönderilmez. Bütün eşler için geçerlidir.',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: ref.watch(pullPdfsProvider).value ?? false,
          onChanged: send.busy ? null : (v) => unawaited(controller.setPullPdfs(v)),
          title: const Text('PDF\'leri eşten al'),
          subtitle: const Text(
            'Açıkken karşıda olup bu cihazda dosyası olmayan PDF\'ler eşitlemede iner '
            '(örneğin tabletten yüklediğin kitap telefona). Kapalıyken yalnızca kayıtlar gelir. '
            'Dosya büyük olabilir (en çok 300 MB); kopan indirme kaldığı yerden sürer.',
          ),
        ),
        const SizedBox(height: 12),
        if (send.busy) ...[
          LinearProgressIndicator(value: send.total > 0 ? send.done / send.total : null),
          const SizedBox(height: 8),
          if (send.stage == SendStage.pdfs)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: controller.cancelPdf,
                icon: const Icon(Icons.close),
                label: const Text('PDF aktarımını iptal et'),
              ),
            ),
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
          'Yeni eşleşmede karşıdaki bütün kayıtlar bu cihaza gelir (yalnızca eksik olanlar eklenir). '
          'Bilgisayara ilk eşitlemede ayrıca tam yedek birleşir (bu cihazdaki kayıtlar kazanır); Android alıcıya bunun '
          'yerine bu cihazın kayıtları da verilir (yalnızca onda eksik olanlar). Sonrasında yalnızca değişiklikler iki '
          'yöne gider; fotoğraflar da. Aynı satır iki yerde değişirse yeni olan kazanır, kaybeden sürüm '
          'Çakışmalar\'da kalır. Hiçbir şey sessizce silinmez. Bağlantı koparsa yeniden eşitle.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(_footer, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _PeerCard extends ConsumerWidget {
  const _PeerCard({required this.peer, required this.busy});

  final PairedComputer peer;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(sendControllerProvider.notifier);
    final last = peer.lastSentAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: ToneIcon(_kindIcon(peer.kind), color: KocumColors.blue),
              title: Text('${peer.name} [${_kindLabel(peer.kind)}]'),
              subtitle: Text('${peer.address}\nSon eşitleme: ${last == null ? 'henüz yok' : formatShortDate(last)}'),
              isThreeLine: true,
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : () => unawaited(controller.send(peerId: peer.id)),
                  icon: const Icon(Icons.send),
                  label: const Text('Şimdi eşitle'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : () => unawaited(_confirmFullState(context, ref)),
                  icon: const Icon(Icons.download),
                  label: const Text('Her şeyi yeniden al'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : () => unawaited(_confirmUnpair(context, ref)),
                  icon: const Icon(Icons.link_off),
                  label: const Text('Kaldır'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmFullState(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Her şey yeniden alınsın mı?'),
        content: Text(
          'Sonraki eşitlemede ${peer.name} cihazındaki bütün kayıtlar gelir; yalnızca bu cihazda EKSİK olanlar eklenir. '
          'Var olan kayıtlara dokunulmaz, bu cihazda sildiğin kayıtlar geri gelmez. Büyük veride biraz sürebilir.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tamam')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(sendControllerProvider.notifier).requestFullState(peer.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sonraki eşitlemede alınacak. "Şimdi eşitle"ye bas.')));
    }
  }

  Future<void> _confirmUnpair(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eşleşme kaldırılsın mı?'),
        content: Text(
          'Bu cihaz artık ${peer.name} ile eşitlenemez. Cihazlardaki veriler silinmez; öbür eşleşmeler etkilenmez. '
          '${peer.name} tarafında da bu cihazı kaldır.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaldır')),
        ],
      ),
    );
    if (ok == true) await ref.read(sendControllerProvider.notifier).unpair(peer.id);
  }
}
