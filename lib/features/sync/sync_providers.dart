import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/phone_sync_store.dart';

/// Eşleşme kaydı uygulamanın kendi (başka uygulamaların erişemediği)
/// klasöründe durur.
final phoneSyncStoreProvider = Provider<PhoneSyncStore>((ref) => PhoneSyncStore(
      () async => File(p.join((await getApplicationSupportDirectory()).path, 'esitleme.json')),
    ));

/// Telefonun eşleştiği bilgisayar; yoksa null.
final pairedComputerProvider =
    FutureProvider<PairedComputer?>((ref) => ref.watch(phoneSyncStoreProvider).computer());

/// "PDF dosyalarını da gönder" ayarı (varsayılan kapalı).
final sendPdfsProvider = FutureProvider<bool>((ref) => ref.watch(phoneSyncStoreProvider).sendPdfs());
