import 'sync_protocol.dart';

/// PDF dosyası aktarımının kuralları (saf Dart). Fotoğraflardan ayrıdır:
/// tek bir kalıp kabul edilir, `<sha256>.pdf`. Ad hem klasör düzeni
/// (`<veri klasörü>/pdfs/<sha256>.pdf`, `PdfImportService.fileOf` ile aynı) hem
/// de doğrulama anahtarıdır: sunucu gelen baytların özetini hesaplayıp adla
/// karşılaştırır. Yol, `..`, alt klasör ya da başka uzantı kabul edilmez.
final _pdfName = RegExp(r'^[0-9a-f]{64}\.pdf$');

bool isTransferablePdfName(String name) => _pdfName.hasMatch(name);

/// Geçerli sha256'dan aktarım adı; geçersizse null.
String? pdfNameOfSha(String sha256) {
  final name = '$sha256.pdf';
  return isTransferablePdfName(name) ? name : null;
}

/// Adın özeti (ilk 64 hane); ad geçersizse null.
String? shaOfPdfName(String name) => isTransferablePdfName(name) ? name.substring(0, 64) : null;

/// Gönderilecek bir PDF: özeti ve bu cihazdaki dosya boyutu.
class PdfOffer {
  const PdfOffer(this.sha256, this.size);

  final String sha256;
  final int size;

  String get name => '$sha256.pdf';
}

/// Telefon/tablet tarafı: belge satırlarından (özet → bu cihazdaki dosya boyutu,
/// dosya yoksa null) gönderilebilecekler ile atlananlar.
({List<PdfOffer> send, int missingFile, int tooBig}) selectPdfsToSend(Map<String, int?> sizes) {
  final send = <PdfOffer>[];
  var missingFile = 0, tooBig = 0;
  for (final e in sizes.entries) {
    final size = e.value;
    if (pdfNameOfSha(e.key) == null) continue; // bozuk satır: göz ardı
    if (size == null || size <= 0) {
      missingFile++;
    } else if (size > SyncLimits.pdf) {
      tooBig++;
    } else {
      send.add(PdfOffer(e.key, size));
    }
  }
  send.sort((a, b) => a.size.compareTo(b.size)); // küçükler önce: hızlı sonuç
  return (send: send, missingFile: missingFile, tooBig: tooBig);
}

/// "12,3 MB" gibi kısa boyut yazısı.
String formatPdfSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0).replaceAll('.', ',')} MB';
}

/// Cihazın bilgisayardan istediği PDF (`pdf-al`): ad ve kaç bayttan başlanacağı
/// (kopan indirme kaldığı yerden sürsün). Gövde imzalıdır.
class PdfGetRequest {
  const PdfGetRequest(this.name, {this.start = 0});

  final String name;
  final int start;

  Map<String, Object?> toJson() => {'yol': name, 'baslangic': start};

  factory PdfGetRequest.fromJson(Object? json) {
    if (json is Map && json['yol'] is String && (json['baslangic'] == null || json['baslangic'] is int)) {
      return PdfGetRequest(json['yol'] as String, start: (json['baslangic'] as int?) ?? 0);
    }
    throw const SyncException('Bozuk mesaj: PDF isteği.');
  }
}

/// `pdf-al` yanıt imzasının bağlandığı üst bilgi (dosya iki kez okunmasın diye
/// baytların kendisi değil ad, başlangıç ve toplam boyut imzalanır; baytların
/// bütünlüğünü adın SHA-256'sı kanıtlar).
String pdfGetMeta(String name, int start, int total) => '$name|$start|$total';
