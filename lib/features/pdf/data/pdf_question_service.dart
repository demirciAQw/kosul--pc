import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/media/media_storage.dart';
import '../../../core/utils/id_generator.dart';
import '../../curriculum/domain/curriculum.dart';
import '../../library/domain/library.dart';
import '../../ocr/domain/auto_tags.dart';
import '../../ocr/domain/ocr.dart';
import '../../ocr/domain/question_text.dart';
import '../../question_bank/domain/question_bank.dart';
import '../../question_bank/domain/question_card.dart';
import '../../question_bank/domain/srs.dart';
import '../domain/pdf_document_record.dart';
import '../domain/pdf_engine.dart';
import '../domain/question_box.dart';
import 'pdf_preview_encoder.dart';

/// Bir soru kutusunun incelemesi: metin, kaynağı ve öneriler.
class BoxAnalysis {
  const BoxAnalysis({
    required this.source,
    required this.suggestion,
    this.lines = const [],
  });
  final BoxTextSource source;
  final BoxSuggestion suggestion;
  final List<OcrLine> lines;
  String get text => suggestion.text;
}

/// "Soru seç" araçının veri tarafı: kutuyu inceler (metin katmanı ya da ML Kit),
/// önizleme üretir ve kartı kaydeder.
class PdfQuestionService {
  PdfQuestionService({
    required this.engine,
    required this.cards,
    required this.media,
    required this.ids,
    required this.clock,
    required this.tempDir,
    required this.lexicon,
    this.ocr,
    this.ocrRepository,
    this.ocrEngineVersion = 'kocum-okuyucu-2.2',
  });

  final PdfEngine engine;
  final QuestionCardRepository cards;
  final MediaStorage media;
  final IdGenerator ids;
  final Clock clock;
  final Directory tempDir;
  final Future<TopicLexicon> Function() lexicon;

  /// ML Kit; yalnızca Android'de verilir. Yoksa taranmış PDF kutusu metinsiz kaydedilir.
  final OcrEngine? ocr;

  /// Varsa metin okuma kaydı da yazılır: otomatik etiketler fotoğraf akışıyla aynı çalışır.
  final OcrRepository? ocrRepository;
  final String ocrEngineVersion;

  static const previewWidth = 480;
  static const ocrWidth = 1400;

  /// Kutunun metnini alır; yoksa (ve ML Kit varsa) sayfa resminden okur; öneri üretir.
  Future<BoxAnalysis> analyze(
    String pdfPath,
    int page,
    PdfBox box, {
    String? subject,
    String examType = 'TYT',
    List<CurriculumNode> curriculum = const [],
  }) async {
    final doc = await engine.openFile(pdfPath);
    try {
      var text = '';
      try {
        text = await doc.textInBox(page, box);
      } catch (_) {
        text = '';
      }
      var source = decideBoxTextSource(text, ocrAvailable: ocr != null);
      var lines = const <OcrLine>[];
      if (source == BoxTextSource.ocr) {
        try {
          lines = await _ocrBox(doc, page, box);
          text = lines.map((l) => l.text).join('\n');
          if (!hasEnoughBoxText(text)) source = BoxTextSource.none;
        } catch (_) {
          source = BoxTextSource.none;
          text = '';
        }
      }
      if (source == BoxTextSource.none) text = '';
      final suggestion = text.isEmpty
          ? const BoxSuggestion()
          : suggestFromBoxText(
              text,
              lexicon: await lexicon(),
              subject: subject,
              examType: examType,
              curriculum: curriculum,
            );
      return BoxAnalysis(source: source, suggestion: suggestion, lines: lines);
    } finally {
      await doc.close();
    }
  }

  Future<List<OcrLine>> _ocrBox(
    PdfEngineDocument doc,
    int page,
    PdfBox box,
  ) async {
    final crop = await _crop(doc, page, box, ocrWidth);
    final png = await encodePreview(crop.rgba, crop.width, crop.height);
    final file = File(
      p.join(
        tempDir.path,
        'kocum_pdfocr_${clock().microsecondsSinceEpoch}${png.extension}',
      ),
    );
    try {
      await file.writeAsBytes(png.bytes, flush: true);
      return await ocr!.recognize(file.path);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  /// Kutuyu sayfadan kırpılmış RGBA olarak verir.
  Future<({Uint8List rgba, int width, int height})> _crop(
    PdfEngineDocument doc,
    int page,
    PdfBox box,
    int targetWidth,
  ) async {
    final size = await doc.pageSize(page);
    final plan = planBoxRender(size, box, targetWidth);
    final img = await doc.renderPage(
      page,
      width: plan.renderWidth,
      height: plan.renderHeight,
    );
    final out = Uint8List(plan.cropWidth * plan.cropHeight * 4);
    final bgra = img.format == PdfPixelFormat.bgra;
    var o = 0;
    for (var y = 0; y < plan.cropHeight; y++) {
      var i = ((plan.cropY + y) * img.width + plan.cropX) * 4;
      for (var x = 0; x < plan.cropWidth; x++) {
        out[o] = img.bytes[bgra ? i + 2 : i];
        out[o + 1] = img.bytes[i + 1];
        out[o + 2] = img.bytes[bgra ? i : i + 2];
        out[o + 3] = 255;
        o += 4;
        i += 4;
      }
    }
    return (rgba: out, width: plan.cropWidth, height: plan.cropHeight);
  }

  /// Önizlemeyi üretir, kalıcı depoya alır, kartı (ve varsa okuma kaydını) yazar.
  /// Hata olursa depoya alınan dosya geri silinir.
  Future<QuestionCard> save({
    required PdfDocumentRecord document,
    required String pdfPath,
    required int page,
    required PdfBox box,
    required QuestionStatus status,
    required String subject,
    BoxAnalysis? analysis,
    Book? book,
    String? topicText,
    String? mebNodeId,
  }) async {
    final context = book == null
        ? null
        : bookContextForPage(book, document.bookPageOf(page));
    String? stored;
    File? tempFile;
    try {
      final doc = await engine.openFile(pdfPath);
      final EncodedPreview preview;
      try {
        final crop = await _crop(doc, page, box, previewWidth);
        preview = await encodePreview(crop.rgba, crop.width, crop.height);
      } finally {
        await doc.close();
      }
      tempFile = File(
        p.join(
          tempDir.path,
          'kocum_pdfkutu_${clock().microsecondsSinceEpoch}${preview.extension}',
        ),
      );
      await tempFile.writeAsBytes(preview.bytes, flush: true);
      stored = await media.importFile(tempFile.path, bucket: 'questions');

      final now = clock();
      final s = analysis?.suggestion;
      final card = QuestionCard(
        id: ids.next(),
        status: status,
        origin: context == null
            ? QuestionOrigin.independent
            : QuestionOrigin.book,
        questionImage: stored,
        sourceName: context?.sourceName ?? document.title,
        bookId: context?.bookId,
        contentNodeId: context?.contentNodeId,
        // Kitap haritası kesindir; yoksa (kullanıcı düzeltmediyse) önerilen MEB konusu.
        mebNodeId: context?.mebNodeId ?? mebNodeId,
        subject: subject,
        topicText: (topicText?.trim().isEmpty ?? true)
            ? null
            : topicText!.trim(),
        difficulty: 5,
        createdAt: now,
        questionNo: s?.questionNo,
        testLabel: context?.testLabel,
        pdfDocumentId: document.id,
        pdfPage: page,
        pdfBox: box,
      );
      await cards.insert(
        card,
        review: status == QuestionStatus.correct
            ? null
            : ReviewState.initial(now),
      );
      final repo = ocrRepository;
      if (repo != null && analysis != null && analysis.text.isNotEmpty) {
        final lines = analysis.lines.isNotEmpty
            ? analysis.lines
            : linesFromPlainText(analysis.text);
        // Kart yazıldı: okuma kaydı yazılamazsa kart ve önizleme yine kalır
        // (arka plan okuyucusu fotoğraftan yeniden okur).
        try {
          await repo.save(
            OcrRecord(
              id: OcrJob.questionId(card.id),
              ownerType: 'question',
              ownerId: card.id,
              imagePath: stored,
              status: 'done',
              processedAt: now,
              fullText: analysis.text,
              parsed: ParsedQuestion(
                stem: analysis.text,
                number: s?.questionNo,
              ),
              lines: lines,
              engine: ocrEngineVersion,
              structure: const {'source': 'pdf', 'figures': []},
            ),
          );
        } catch (_) {}
      }
      return card;
    } catch (_) {
      if (stored != null) await media.delete(stored);
      rethrow;
    } finally {
      if (tempFile != null && await tempFile.exists()) await tempFile.delete();
    }
  }
}
