/// Huawei Sağlık "Verilerini iste" dışa aktarımı için TOLERANSLI ayrıştırıcı
/// (saf Dart).
///
/// ÖNEMLİ: Bu dışa aktarımın GERÇEK ŞEMASI BİLİNMİYOR (Huawei belgelemiyor;
/// aylık ZIP, JSON + XLSX açıklama dosyaları; stres verisi olup olmadığı
/// belirsiz). Bu yüzden iki aşama var:
///  1. [describeHuaweiStructure]: dosya adları ve JSON/CSV ANAHTAR/SÜTUN adları
///     (DEĞERLER OLMADAN) = "Yapı raporu". Kullanıcı bunu kopyalayıp gösterir.
///  2. [parseHuaweiFiles]: sık geçen alan adlarıyla tahmine dayalı arama. Hiçbir
///     şeyi bulamazsa nedenini söyler. Bulduğu her şey önizlemeyle onaylanır.
/// Sentetik örnekler test/health/huawei_zip_parser_test.dart içindedir; gerçek
/// bir Huawei dosyasıyla DENENMEDİ.
library;

import 'dart:convert';

import '../../../core/database/health_tables.dart';
import 'health_models.dart';

/// Okunmuş bir dosya: [text] null ise ikili/okunamaz (ör. XLSX).
class HuaweiFile {
  const HuaweiFile(this.name, this.size, this.text);
  final String name;
  final int size;
  final String? text;
}

// ───────────────────────── Yapı raporu ─────────────────────────

class FileStructure {
  const FileStructure({required this.name, required this.kind, required this.size, this.keys = const [], this.rows});
  final String name;

  /// json | csv | xlsx | diğer
  final String kind;
  final int size;

  /// JSON: anahtar yolları (`kayitlar[].baslangic`); CSV: sütun adları.
  final List<String> keys;
  final int? rows;
}

String _kindOf(String name) {
  final l = name.toLowerCase();
  if (l.endsWith('.json') || l.endsWith('.jsonl')) return 'json';
  if (l.endsWith('.csv') || l.endsWith('.tsv')) return 'csv';
  if (l.endsWith('.xlsx') || l.endsWith('.xls')) return 'xlsx';
  return 'diğer';
}

final _dynamicKey = RegExp(r'^[\d\-:T .+Z/_]+$');

List<FileStructure> describeHuaweiStructure(List<HuaweiFile> files) => [
      for (final f in files) _describe(f),
    ];

FileStructure _describe(HuaweiFile f) {
  final kind = _kindOf(f.name);
  final t = f.text;
  if (t == null) return FileStructure(name: f.name, kind: kind, size: f.size);
  if (kind == 'csv') {
    final rows = _readCsv(t);
    return FileStructure(
      name: f.name,
      kind: kind,
      size: f.size,
      keys: rows.header,
      rows: rows.rows.length,
    );
  }
  if (kind == 'json') {
    final docs = _decodeJsonDocs(t);
    final keys = <String>{};
    var biggest = 0;
    for (final d in docs) {
      _collectKeys(d, '', keys, 0);
      biggest = _maxList(d) > biggest ? _maxList(d) : biggest;
    }
    final sorted = keys.toList()..sort();
    return FileStructure(
      name: f.name,
      kind: kind,
      size: f.size,
      keys: sorted.take(120).toList(),
      rows: biggest == 0 ? null : biggest,
    );
  }
  return FileStructure(name: f.name, kind: kind, size: f.size);
}

void _collectKeys(Object? n, String path, Set<String> out, int depth) {
  if (depth > 7 || out.length > 400) return;
  if (n is Map) {
    for (final e in n.entries) {
      final k = '${e.key}';
      final shown = _dynamicKey.hasMatch(k) ? '<sayı/tarih>' : k;
      final p = path.isEmpty ? shown : '$path.$shown';
      out.add(p);
      _collectKeys(e.value, p, out, depth + 1);
    }
  } else if (n is List) {
    for (final e in n.take(50)) {
      _collectKeys(e, '$path[]', out, depth + 1);
    }
  } else if (n is String) {
    final inner = _tryJson(n);
    if (inner != null) _collectKeys(inner, '$path{json}', out, depth + 1);
  }
}

int _maxList(Object? n) {
  if (n is List) {
    var m = n.length;
    for (final e in n.take(20)) {
      final x = _maxList(e);
      if (x > m) m = x;
    }
    return m;
  }
  if (n is Map) {
    var m = 0;
    for (final v in n.values) {
      final x = _maxList(v);
      if (x > m) m = x;
    }
    return m;
  }
  return 0;
}

/// Kopyalanabilir yapı raporu (kişisel değer YOK).
String structureReportText(List<FileStructure> files) {
  final b = StringBuffer()
    ..writeln('Koçum: Huawei verisi yapı raporu (yalnız dosya ve alan adları; değerler yok)')
    ..writeln('Dosya sayısı: ${files.length}');
  for (final f in files) {
    b
      ..writeln()
      ..writeln('- ${f.name} [${f.kind}, ${f.size} bayt${f.rows == null ? '' : ', ~${f.rows} kayıt'}]');
    if (f.kind == 'xlsx') b.writeln('  (XLSX: açıklama dosyası olabilir; içeriği okunmadı)');
    for (final k in f.keys) {
      b.writeln('  $k');
    }
  }
  return b.toString();
}

// ───────────────────────── Ayrıştırma ─────────────────────────

class HuaweiParseResult {
  const HuaweiParseResult({
    this.sleep = const [],
    this.stress = const [],
    this.days = const [],
    this.notes = const [],
  });

  /// Başlangıç/bitişi bilinen uyku oturumları.
  final List<SleepSession> sleep;
  final List<StressSample> stress;

  /// Yalnız gün + toplam bilinen uyku kayıtları (saati yok).
  final List<HealthDay> days;

  /// Uyarılar ve "neden bulunamadı" açıklamaları (Türkçe).
  final List<String> notes;

  bool get isEmpty => sleep.isEmpty && stress.isEmpty && days.isEmpty;

  int get sleepDayCount => {...sleep.map((s) => s.day), ...days.map((d) => d.day)}.length;
  int get stressDayCount => {for (final s in stress) dayKey(s.time)}.length;

  DateTime? get first {
    final ts = [...sleep.map((s) => s.end), ...stress.map((s) => s.time), ...days.map((d) => DateTime.parse(d.day))];
    if (ts.isEmpty) return null;
    return ts.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  DateTime? get last {
    final ts = [...sleep.map((s) => s.end), ...stress.map((s) => s.time), ...days.map((d) => DateTime.parse(d.day))];
    if (ts.isEmpty) return null;
    return ts.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// Önizleme metni.
  String preview() {
    if (isEmpty) return notes.isEmpty ? 'Hiçbir uyku ya da stres kaydı bulunamadı.' : notes.join('\n');
    String d(DateTime t) => dayKey(t);
    return 'Uyku: ${sleep.length + days.length} kayıt, $sleepDayCount gün\n'
        'Stres: ${stress.length} ölçüm, $stressDayCount gün\n'
        'Tarih aralığı: ${d(first!)} – ${d(last!)}';
  }
}

HuaweiParseResult parseHuaweiFiles(List<HuaweiFile> files, {String source = healthSourceHuaweiZip}) {
  final sleeps = <int, SleepSession>{};
  final stressRaw = <int, _RawStress>{};
  final days = <String, HealthDay>{};
  final notes = <String>[];
  var readable = 0;
  final noted = <String>{};

  for (final f in files) {
    final kind = _kindOf(f.name);
    final t = f.text;
    if (t == null) {
      if (kind == 'xlsx') continue; // açıklama dosyası
      continue;
    }
    readable++;
    final ctxFile = f.name.toLowerCase();
    final c = _Collector(source: source);
    if (kind == 'csv') {
      final csv = _readCsv(t);
      for (final r in csv.rows) {
        c.record(r, ctxFile);
      }
    } else if (kind == 'json') {
      for (final d in _decodeJsonDocs(t)) {
        c.walk(d, ctxFile, 0);
      }
    } else {
      continue;
    }
    for (final s in c.sleep) {
      sleeps[s.start.millisecondsSinceEpoch] = s;
    }
    for (final d in c.days) {
      days[d.day] = d;
    }
    for (final s in c.stress) {
      stressRaw[s.time.millisecondsSinceEpoch] = s;
    }
    if (c.dayStressUsed && noted.add('gunluk-stres')) {
      notes.add('Günlük ortalama gibi görünen stres kayıtları o günün öğlen 12:00 ölçümü olarak alındı.');
    }
  }

  // Stres ölçeği: hiç 5'ten büyük değer yoksa 1..5, yoksa 0..100 varsay.
  final maxRaw = stressRaw.values.fold<double>(0, (a, s) => s.level > a ? s.level : a);
  final scale = stressRaw.isEmpty ? 100 : (maxRaw <= 5 ? 5 : 100);
  final stress = [
    for (final s in stressRaw.values)
      StressSample(time: s.time, level: s.level, max: scale, source: source),
  ]..sort((a, b) => a.time.compareTo(b.time));
  final sleep = sleeps.values.toList()..sort((a, b) => a.start.compareTo(b.start));
  // Saatli oturumu olan günün gün-özeti kaydı tekrar sayılmasın.
  final sessionDays = {for (final s in sleep) s.day};
  final dayList = [for (final d in days.values) if (!sessionDays.contains(d.day)) d]
    ..sort((a, b) => a.day.compareTo(b.day));

  final result = HuaweiParseResult(sleep: sleep, stress: stress, days: dayList, notes: notes);
  if (result.isEmpty) {
    final why = <String>[
      if (files.isEmpty)
        'ZIP/klasörde dosya yok.'
      else if (readable == 0)
        'Okunabilir JSON/CSV dosyası yok (yalnız XLSX/ikili dosyalar olabilir). Şifreli ZIP desteklenmez.'
      else
        'JSON/CSV dosyaları okundu ama uyku (başlangıç-bitiş saatli) ya da stres (zaman + değer) kaydına benzeyen '
            'alan bulunamadı. Huawei bu verileri dışa aktarmıyor olabilir ya da alan adları tanıdığım adlardan farklı. '
            '"Yapı raporu"nu kopyalayıp gönder; ayrıştırıcı ona göre uyarlanır.',
    ];
    return HuaweiParseResult(notes: [...notes, ...why]);
  }
  return result;
}

class _RawStress {
  _RawStress(this.time, this.level);
  final DateTime time;
  final double level;
}

// Anahtar adlarını parçalara ayırır: "deepSleepTime" -> {deep, sleep, time}.
Set<String> _tokens(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((e) => e.isNotEmpty);
  return spaced.toSet();
}

String _norm(String key) => key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

const _startNames = {
  'starttime', 'start', 'begintime', 'begin', 'fallasleeptime', 'sleepstart', 'sleepstarttime', 'bedtime',
  'starttimestamp', 'startdate', 'baslangic', 'baslangicsaati', 'yatis',
};
const _endNames = {
  'endtime', 'end', 'wakeuptime', 'wakeup', 'waketime', 'sleepend', 'sleependtime', 'risetime', 'endtimestamp',
  'enddate', 'bitis', 'bitissaati', 'kalkis',
};
const _timeNames = {
  'time', 'timestamp', 'starttime', 'recordtime', 'measuretime', 'datetime', 'date', 'createtime', 'savetime',
  'starttimestamp', 'zaman', 'tarih',
};
const _dayNames = {'date', 'day', 'daytime', 'sleepdate', 'calendarday', 'recorddate', 'tarih', 'gun', 'statdate'};
const _totalNames = {
  'sleepduration', 'totalsleep', 'totalsleeptime', 'sleeptime', 'totalduration', 'sleepminutes', 'duration',
  'totalsleepduration', 'sleeplength', 'toplamuyku',
};

class _Collector {
  _Collector({required this.source});
  final String source;
  final sleep = <SleepSession>[];
  final days = <HealthDay>[];
  final stress = <_RawStress>[];
  bool dayStressUsed = false;

  void walk(Object? node, String ctx, int depth) {
    if (depth > 8) return;
    if (node is List) {
      for (final e in node) {
        walk(e, ctx, depth + 1);
      }
    } else if (node is Map) {
      record(node.map((k, v) => MapEntry('$k', v)), ctx);
      for (final e in node.entries) {
        final v = e.value;
        final sub = '$ctx/${e.key}'.toLowerCase();
        if (v is Map || v is List) {
          walk(v, sub, depth + 1);
        } else if (v is String && v.length > 2) {
          final inner = _tryJson(v);
          if (inner != null) walk(inner, sub, depth + 1);
        }
      }
    }
  }

  void record(Map<String, Object?> m, String ctx) {
    final c = ctx.toLowerCase();
    final sleepCtx = c.contains('sleep') || c.contains('uyku') || c.contains('slp');
    final stressCtx = c.contains('stress') || c.contains('stres') || c.contains('pressure');
    final keys = {for (final k in m.keys) _norm(k): k};
    final stageKeys = m.keys.where((k) {
      final t = _tokens(k);
      return t.contains('deep') || t.contains('rem') || t.contains('light') || t.contains('awake');
    }).isNotEmpty;

    // Aşama listesinin öğeleri ayrı uyku oturumu değildir.
    final lastSeg = _tokens(c.split('/').last);
    final inStageList = lastSeg.any(const {'stage', 'stages', 'phase', 'segment', 'detail', 'details'}.contains);
    if ((sleepCtx || stageKeys) && !inStageList) {
      if (_tryTimedSleep(m, keys, stageKeys, sleepCtx)) return;
      _tryDaySleep(m, keys, stageKeys, sleepCtx);
    }
    if (stressCtx || keys.keys.any((k) => k.contains('stress'))) _tryStress(m, keys);
  }

  Object? _pick(Map<String, Object?> m, Map<String, String> keys, Set<String> names) {
    for (final n in names) {
      final k = keys[n];
      if (k != null && m[k] != null) return m[k];
    }
    return null;
  }

  bool _tryTimedSleep(Map<String, Object?> m, Map<String, String> keys, bool stageKeys, bool sleepCtx) {
    final start = _parseTime(_pick(m, keys, _startNames));
    final end = _parseTime(_pick(m, keys, _endNames));
    if (start == null || end == null || !end.isAfter(start)) return false;
    final span = end.difference(start).inMinutes;
    if (span < 20 || span > 24 * 60) return false;
    int? totalMin;
    for (final e in m.entries) {
      if (!_totalNames.contains(_norm(e.key))) continue;
      final v = _num(e.value);
      if (v != null && v >= 0) {
        totalMin = _toMinutes(v, _tokens(e.key), span);
        break;
      }
    }
    int? mins(Set<String> need, {Set<String> not = const {}}) {
      for (final e in m.entries) {
        final t = _tokens(e.key);
        if (!need.every(t.contains) || not.any(t.contains)) continue;
        final v = _num(e.value);
        if (v == null || v < 0) continue;
        return _toMinutes(v, t, span);
      }
      return null;
    }

    final stages = _stageList(m);
    sleep.add(SleepSession(
      start: start,
      end: end,
      source: source,
      stages: stages,
      totalMinutesOverride: totalMin,
      deepMinutesOverride: mins({'deep'}),
      lightMinutesOverride: mins({'light'}),
      remMinutesOverride: mins({'rem'}),
      awakeMinutesOverride: mins({'awake'}),
    ));
    return true;
  }

  List<SleepStageSpan> _stageList(Map<String, Object?> m) {
    for (final e in m.entries) {
      final t = _tokens(e.key);
      if (e.value is! List) continue;
      if (!(t.contains('stage') || t.contains('stages') || t.contains('phase') || t.contains('segment') || t.contains('detail'))) {
        continue;
      }
      final out = <SleepStageSpan>[];
      for (final x in e.value as List) {
        if (x is! Map) continue;
        final mm = x.map((k, v) => MapEntry('$k', v));
        final keys = {for (final k in mm.keys) _norm(k): k};
        final s = _parseTime(_pick(mm, keys, _startNames));
        final en = _parseTime(_pick(mm, keys, _endNames));
        final type = _pick(mm, keys, {'type', 'stage', 'status', 'sleepstage', 'state'});
        if (s == null || en == null || !en.isAfter(s) || type is! String) continue;
        final kind = _stageKindOf(type);
        if (kind == null) continue;
        out.add(SleepStageSpan(s, en, kind));
      }
      if (out.isNotEmpty) return out;
    }
    return const [];
  }

  void _tryDaySleep(Map<String, Object?> m, Map<String, String> keys, bool stageKeys, bool sleepCtx) {
    final day = _parseTime(_pick(m, keys, _dayNames));
    if (day == null) return;
    int? mins(String token) {
      for (final e in m.entries) {
        final t = _tokens(e.key);
        if (!t.contains(token)) continue;
        final v = _num(e.value);
        if (v != null && v >= 0) return _toMinutes(v, t, null);
      }
      return null;
    }

    final deep = mins('deep'), light = mins('light'), rem = mins('rem'), awake = mins('awake');
    int? tm;
    for (final e in m.entries) {
      if (!_totalNames.contains(_norm(e.key))) continue;
      final v = _num(e.value);
      if (v != null && v >= 0) {
        tm = _toMinutes(v, _tokens(e.key), null);
        break;
      }
    }
    tm ??= (deep == null && light == null && rem == null) ? null : (deep ?? 0) + (light ?? 0) + (rem ?? 0);
    if (tm == null || tm < 20 || tm > 24 * 60) return;
    days.add(HealthDay(
      day: dayKey(day),
      source: source,
      sleepTotalMin: tm,
      sleepDeepMin: deep,
      sleepLightMin: light,
      sleepRemMin: rem,
      sleepAwakeMin: awake,
    ));
  }

  void _tryStress(Map<String, Object?> m, Map<String, String> keys) {
    // Değer: adında "stress"/"pressure"/"stres" geçen sayı; yoksa value/score/level.
    double? level;
    for (final e in m.entries) {
      final n = _norm(e.key);
      if (n.contains('stress') || n.contains('stres') || n.contains('pressure')) {
        if (n.contains('max') || n.contains('min')) continue;
        final v = _num(e.value);
        if (v != null) {
          level = v;
          break;
        }
      }
    }
    level ??= _num(_pick(m, keys, {'value', 'score', 'level', 'avg', 'average'}));
    if (level == null || level < 0 || level > 100) return;
    final t = _parseTime(_pick(m, keys, _timeNames));
    if (t == null) return;
    // Saat bilgisi yoksa (yalnız gün) öğlen 12:00 örneği.
    final dateOnly = t.hour == 0 && t.minute == 0 && t.second == 0;
    if (dateOnly) dayStressUsed = true;
    stress.add(_RawStress(dateOnly ? DateTime(t.year, t.month, t.day, 12) : t, level));
  }
}

SleepStageKind? _stageKindOf(String s) {
  final l = s.toLowerCase();
  if (l.contains('deep')) return SleepStageKind.deep;
  if (l.contains('light')) return SleepStageKind.light;
  if (l.contains('rem') || l.contains('dream')) return SleepStageKind.rem;
  if (l.contains('awake') || l.contains('wake')) return SleepStageKind.awake;
  if (l.contains('sleep')) return SleepStageKind.sleeping;
  return null;
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// Süre birimi: anahtarda varsa ona göre; yoksa [span] (dk) ile uyumluya göre; yoksa dakika/saniye tahmini.
int _toMinutes(double v, Set<String> tokens, int? span) {
  if (tokens.contains('ms') || tokens.contains('millis') || tokens.contains('milliseconds')) return (v / 60000).round();
  if (tokens.contains('sec') || tokens.contains('secs') || tokens.contains('seconds') || tokens.contains('s')) {
    return (v / 60).round();
  }
  if (tokens.contains('min') || tokens.contains('mins') || tokens.contains('minutes')) return v.round();
  if (tokens.contains('hour') || tokens.contains('hours') || tokens.contains('h')) return (v * 60).round();
  if (span != null && span > 0) {
    for (final div in [1.0, 60.0, 60000.0]) {
      final m = v / div;
      if (m <= span * 1.15) return m.round();
    }
  }
  if (v <= 1000) return v.round();
  if (v <= 86400) return (v / 60).round();
  return (v / 60000).round();
}

/// Sayı (sn/ms), "yyyyMMdd", ISO ve "gg.aa.yyyy" biçimlerini yerel saate çevirir.
DateTime? _parseTime(Object? v) {
  if (v == null) return null;
  if (v is num) return _fromEpoch(v.toDouble());
  if (v is! String) return null;
  final s = v.trim();
  if (s.isEmpty) return null;
  final n = double.tryParse(s);
  if (n != null && RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) {
    if (s.length == 8) return _compact(s);
    if (s.length == 14) return _compact(s);
    return _fromEpoch(n);
  }
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.toLocal();
  final m = RegExp(r'^(\d{1,2})[./](\d{1,2})[./](\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$').firstMatch(s);
  if (m != null) {
    return DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!), int.tryParse(m[4] ?? '') ?? 0,
        int.tryParse(m[5] ?? '') ?? 0, int.tryParse(m[6] ?? '') ?? 0);
  }
  return null;
}

DateTime? _compact(String s) {
  final y = int.parse(s.substring(0, 4)), mo = int.parse(s.substring(4, 6)), d = int.parse(s.substring(6, 8));
  if (y < 1990 || y > 2100 || mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  if (s.length == 8) return DateTime(y, mo, d);
  return DateTime(y, mo, d, int.parse(s.substring(8, 10)), int.parse(s.substring(10, 12)), int.parse(s.substring(12, 14)));
}

DateTime? _fromEpoch(double v) {
  // 1e11 ms ~ 1973, 1e11 sn ~ yıl 5138: ayrım güvenli.
  int ms;
  if (v >= 1e11) {
    ms = v.round();
  } else if (v >= 9.5e8) {
    ms = (v * 1000).round();
  } else {
    return null;
  }
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  if (t.year < 2005 || t.year > 2100) return null;
  return t;
}

Object? _tryJson(String s) {
  final t = s.trimLeft();
  if (!(t.startsWith('{') || t.startsWith('['))) return null;
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

/// Tek JSON, ya da satır satır JSON (JSONL), ya da başında BOM olan dosya.
List<Object?> _decodeJsonDocs(String text) {
  final t = text.replaceFirst('﻿', '').trim();
  if (t.isEmpty) return const [];
  try {
    return [jsonDecode(t)];
  } catch (_) {
    final out = <Object?>[];
    for (final line in const LineSplitter().convert(t)) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        out.add(jsonDecode(l));
      } catch (_) {}
    }
    return out;
  }
}

class _Csv {
  _Csv(this.header, this.rows);
  final List<String> header;
  final List<Map<String, Object?>> rows;
}

_Csv _readCsv(String text) {
  final lines = const LineSplitter().convert(text.replaceFirst('﻿', '')).where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return _Csv(const [], const []);
  final first = lines.first;
  final delim = [',', ';', '\t'].reduce((a, b) => first.split(a).length >= first.split(b).length ? a : b);
  List<String> split(String l) => [for (final c in _splitCsvLine(l, delim)) c.trim()];
  final header = split(first);
  final rows = <Map<String, Object?>>[];
  for (final l in lines.skip(1)) {
    final cells = split(l);
    rows.add({for (var i = 0; i < header.length && i < cells.length; i++) header[i]: cells[i]});
  }
  return _Csv(header, rows);
}

List<String> _splitCsvLine(String line, String d) {
  final out = <String>[];
  final cur = StringBuffer();
  var q = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (q && i + 1 < line.length && line[i + 1] == '"') {
        cur.write('"');
        i++;
      } else {
        q = !q;
      }
    } else if (ch == d && !q) {
      out.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  out.add(cur.toString());
  return out;
}
