import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/formatters.dart';
import '../../desktop_providers.dart';
import '../data/import_service.dart';
import '../domain/import_rules.dart';
import '../import_providers.dart';
import 'import_flow.dart';

class AutoImportState {
  const AutoImportState({this.folder, this.watching = false, this.message});

  final String? folder;
  final bool watching;
  final String? message;
}

/// İzlenen klasör: Syncthing, KDE Connect ya da USB ile gelen yeni yedek ZIP'i
/// (yazılması bitince) kendiliğinden içe aktarılır. Son içe aktarılandan eski
/// yedekler alınmaz; aynı dosya değişmedikçe yeniden denenmez.
class AutoImportController extends Notifier<AutoImportState> {
  StreamSubscription<FileSystemEvent>? _subscription;
  Timer? _timer;
  var _scanning = false;

  @override
  AutoImportState build() {
    ref.onDispose(_stop);
    unawaited(_restore());
    return const AutoImportState();
  }

  ImportService get _service => ref.read(importServiceProvider);

  Future<void> _restore() async {
    final folder = await _service.state.watchedFolder();
    if (folder != null) await _watch(folder);
  }

  Future<void> setFolder(String? folder) async {
    _stop();
    await _service.state.setWatchedFolder(folder);
    if (folder == null) {
      state = const AutoImportState();
    } else {
      await _watch(folder);
    }
  }

  Future<void> _watch(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) {
      state = AutoImportState(folder: folder, message: 'Klasör bulunamadı.');
      return;
    }
    try {
      _subscription = dir.watch().listen(
        (_) => _schedule(),
        onError: (Object e) {
          state = AutoImportState(folder: folder, message: 'İzleme durdu: $e');
        },
      );
    } on FileSystemException catch (e) {
      state = AutoImportState(folder: folder, message: 'Klasör izlenemiyor: ${e.message}');
      return;
    }
    state = AutoImportState(folder: folder, watching: true, message: 'Yeni yedek bekleniyor.');
    _schedule(); // uygulama kapalıyken gelmiş yedekler
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  /// Dosya yazılırken art arda olay gelir; son olaydan 3 sn sonra bakılır.
  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), () => unawaited(_scan()));
  }

  void _say(String message) =>
      state = AutoImportState(folder: state.folder, watching: state.watching, message: message);

  Future<void> _scan() async {
    final folder = state.folder;
    if (folder == null || !state.watching || _scanning) return;
    // Elle içe aktarma sürüyorsa biraz sonra yeniden bakılır.
    if (ref.read(importBusyProvider) != null) {
      _schedule();
      return;
    }
    _scanning = true;
    try {
      final files = <BackupFileInfo>[];
      await for (final e in Directory(folder).list(followLinks: false)) {
        if (e is File && isBackupCandidate(p.basename(e.path))) {
          final s = await e.stat();
          files.add(BackupFileInfo(p.basename(e.path), s.size, s.modified));
        }
      }
      final pick = pickBackupToImport(files, await _service.state.processedFiles());
      for (final f in pick.skip) {
        await _service.state.markProcessed(f.name, f.fingerprint);
      }
      final file = pick.import;
      if (file == null) return;
      // Eşitleme hâlâ yazıyor olabilir: boyut ve tarih 2 sn sabit kalmalı.
      await Future<void>.delayed(const Duration(seconds: 2));
      final again = await File(p.join(folder, file.name)).stat();
      if (again.size != file.size || again.modified != file.modified) {
        _schedule();
        return;
      }
      await _import(folder, file);
    } on FileSystemException catch (e) {
      _say('Klasör okunamadı: ${e.message}');
    } finally {
      _scanning = false;
    }
  }

  Future<void> _import(String folder, BackupFileInfo file) async {
    final busy = ref.read(importBusyProvider.notifier);
    busy.set('İzlenen klasörden içe aktarılıyor: ${file.name}');
    try {
      final job = await _service.prepare(p.join(folder, file.name));
      if (job.isOlder) {
        await _service.discard(job);
        _say('${file.name} son içe aktarılandan eski; kendiliğinden alınmadı. İstersen elle içe aktar.');
        return;
      }
      final summary = await _service.run(job, automatic: true);
      ref
        ..invalidate(importHistoryProvider)
        ..invalidate(tombstonesProvider);
      _say('Son: ${file.name}, ${formatShortDate(summary.at)}');
      desktopMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Telefon yedeği alındı (${file.name}): ${summary.shortText}')),
      );
    } on Exception catch (e) {
      _say('${file.name} içe aktarılamadı: $e');
    } finally {
      // Aynı dosya değişmedikçe yeniden denenmez (bozuk dosyada döngü olmasın).
      await _service.state.markProcessed(file.name, file.fingerprint);
      busy.set(null);
    }
  }
}

final autoImportProvider = NotifierProvider<AutoImportController, AutoImportState>(AutoImportController.new);
