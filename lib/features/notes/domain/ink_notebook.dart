import 'page_template.dart';

/// Kalemli defter (T6). Anlık not ve ders notundan ayrıdır.
class InkNotebookRecord {
  const InkNotebookRecord({
    required this.id,
    required this.title,
    required this.coverColor,
    required this.defaultTemplate,
    required this.sortOrder,
    required this.pageCount,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
    this.folderId,
  });

  final String id;
  final String title;

  /// Defterin klasörü (v23); null = kökte.
  final String? folderId;
  final int coverColor;
  final PageTemplate defaultTemplate;
  final int sortOrder;

  /// Silinmemiş sayfa sayısı.
  final int pageCount;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Defter sayfası. Çizgileri: `NotePageOwner(id, pageNo)` (bkz. `ink_note_pages` belgesi).
class InkNotePageRecord {
  const InkNotePageRecord({
    required this.id,
    required this.notebookId,
    required this.pageNo,
    required this.sortOrder,
    required this.template,
    required this.width,
    required this.height,
    required this.background,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
    this.title,
    this.konuId,
    this.parentPageId,
    this.boardX,
    this.boardY,
    this.boardW,
    this.boardH,
  });

  final String id;
  final String notebookId;

  /// Sayfa başlığı (v23); null = başlıksız.
  final String? title;

  /// Bağlı MEB konusu (`curriculum_nodes.id`); null = bağsız.
  final String? konuId;

  /// Alt sayfaysa ebeveyn sayfa.
  final String? parentPageId;

  /// Pano konumu ve kart boyutu (null: yerleşmemiş / varsayılan boyut).
  final double? boardX;
  final double? boardY;
  final double? boardW;
  final double? boardH;

  /// Değişmeyen numara: `ink_strokes.notePage` bunu taşır.
  final int pageNo;
  final int sortOrder;
  final PageTemplate template;
  final double width;
  final double height;
  final int background;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// A4 oranında varsayılan sayfa boyutu (not koordinatı).
const defaultPageWidth = 1404.0;
const defaultPageHeight = 1984.0;
