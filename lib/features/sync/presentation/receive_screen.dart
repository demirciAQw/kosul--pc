import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/tablet.dart' show isTabletContext;
import '../../../core/utils/formatters.dart';
import '../data/server_sync_store.dart';
import '../domain/pairing_window.dart';
import '../domain/sync_protocol.dart';
import 'receive_controller.dart';

/// Ayarlar → Cihazlarla eşitle → "Bu cihazda kod göster" (v9.23): bu Android cihaz ALICI olur.
/// Öbür telefon/tablet/bilgisayar buraya bağlanıp eşitler. Arka plan servisi yoktur: alıcı
/// yalnızca uygulama ön plandayken (ekran açık) çalışır.
class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key});

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends ConsumerState<ReceiveScreen> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // Kodun kalan süresi saniye saniye görünsün.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(receiveControllerProvider).pairing != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(receiveControllerProvider);
    final controller = ref.read(receiveControllerProvider.notifier);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Scaffold(
      appBar: AppBar(title: const Text('Bu cihazda kod göster')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Bu cihaz alıcı olur: öbür cihaz (telefon, tablet ya da bilgisayar) aynı Wi-Fi\'dayken bu cihaza bağlanıp '
            'kayıtlarını eşitler. İnternet ya da bulut kullanılmaz. En çok ${SyncLimits.maxDevices} cihaz aynı anda bağlı '
            'kalır. Alıcı yalnızca bu uygulama ekranda açıkken çalışır; uygulamayı kapatınca ya da arka plana atınca '
            'durur (eşleşmeler kalır).',
            style: small,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: s.enabled,
            onChanged: (v) => unawaited(controller.setEnabled(v, isTablet: isTabletContext(context))),
            title: Text(s.running ? 'Alıcı açık' : (s.enabled ? 'Beklemede (uygulama arka planda)' : 'Alıcı kapalı')),
            subtitle: Text(
              s.running
                  ? '${s.name ?? 'Bu cihaz'} · '
                      '${s.addresses.isEmpty ? 'yerel ağ bağlantısı yok' : s.addresses.map((a) => '$a:${s.port}').join('  ·  ')}'
                  : 'Açınca bu cihaz yalnızca yerel ağda dinler.',
            ),
          ),
          const SizedBox(height: 8),
          for (final device in s.devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(device.isTablet ? Icons.tablet_android : Icons.phone_android),
              title: Text('${device.name} [${device.isTablet ? 'tablet' : 'telefon'}]'),
              subtitle: Text(
                'Eşleşme: ${formatShortDate(device.pairedAt)} · '
                'Son eşitleme: ${device.lastSyncAt == null ? 'henüz yok' : formatShortDate(device.lastSyncAt!)}',
              ),
              trailing: OutlinedButton(
                onPressed: () => unawaited(_confirmForget(device)),
                child: const Text('Kaldır'),
              ),
            ),
          if (s.pairing case final code?)
            _CodeBox(code: code, onCancel: () => unawaited(controller.cancelPairing()))
          else if (s.devices.length >= SyncLimits.maxDevices)
            Text('${SyncLimits.maxDevices} cihaz eşleşmiş. Yeni cihaz için önce birini kaldır.', style: small)
          else
            FilledButton.icon(
              onPressed: s.running ? () => unawaited(controller.startPairing()) : null,
              icon: const Icon(Icons.add_link),
              label: const Text('Yeni cihaz ekle (kod göster)'),
            ),
          if (s.error case final error?) ...[
            const SizedBox(height: 8),
            Text(error, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          ],
          if (s.message case final message?) ...[
            const SizedBox(height: 8),
            Text(message, style: small),
          ],
          const SizedBox(height: 12),
          Text(
            'Öbür cihaz bulamazsa: ikisi aynı ağda mı? Yukarıdaki adresi öbür cihazda "Adresi elle yaz" ile gir. '
            'Okul ya da kafe gibi ortak Wi-Fi\'da kullanma: anahtar ağdan hiç geçmez ve kimse senin yerine gönderemez, '
            'ama fotoğraflar ve veriler şifrelenmeden gider. Bu cihaz tam yedek (ZIP) almaz; kayıtlar değişiklik defteri '
            've tam durumla taşınır.',
            style: small,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmForget(PairedDevice device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eşleşme kaldırılsın mı?'),
        content: Text(
          '${device.name} artık bu cihaza veri gönderemez. Bu cihazdaki veriler silinmez; öbür eşleşmeler bozulmaz. '
          'Öbür cihazda da bu eşleşmeyi kaldır.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaldır')),
        ],
      ),
    );
    if (ok == true) await ref.read(receiveControllerProvider.notifier).forgetDevice(device.id);
  }
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.code, required this.onCancel});

  final PairingCode code;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = code.expiresAt.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : left.inSeconds;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Öbür cihazda bu kodu yaz', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SelectableText(
            '${code.code.substring(0, 3)} ${code.code.substring(3)}',
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 4,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} kaldı · '
            '${code.attemptsLeft} deneme hakkı · tek kullanımlık',
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onCancel, child: const Text('Vazgeç')),
        ],
      ),
    );
  }
}
