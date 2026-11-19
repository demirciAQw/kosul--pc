import '../../../core/ledger/ledger_service.dart';
import 'media_rules.dart';
import 'sync_protocol.dart';

/// Tek istekte taşınan en çok değişiklik. Daha fazlası birkaç turda gider.
const ledgerBatch = 300;

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
  });

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
    return LedgerRequest(schema: schema, device: device, received: received, changes: changes, lastSeq: last);
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
  });

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
    return LedgerResponse(
      acked: acked,
      changes: changes,
      lastSeq: last,
      more: json['daha'] == true,
      photos: photos,
      summary: json['ozet'] is String ? json['ozet'] as String : '',
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
