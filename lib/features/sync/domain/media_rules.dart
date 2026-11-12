import 'sync_protocol.dart';

/// Kablosuz aktarılabilen dosyalar yalnızca Koçum'un fotoğraflarıdır:
/// "questions|solutions|notes/<yıl>/<ay>/<ad>.<uzantı>". Başka hiçbir yol
/// (ör. "../", mutlak yol, gizli dosya, alt klasör) kabul edilmez; bilgisayar
/// da telefon da yalnızca uygulamanın kendi alanına dokunur.
final _mediaPath = RegExp(r'^(questions|solutions|notes)/\d{4}/\d{2}/[A-Za-z0-9_-]{1,80}(\.[A-Za-z0-9]{1,8})?$');

bool isTransferableMediaPath(String path) => path.length <= 160 && _mediaPath.hasMatch(path);

/// Bilgisayar tarafı: telefonun listesindeki geçerli yollardan bilgisayarda
/// olmayanlar ya da boyutu tutmayanlar (yarım kalmış aktarım). [localSizes]
/// geçerli yolların bilgisayardaki boyutu; dosya yoksa null.
({List<String> missing, int rejected}) selectMissingMedia(
  List<MediaEntry> offered,
  Map<String, int?> localSizes,
) {
  final missing = <String>[];
  final seen = <String>{};
  var rejected = 0;
  for (final e in offered) {
    if (!isTransferableMediaPath(e.path) || e.size < 0 || e.size > SyncLimits.photo) {
      rejected++;
      continue;
    }
    if (!seen.add(e.path)) continue;
    if (localSizes[e.path] != e.size) missing.add(e.path);
  }
  return (missing: missing, rejected: rejected);
}

/// Telefon tarafı: bilgisayarın istediği yollar yalnızca telefonun kendi
/// sunduğu listeden olabilir. Bilgisayar listede olmayan bir dosya isterse
/// (ör. "../ayarlar") o istek yok sayılır.
List<MediaEntry> requestedFromOffer(List<MediaEntry> offered, List<String> requested) {
  final byPath = {for (final e in offered) e.path: e};
  final out = <MediaEntry>[];
  final seen = <String>{};
  for (final path in requested) {
    final e = byPath[path];
    if (e != null && isTransferableMediaPath(path) && seen.add(path)) out.add(e);
  }
  return out;
}
