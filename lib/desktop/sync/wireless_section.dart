import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../../features/sync/domain/pairing_window.dart';
import '../widgets/settings_card.dart';
import 'data/desktop_sync_store.dart';
import 'wireless_controller.dart';

/// Ayarlar → Kablosuz alma: aç/kapat, adres, eşleştirme kodu, eşleşmiş telefon.
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
      title: 'Telefon eşleştirme (yerel ağ)',
      children: [
        Text(
          'Telefon aynı Wi-Fi\'dayken Koçum\'da Araçlar → Bilgisayarla eşitle. İnternet ya da bulut kullanılmaz; '
          'yalnızca eşleşmiş tek telefon kabul edilir ve yalnızca bilgisayarda olmayan fotoğraflar gelir.',
          style: mutedStyle(context),
        ),
        if (!s.supported) ...[
          const SizedBox(height: 12),
          const Text('Telefon eşleştirme yalnızca Linux\'ta açılır.'),
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
          if (s.phone case final phone?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phone_android),
              title: Text(phone.name),
              subtitle: Text('Eşleşme: ${formatShortDate(phone.pairedAt)}'),
              trailing: OutlinedButton(
                onPressed: () => unawaited(_confirmForget(phone)),
                child: const Text('Eşleşmeyi kaldır'),
              ),
            )
          else if (s.pairing case final code?)
            _CodeBox(code: code, onCancel: () => unawaited(controller.cancelPairing()))
          else
            FilledButton.icon(
              onPressed: s.running ? () => unawaited(controller.startPairing()) : null,
              icon: const Icon(Icons.link),
              label: const Text('Telefon eşleştir'),
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
            'Telefon bilgisayarı bulamazsa: ikisi aynı ağda mı? Güvenlik duvarı açıksa 47321/TCP ve 47322/UDP '
            'izinli olmalı. Okul ya da kafe gibi ortak Wi-Fi\'da kullanma: anahtar ağdan hiç geçmez ve kimse senin '
            'yerine gönderemez, ama fotoğraflar ve veriler şifrelenmeden gider.',
            style: small,
          ),
        ],
      ],
    );
  }

  Future<void> _confirmForget(PairedPhone phone) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eşleşme kaldırılsın mı?'),
        content: Text(
          '${phone.name} artık bu bilgisayara veri gönderemez. Bilgisayardaki veriler silinmez. '
          'Telefonda da Bilgisayarla eşitle → Eşleşmeyi kaldır yap.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaldır')),
        ],
      ),
    );
    if (ok == true) await ref.read(wirelessProvider.notifier).forgetPhone();
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
          Text('Telefonda bu kodu yaz', style: theme.textTheme.titleSmall),
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
