import '../../../core/ledger/ledger_service.dart';
import 'media_rules.dart';
import 'sync_protocol.dart';

/// Tek istekte taşınan en çok değişiklik. Daha fazlası birkaç turda gider.
const ledgerBatch = 300;

/// Tek istekte itilen en çok tam durum satırı (`LedgerService.snapshotPage` en çok 400 verir).
const ledgerSnapshotPush = 400;

/// Alışveriş toplamı bu bayttan büyük olamaz (gövde sınırının altında kalsın).
const ledgerBatchBytes = 5 * 1024 * 1024;

final _mediaInJson = RegExp(r'"((?:questions|solutions|notes)/\d{4}/\d{2}/[A-Za-z0-9_-]{1,80}(?:\.[A-Za-z0-9]{1,8})?)"');

/// Bir satırın JSON'unda geçen fotoğraf yolları (yalnızca kurala uyanlar).
List<String> mediaPathsIn(String? json) => json == null
    ? const []
    : [
        for (final m in _mediaInJson.allMatches(json))
          if (isTransferableMediaPath(m.group(1)!)) m.group(1)!,
      ];

/// Bir değişiklik toplusunun yeni değerlerinde geçen fotoğraf yolları.
Set<String> mediaPathsOfChanges(Iterable<LedgerChange> changes) => {
      for (final c in changes) ...mediaPathsIn(c.neu),
    };

/// Telefondan bilgisayara: kendi değişiklikleri ve "bilgisayarın şu sıraya
/// kadarını aldım" bilgisi.
class LedgerRequest {
  const LedgerRequest({
    required this.schema,
    required this.device,
    required this.received,
    required this.changes,
    required this.lastSeq,
    this.snapshotCursor,
    this.pushSnapshot = const [],
  });

  /// Tam durum İTMESİ (v9.23, yalnız Android alıcıya): istemcinin kendi güncel
  /// satırları `ekle` biçiminde. Alıcı YALNIZCA eksik satırı ekler (`applySnapshot`:
  /// var olana dokunmaz, silineni geri getirmez, deftere işlemez). Bilgisayar alıcı
  /// bunun yerine ilk eşitlemede tam yedek alır.
  final List<LedgerChange> pushSnapshot;

  /// Tam durum isteği (v9.15): null = istenmiyor; boş metin = baştan; dolu = kaldığı yer.
  /// İstenirse bilgisayar defter değişikliği DÖNMEZ; yalnızca anlık görüntü satırları
  /// ve bu anki defter sırası gelir (tam durum, geçmişi yeniden oynatmadan başlar).
  final String? snapshotCursor;

  /// Veritabanı şema sürümü: iki taraf aynı olmalı.
  final int schema;
  final String device;

  /// Telefonun bilgisayardan aldığı son yerel sıra (bilgisayar bundan
  /// sonrakileri gönderir).
  final int received;
  final List<LedgerChange> changes;

  /// Bu topludaki en büyük telefon sırası (bilgisayar uygulayınca onaylar).
  final int lastSeq;

  Map<String, Object?> toJson() => {
        'sema': schema,
        'cihaz': device,
        'alinan': received,
        'satirlar': [for (final c in changes) c.toJson()],
        'son': lastSeq,
        if (snapshotCursor != null) 'anlik': snapshotCursor,
        if (pushSnapshot.isNotEmpty) 'anlikGonder': [for (final c in pushSnapshot) c.toJson()],
      };

  factory LedgerRequest.fromJson(Object? json) {
    if (json is! Map) throw const SyncException('Bozuk mesaj.');
    final rows = json['satirlar'];
    final schema = json['sema'], device = json['cihaz'], received = json['alinan'], last = json['son'];
    if (rows is! List || schema is! int || device is! String || received is! int || last is! int) {
      throw const SyncException('Bozuk mesaj: değişiklik listesi.');
    }
    if (rows.length > ledgerBatch) throw const SyncException('Değişiklik listesi çok uzun.');
    if (!isValidDeviceId(device)) throw const SyncException('Bozuk mesaj: cihaz.');
    final changes = <LedgerChange>[];
    for (final r in rows) {
      final c = LedgerChange.tryParse(r);
      if (c == null) throw const SyncException('Bozuk mesaj: değişiklik.');
      changes.add(c);
    }
    final snapshot = json['anlik'];
    if (snapshot != null && (snapshot is! String || snapshot.length > 512)) throw const SyncException('Bozuk mesaj: tam durum imleci.');
    final push = <LedgerChange>[];
    final rawPush = json['anlikGonder'];
    if (rawPush != null) {
      if (rawPush is! List || rawPush.length > ledgerSnapshotPush) throw const SyncException('Bozuk mesaj: tam durum satırları.');
      for (final r in rawPush) {
        final c = LedgerChange.tryParse(r);
        if (c == null) throw const SyncException('Bozuk mesaj: tam durum satırı.');
        push.add(c);
      }
    }
    return LedgerRequest(
        schema: schema,
        device: device,
        received: received,
        changes: changes,
        lastSeq: last,
        snapshotCursor: snapshot as String?,
        pushSnapshot: push);
  }
}

/// Bilgisayardan telefona: telefonun henüz görmediği değişiklikler, onay
/// ve (varsa) telefonun alması gereken fotoğraflar.
class LedgerResponse {
  const LedgerResponse({
    required this.acked,
    required this.changes,
    required this.lastSeq,
    required this.more,
    required this.photos,
    required this.summary,
    this.snapshot = const [],
    this.snapshotNext,
    this.snapshotMarker = 0,
    this.device,
  });

  /// Alıcının DEFTER cihaz kimliği (v9.23): istemci, alıcıdan gelen satırları ona
  /// geri yollamasın diye (yankı). Eski sürüm göndermez: null.
  final String? device;

  /// Tam durum sayfası (yalnızca istenirse): güncel satırlar `ekle` biçiminde.
  final List<LedgerChange> snapshot;

  /// Sonraki istekte gönderilecek imleç; null = tam durum bitti (ya da istenmedi).
  final String? snapshotNext;

  /// Tam durum yanıtında bilgisayar defterinin o anki en büyük sırası: bittiğinde
  /// cihazın `alinan_sira` imleci buraya çekilir (geçmiş yeniden oynatılmaz).
  final int snapshotMarker;

  /// Bilgisayarın uyguladığı en büyük telefon sırası.
  final int acked;
  final List<LedgerChange> changes;

  /// Bu topludaki en büyük bilgisayar sırası (telefon bir sonrakinde buradan ister).
  final int lastSeq;

  /// Bilgisayarda gönderilecek daha değişiklik var.
  final bool more;

  /// Bu değişikliklerin başvurduğu ve bilgisayarda bulunan fotoğraflar.
  final List<MediaEntry> photos;

  /// "3 uygulandı, 1 çakışma" gibi kısa özet.
  final String summary;

  Map<String, Object?> toJson() => {
        'onay': acked,
        'satirlar': [for (final c in changes) c.toJson()],
        'son': lastSeq,
        'daha': more,
        'fotograflar': [
          for (final p in photos) {'yol': p.path, 'boyut': p.size},
        ],
        'ozet': summary,
        if (device != null) 'cihaz': device,
        if (snapshot.isNotEmpty || snapshotNext != null || snapshotMarker > 0) ...{
          'anlik': [for (final c in snapshot) c.toJson()],
          'anlikSonra': snapshotNext,
          'anlikSira': snapshotMarker,
        },
      };

  factory LedgerResponse.fromJson(Object? json) {
    if (json is! Map) throw const SyncException('Bilgisayardan bozuk yanıt geldi.');
    final rows = json['satirlar'], acked = json['onay'], last = json['son'];
    if (rows is! List || acked is! int || last is! int) throw const SyncException('Bilgisayardan bozuk yanıt geldi.');
    final changes = <LedgerChange>[];
    for (final r in rows) {
      final c = LedgerChange.tryParse(r);
      if (c == null) throw const SyncException('Bilgisayardan bozuk değişiklik geldi.');
      changes.add(c);
    }
    final photos = <MediaEntry>[];
    final ph = json['fotograflar'];
    if (ph is List) {
      for (final e in ph) {
        if (e is Map && e['yol'] is String && e['boyut'] is int && isTransferableMediaPath(e['yol'] as String)) {
          photos.add(MediaEntry(e['yol'] as String, e['boyut'] as int));
        }
      }
    }
    final snap = <LedgerChange>[];
    final rawSnap = json['anlik'];
    if (rawSnap is List) {
      for (final r in rawSnap) {
        final c = LedgerChange.tryParse(r);
        if (c == null) throw const SyncException('Bilgisayardan bozuk tam durum satırı geldi.');
        snap.add(c);
      }
    }
    return LedgerResponse(
      snapshot: snap,
      snapshotNext: json['anlikSonra'] is String ? json['anlikSonra'] as String : null,
      snapshotMarker: json['anlikSira'] is int ? json['anlikSira'] as int : 0,
      acked: acked,
      changes: changes,
      lastSeq: last,
      more: json['daha'] == true,
      photos: photos,
      summary: json['ozet'] is String ? json['ozet'] as String : '',
      device: json['cihaz'] is String && isValidDeviceId(json['cihaz'] as String) ? json['cihaz'] as String : null,
    );
  }
}

/// Telefonun bilgisayardan istediği tek fotoğraf.
class PhotoGetRequest {
  const PhotoGetRequest(this.path);
  final String path;

  Map<String, Object?> toJson() => {'yol': path};

  factory PhotoGetRequest.fromJson(Object? json) {
    if (json is Map && json['yol'] is String) return PhotoGetRequest(json['yol'] as String);
    throw const SyncException('Bozuk mesaj: fotoğraf yolu.');
  }
}
