import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../../features/sync/domain/pairing_window.dart';
import '../../features/sync/domain/sync_protocol.dart';
import '../widgets/settings_card.dart';
import 'data/desktop_sync_store.dart';
import 'wireless_controller.dart';

/// Ayarlar → Cihaz eşleştirme: aç/kapat, adres, eşleşmiş telefon ve tabletler
/// (ad, tür, son eşitleme, kaldır), "Yeni cihaz ekle" ile kod.
class WirelessSection extends ConsumerStatefulWidget {
  const WirelessSection({super.key});

  @override
  ConsumerState<WirelessSection> createState() => _WirelessSectionState();
}

class _WirelessSectionState extends ConsumerState<WirelessSection> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // Kodun kalan süresi saniye saniye görünsün.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(wirelessProvider).pairing != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(wirelessProvider);
    final controller = ref.read(wirelessProvider.notifier);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return SettingsCard(
      icon: Icons.wifi,
      title: 'Cihaz eşleştirme (yerel ağ)',
      children: [
        Text(
          'Telefon ve tablet aynı Wi-Fi\'dayken Koçum\'da Ayarlar → Araçlar → Bilgisayarla eşitle. İnternet ya da bulut '
          'kullanılmaz. En çok ${SyncLimits.maxDevices} cihaz aynı anda bağlı kalır; yeni cihaz eklemek öbürlerini koparmaz. '
          'Telefon ile tablet birbirine doğrudan bağlanmaz: kayıtlar bilgisayar üzerinden herkese ulaşır.',
          style: mutedStyle(context),
        ),
        if (!s.supported) ...[
          const SizedBox(height: 12),
          const Text('Cihaz eşleştirme yalnızca Linux\'ta açılır.'),
        ] else ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: s.enabled,
            onChanged: (v) => unawaited(controller.setEnabled(v)),
            title: Text(s.running ? 'Açık' : 'Kapalı'),
            subtitle: Text(
              s.running
                  ? '${s.computerName ?? 'Bu bilgisayar'} · '
                      '${s.addresses.isEmpty ? 'yerel ağ bağlantısı yok' : s.addresses.map((a) => '$a:${s.port}').join('  ·  ')}'
                  : 'Açınca bu bilgisayar yalnızca yerel ağda dinler.',
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
              label: const Text('Yeni cihaz ekle'),
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
            'Cihaz bilgisayarı bulamazsa: ikisi aynı ağda mı? Güvenlik duvarı açıksa 47321/TCP ve 47322/UDP '
            'izinli olmalı. Veriler ve fotoğraflar uçtan uca şifreli gider (ChaCha20-Poly1305); anahtar ağdan hiç '
            'geçmez, kimse okuyamaz ya da senin yerine gönderemez. Yine de okul ya da kafe gibi ortak Wi-Fi\'da '
            'cihaz adı ve dosya adları (fotoğraf yolu, PDF özeti) görünebilir; evde ya da güvendiğin ağda kullan.',
            style: small,
          ),
        ],
      ],
    );
  }

  Future<void> _confirmForget(PairedDevice device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eşleşme kaldırılsın mı?'),
        content: Text(
          '${device.name} artık bu bilgisayara veri gönderemez. Bilgisayardaki veriler silinmez; '
          'öbür cihazların eşleşmesi bozulmaz. Cihazda da Ayarlar → Araçlar → Bilgisayarla eşitle → '
          'Eşleşmeyi kaldır yap.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaldır')),
        ],
      ),
    );
    if (ok == true) await ref.read(wirelessProvider.notifier).forgetDevice(device.id);
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
          Text('Cihazda bu kodu yaz', style: theme.textTheme.titleSmall),
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
