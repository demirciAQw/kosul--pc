import 'dart:io';
import 'dart:typed_data';

import 'app_database.dart';

/// Yedek ZIP'inde veritabanı kopyasının adı. Bilgisayar uygulaması bu dosyayı
/// satır satır birleştirir; kitapların test kimlikleri ve tekrar durumları gibi
/// JSON'da olmayan her şey burada eksiksiz durur.
const databaseSnapshotName = 'kocum.db';

/// Veritabanının tutarlı bir kopyası; uygulama açıkken bile güvenli
/// (SQLite `VACUUM INTO`). [scratch] geçici dosyadır, iş bitince silinir.
Future<Uint8List> databaseSnapshot(AppDatabase db, File scratch) async {
  if (await scratch.exists()) await scratch.delete();
  try {
    await db.customStatement('VACUUM INTO ?', [scratch.path]);
    return await scratch.readAsBytes();
  } finally {
    if (await scratch.exists()) await scratch.delete();
  }
}

/// SQLite dosya başlığından şema sürümü (`PRAGMA user_version`, bayt 60–63).
/// Dosya SQLite değilse null.
int? sqliteUserVersion(List<int> header) {
  const magic = 'SQLite format 3\u0000';
  if (header.length < 64) return null;
  for (var i = 0; i < magic.length; i++) {
    if (header[i] != magic.codeUnitAt(i)) return null;
  }
  return ByteData.sublistView(Uint8List.fromList(header.sublist(60, 64))).getUint32(0);
}
