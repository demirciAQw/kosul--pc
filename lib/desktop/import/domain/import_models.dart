/// Bir tablonun birleştirme sonucu.
class TableMerge {
  const TableMerge({
    required this.table,
    required this.total,
    required this.added,
    required this.updated,
    this.missingIds = const [],
  });

  final String table; // SQL adı: "question_cards"
  final int total; // telefondaki satır sayısı
  final int added;
  final int updated;

  /// Bilgisayarda olup telefon kopyasında olmayan kayıtlar ("telefonda silindi").
  final List<String> missingIds;

  Map<String, Object?> toJson() =>
      {'table': table, 'total': total, 'added': added, 'updated': updated, 'missing': missingIds.length};

  factory TableMerge.fromJson(Map<String, Object?> j) => TableMerge(
        table: j['table'] as String,
        total: (j['total'] as num?)?.toInt() ?? 0,
        added: (j['added'] as num?)?.toInt() ?? 0,
        updated: (j['updated'] as num?)?.toInt() ?? 0,
        // Geçmişte yalnızca sayı tutulur.
        missingIds: List.filled((j['missing'] as num?)?.toInt() ?? 0, ''),
      );
}

/// Bir içe aktarmanın özeti (Ayarlar'daki geçmişte de durur).
class ImportSummary {
  const ImportSummary({
    required this.at,
    required this.source,
    this.exportedAt,
    required this.tables,
    this.photosAdded = 0,
    this.photosSkipped = 0,
    this.photosRejected = 0,
    this.automatic = false,
    this.warnings = const [],
  });

  final DateTime at;
  final String source; // dosya ya da klasör adı
  final DateTime? exportedAt; // yedeğin telefonda alındığı an
  final List<TableMerge> tables;
  final int photosAdded;
  final int photosSkipped; // zaten vardı
  final int photosRejected; // güvensiz yol
  final bool automatic; // izlenen klasörden
  final List<String> warnings; // içe aktarmayı durdurmayan sorunlar (ör. koç klasörü yazılamadı)

  TableMerge? table(String name) {
    for (final t in tables) {
      if (t.table == name) return t;
    }
    return null;
  }

  int get totalAdded => tables.fold(0, (s, t) => s + t.added);
  int get totalUpdated => tables.fold(0, (s, t) => s + t.updated);
  int get totalMissing => tables.fold(0, (s, t) => s + t.missingIds.length);
  bool get hasChanges => totalAdded + totalUpdated + photosAdded > 0;

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'source': source,
        if (exportedAt != null) 'exportedAt': exportedAt!.toIso8601String(),
        'tables': [for (final t in tables) t.toJson()],
        'photosAdded': photosAdded,
        'photosSkipped': photosSkipped,
        'photosRejected': photosRejected,
        'automatic': automatic,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };

  factory ImportSummary.fromJson(Map<String, Object?> j) => ImportSummary(
        at: DateTime.parse(j['at'] as String),
        source: j['source'] as String? ?? '',
        exportedAt: j['exportedAt'] == null ? null : DateTime.tryParse(j['exportedAt'] as String),
        tables: [
          for (final t in (j['tables'] as List? ?? const []))
            if (t is Map) TableMerge.fromJson(t.cast<String, Object?>()),
        ],
        photosAdded: (j['photosAdded'] as num?)?.toInt() ?? 0,
        photosSkipped: (j['photosSkipped'] as num?)?.toInt() ?? 0,
        photosRejected: (j['photosRejected'] as num?)?.toInt() ?? 0,
        automatic: j['automatic'] == true,
        warnings: [for (final w in (j['warnings'] as List? ?? const [])) '$w'],
      );
}

/// Telefonda silinmiş ama bilgisayarda duran kayıt; kullanıcı elle siler.
class Tombstone {
  const Tombstone({required this.table, required this.id, required this.since});

  final String table;
  final String id;
  final DateTime since; // ilk fark edildiği içe aktarma

  String get key => '$table/$id';

  Map<String, Object?> toJson() => {'table': table, 'id': id, 'since': since.toIso8601String()};

  factory Tombstone.fromJson(Map<String, Object?> j) => Tombstone(
        table: j['table'] as String,
        id: j['id'] as String,
        since: DateTime.tryParse(j['since'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  bool operator ==(Object other) => other is Tombstone && other.key == key && other.since == since;

  @override
  int get hashCode => Object.hash(key, since);
}

/// Tabloların insan dilindeki adları (özet ve "Telefonda silinenler" için),
/// önem sırasına göre.
const tableLabels = <String, String>{
  'question_cards': 'Sorular',
  'mock_exams': 'Denemeler',
  'mock_exam_sections': 'Deneme dersleri',
  'study_sessions': 'Oturumlar',
  'session_items': 'Oturum maddeleri',
  'books': 'Kitaplar',
  'content_nodes': 'Kitap bölümleri ve testler',
  'test_results': 'Test sonuçları',
  'study_plans': 'Planlar',
  'plan_tasks': 'Plan görevleri',
  'study_notes': 'Notlar',
  'note_photos': 'Not fotoğrafları',
  'review_states': 'Tekrar durumları',
  'ocr_results': 'Fotoğraftan okunan metinler',
  'curriculum_nodes': 'MEB konuları',
};

String tableLabel(String table) => tableLabels[table] ?? table;

/// Ekranda gösterilecek "telefonda silindi" kaydı.
class TombstoneView {
  const TombstoneView(this.tombstone, this.label);
  final Tombstone tombstone;
  final String label;
}
