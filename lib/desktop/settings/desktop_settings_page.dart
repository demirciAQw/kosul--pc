import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/palette.dart';
import '../../core/utils/formatters.dart';
import '../../features/settings/settings_providers.dart';
import '../desktop_providers.dart';
import '../import/domain/import_models.dart';
import '../import/import_providers.dart';
import '../import/presentation/auto_import.dart';
import '../import/presentation/import_flow.dart';
import '../sync/wireless_section.dart';
import '../widgets/desktop_page.dart';
import '../widgets/settings_card.dart';

class DesktopSettingsPage extends ConsumerWidget {
  const DesktopSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DesktopPage(
      title: 'Ayarlar',
      subtitle: 'Telefondan veri alma, kablosuz alma, izlenen klasör, koç klasörü, görünüm',
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const _ImportSection(),
              const WirelessSection(),
              const _WatchedFolderSection(),
              const _CoachSection(),
              const _TombstoneSection(),
              const _AppearanceSection(),
              const _HistorySection(),
              const SizedBox(height: 8),
              Text(
                'Bilgisayardaki veriler: ${ref.watch(desktopDataDirProvider).path}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportSection extends ConsumerWidget {
  const _ImportSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(importBusyProvider);
    final last = ref.watch(importHistoryProvider).value?.firstOrNull;
    final exported = last?.exportedAt;
    return SettingsCard(
      icon: Icons.phone_android,
      title: 'Telefondan veri al',
      children: [
        Text(
          'Telefonda Araçlar → Tüm veriyi dışa aktar ile aldığın ZIP\'i seç. Açılmış bir yedek klasörü de olur. '
          'Var olan kayıtlar güncellenir, yeniler eklenir; hiçbir şey sessizce silinmez.',
          style: mutedStyle(context),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy == null ? () => unawaited(pickAndImport(context, ref, folder: false)) : null,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('ZIP seç'),
            ),
            OutlinedButton.icon(
              onPressed: busy == null ? () => unawaited(pickAndImport(context, ref, folder: true)) : null,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Klasör seç'),
            ),
          ],
        ),
        if (busy != null) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(busy),
        ],
        if (last != null) ...[
          const SizedBox(height: 12),
          Text(
            'Son içe aktarma: ${formatShortDate(last.at)} · ${last.source}'
            '${exported == null ? '' : ' · telefonda ${formatShortDate(exported)}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _WatchedFolderSection extends ConsumerWidget {
  const _WatchedFolderSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auto = ref.watch(autoImportProvider);
    final folder = auto.folder;
    return SettingsCard(
      icon: Icons.sync,
      title: 'İzlenen klasör',
      children: [
        Text(
          'Syncthing, KDE Connect ya da USB ile bu klasöre gelen yeni yedek ZIP\'i, yazılması bitince '
          'kendiliğinden içe aktarılır. Son içe aktarılandan eski yedekler alınmaz.',
          style: mutedStyle(context),
        ),
        const SizedBox(height: 10),
        _PathRow(
          path: folder,
          ok: auto.watching,
          onPick: () async {
            final path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'İzlenecek klasörü seç');
            if (path != null) await ref.read(autoImportProvider.notifier).setFolder(path);
          },
          onClear: folder == null ? null : () => unawaited(ref.read(autoImportProvider.notifier).setFolder(null)),
        ),
        if (auto.message != null && folder != null) ...[
          const SizedBox(height: 6),
          Text(auto.message!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _CoachSection extends ConsumerWidget {
  const _CoachSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = ref.watch(coachFolderProvider).value;
    final state = ref.read(importServiceProvider).state;
    return SettingsCard(
      icon: Icons.psychology_alt_outlined,
      title: 'Koç klasörü (ör. Obsidian kasası)',
      children: [
        Text(
          'Her içe aktarmadan sonra güncel yedek fotoğrafsız olarak bu klasörde Koçum/kocum_yedek.json '
          'adıyla yazılır.',
          style: mutedStyle(context),
        ),
        const SizedBox(height: 10),
        _PathRow(
          path: folder,
          ok: folder != null,
          onPick: () async {
            final path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Koç klasörünü seç');
            if (path == null) return;
            await state.setCoachFolder(path);
            ref.invalidate(coachFolderProvider);
          },
          onClear: folder == null
              ? null
              : () async {
                  await state.setCoachFolder(null);
                  ref.invalidate(coachFolderProvider);
                },
        ),
      ],
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.path, required this.ok, required this.onPick, required this.onClear});

  final String? path;
  final bool ok;
  final Future<void> Function() onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          path == null ? Icons.folder_off_outlined : (ok ? Icons.check_circle : Icons.warning_amber),
          size: 20,
          color: path == null ? theme.colorScheme.outline : (ok ? KocumColors.correct : KocumColors.amber),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(path ?? 'Seçilmedi', style: theme.textTheme.bodyMedium),
        ),
        TextButton(onPressed: () => unawaited(onPick()), child: Text(path == null ? 'Klasör seç' : 'Değiştir')),
        if (onClear != null) TextButton(onPressed: onClear, child: const Text('Kaldır')),
      ],
    );
  }
}

class _TombstoneSection extends ConsumerWidget {
  const _TombstoneSection();

  static const _shown = 30;

  Future<void> _delete(BuildContext context, WidgetRef ref, List<TombstoneView> items) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(items.length == 1 ? 'Bu kayıt silinsin mi?' : '${items.length} kayıt silinsin mi?'),
        content: Text(
          '${items.length == 1 ? items.single.label : tableLabel(items.first.tombstone.table)}\n\n'
          'Bilgisayardan kalıcı olarak silinir; bağlı kayıtlar da gider (ör. kitapla birlikte testleri). '
          'Telefon etkilenmez.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(importServiceProvider).deleteTombstoned([for (final v in items) v.tombstone]);
    ref.invalidate(tombstonesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tombstonesProvider);
    final all = async.value ?? const <TombstoneView>[];
    final groups = <String, List<TombstoneView>>{};
    for (final v in all) {
      (groups[v.tombstone.table] ??= []).add(v);
    }
    final theme = Theme.of(context);
    return SettingsCard(
      icon: Icons.delete_sweep_outlined,
      title: 'Telefonda silinenler (${all.length})',
      children: [
        if (async.isLoading && all.isEmpty) const LinearProgressIndicator(),
        if (async.hasError) Text('Liste okunamadı: ${async.error}', style: TextStyle(color: theme.colorScheme.error)),
        if (!async.isLoading && all.isEmpty)
          Text(
            'Yok. Telefonda silinen kayıtlar bir sonraki içe aktarmada burada görünür; bilgisayardan elle silersin.',
            style: mutedStyle(context),
          ),
        for (final g in groups.entries) ...[
          Row(
            children: [
              Expanded(child: Text('${tableLabel(g.key)} (${g.value.length})', style: theme.textTheme.titleSmall)),
              TextButton(
                onPressed: () => unawaited(_delete(context, ref, g.value)),
                child: Text(g.value.length == 1 ? 'Sil' : 'Hepsini sil'),
              ),
            ],
          ),
          for (final v in g.value.take(_shown))
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 8),
              title: Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('İlk fark edildiği içe aktarma: ${formatShortDate(v.tombstone.since)}'),
              trailing: IconButton(
                tooltip: 'Sil',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => unawaited(_delete(context, ref, [v])),
              ),
            ),
          if (g.value.length > _shown)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8),
              child: Text('… ve ${g.value.length - _shown} kayıt daha', style: mutedStyle(context)),
            ),
        ],
      ],
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    return SettingsCard(
      icon: Icons.palette_outlined,
      title: 'Görünüm',
      children: [
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('Sistem')),
            ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Açık')),
            ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Koyu')),
          ],
          selected: {settings?.themeMode ?? ThemeMode.system},
          onSelectionChanged: settings == null
              ? null
              : (s) => unawaited(ref.read(settingsProvider.notifier).change(settings.copyWith(themeMode: s.first))),
        ),
      ],
    );
  }
}

class _HistorySection extends ConsumerWidget {
  const _HistorySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(importHistoryProvider).value ?? const <ImportSummary>[];
    final theme = Theme.of(context);
    return SettingsCard(
      icon: Icons.history,
      title: 'İçe aktarma geçmişi',
      children: [
        if (history.isEmpty) Text('Henüz içe aktarma yok.', style: mutedStyle(context)),
        for (final s in history.take(10))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(s.automatic ? Icons.sync : Icons.download_done, size: 20),
            title: Text('${formatShortDate(s.at)} · ${s.source}${s.automatic ? ' (izlenen klasör)' : ''}'),
            subtitle: Text(
              [s.shortText, ...s.warnings].join(' · '),
              style: s.warnings.isEmpty ? null : TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
