// Tablolar yalnızca ilkel tipler kullanır; enum'lar `.name` olarak metin
// saklanır ve eşleme her özelliğin data katmanında yapılır. Böylece core,
// hiçbir özelliğin domain'ine bağımlı olmaz.
import 'package:drift/drift.dart';

import 'converters.dart';

// ───────────────────────── Kaynaklar ─────────────────────────

@DataClassName('BookRow')
class Books extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get publisher => text().nullable()();
  TextColumn get examType => text()(); // TYT | AYT | YDT
  TextColumn get subject => text()();
  IntColumn get pageCount => integer()();
  RealColumn get avgQuestionsPerPage => real()();
  TextColumn get templateAuthor => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Kitap içindekiler ağacı (Ünite → Konu → Alt konu), adjacency list.
@DataClassName('ContentNodeRow')
@TableIndex(name: 'ix_content_nodes_book_parent', columns: {#bookId, #parentId})
class ContentNodes extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get parentId => text().nullable()();
  TextColumn get level => text()(); // unit | topic | subtopic
  TextColumn get title => text()();
  IntColumn get pageStart => integer().nullable()();
  IntColumn get pageEnd => integer().nullable()();
  IntColumn get sortOrder => integer()();
  TextColumn get mebNodeId =>
      text().nullable().references(CurriculumNodes, #id, onDelete: KeyAction.setNull)();
  RealColumn get mebMatchScore => real().nullable()();

  /// Şablonda verilmişse testteki kesin soru sayısı (v3). Optik form bununla açılır.
  IntColumn get questionCount => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// MEB Standart Kazanım Ağacı (asset'ten tohumlanır, upsert ile güncellenir).
@DataClassName('CurriculumNodeRow')
@TableIndex(name: 'ix_curriculum_subject', columns: {#examType, #subject})
class CurriculumNodes extends Table {
  TextColumn get id => text()(); // kalıcı anahtar: "tyt.mat.problemler.yas"
  TextColumn get parentId => text().nullable()();
  TextColumn get examType => text()();
  TextColumn get subject => text()();
  TextColumn get title => text()();
  TextColumn get aliases => text().map(const StringListConverter())();
  IntColumn get depth => integer()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

// ───────────────────────── Planlama ─────────────────────────

/// Tarih aralıklı görev havuzu (günlük program dayatmaz).
@DataClassName('StudyPlanRow')
class StudyPlans extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get startsOn => dateTime()();
  DateTimeColumn get endsOn => dateTime()();
  DateTimeColumn get createdAt => dateTime()();

  /// "Tamamladım" işareti (v3). Null = sürüyor.
  DateTimeColumn get completedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['CHECK (ends_on >= starts_on)'];
}

@DataClassName('PlanTaskRow')
@TableIndex(name: 'ix_plan_tasks_plan', columns: {#planId})
class PlanTasks extends Table {
  TextColumn get id => text()();
  TextColumn get planId => text().references(StudyPlans, #id, onDelete: KeyAction.cascade)();
  TextColumn get bookId => text().nullable().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get contentNodeId =>
      text().nullable().references(ContentNodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  IntColumn get targetQuestions => integer().nullable()();
  BoolColumn get isDone => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

// ───────────────────────── Çalışma oturumları ─────────────────────────

/// Süre `startedAt` damgasından hesaplanır; sayaç asla "tick" saklamaz.
/// Bu yüzden uygulama öldürülse, telefon yeniden başlasa bile süre kaybolmaz.
@DataClassName('StudySessionRow')
class StudySessions extends Table {
  TextColumn get id => text()();
  TextColumn get status => text()(); // running | awaitingResults | completed
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get planId =>
      text().nullable().references(StudyPlans, #id, onDelete: KeyAction.setNull)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SessionItemRow')
@TableIndex(name: 'ix_session_items_session', columns: {#sessionId})
class SessionItems extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId =>
      text().references(StudySessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get bookId => text().nullable().references(Books, #id, onDelete: KeyAction.setNull)();
  TextColumn get contentNodeId =>
      text().nullable().references(ContentNodes, #id, onDelete: KeyAction.setNull)();
  TextColumn get mebNodeId => text().nullable()(); // analiz için anlık görüntü
  TextColumn get label => text()(); // anlık görüntü: kitap silinse de geçmiş okunur kalır
  TextColumn get pages => text().map(const IntListConverter())();
  IntColumn get estimatedQuestions => integer().nullable()();
  IntColumn get correct => integer().nullable()();
  IntColumn get wrong => integer().nullable()();
  IntColumn get blank => integer().nullable()();
  IntColumn get sortOrder => integer()();

  /// "TYT Matematik". Kitapsız oturumlarda dersin tek kaynağı (v2).
  TextColumn get subject => text().nullable()();

  /// questions | lecture | video | review | other. Kitaplı bloklarda null = soru çözümü (v2).
  TextColumn get activity => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ───────────────────────── Hata / Boş / GK defteri ─────────────────────────

@DataClassName('QuestionCardRow')
@TableIndex(name: 'ix_cards_subject_meb', columns: {#subject, #mebNodeId})
@TableIndex(name: 'ix_cards_created', columns: {#createdAt})
@TableIndex(name: 'ix_cards_starred', columns: {#isStarred})
class QuestionCards extends Table {
  TextColumn get id => text()();
  TextColumn get status => text()(); // wrong | blank | correct
  TextColumn get origin => text()(); // book | independent | mockExam

  /// Medya köküne göre GÖRELİ yol. v2'den itibaren isteğe bağlı: fotoğrafsız
  /// "hızlı" kartlar Eksikler listesinde tamamlanmayı bekler.
  TextColumn get questionImage => text().nullable()();
  TextColumn get solutionImage => text().nullable()();
  TextColumn get solutionText => text().nullable()();
  TextColumn get sourceName => text()();
  TextColumn get bookId => text().nullable().references(Books, #id, onDelete: KeyAction.setNull)();
  TextColumn get contentNodeId =>
      text().nullable().references(ContentNodes, #id, onDelete: KeyAction.setNull)();
  TextColumn get sessionId =>
      text().nullable().references(StudySessions, #id, onDelete: KeyAction.setNull)();
  TextColumn get mebNodeId =>
      text().nullable().references(CurriculumNodes, #id, onDelete: KeyAction.setNull)();
  TextColumn get subject => text()(); // "TYT Matematik" (hızlı filtre için denormalize)
  IntColumn get testTotalQuestions => integer().nullable()();
  TextColumn get reason => text().nullable()();

  /// "Diğer" nedeni seçildiğinde kullanıcının kendi açıklaması (v4).
  TextColumn get reasonNote => text().nullable()();

  /// Serbest konu/kazanım adı (v5): karneden gelen "ÖZDEŞLİKLER" gibi. MEB
  /// listesinde karşılığı olmasa da analizde konu olarak sayılır.
  TextColumn get topicText => text().nullable()();

  /// Şıklar (v8): sorunun doğru cevabı ve öğrencinin işaretlediği ("A"–"E").
  TextColumn get correctAnswer => text().nullable()();
  TextColumn get givenAnswer => text().nullable()();
  RealColumn get avgSecondsPerQuestion => real().nullable()();
  IntColumn get difficulty => integer()();
  BoolColumn get isStarred => boolean().withDefault(const Constant(false))();
  TextColumn get note => text().nullable()();
  TextColumn get searchText => text()(); // normalizeTr ile katlanmış arama metni
  DateTimeColumn get createdAt => dateTime()();

  // ── v2: "testin 7. sorusu" ile hızlı kayıt ──
  IntColumn get questionNo => integer().nullable()();

  /// Anlık görüntü: "Problemler › Yaş Problemleri – Kavrama" (kitap silinse de okunur kalır).
  TextColumn get testLabel => text().nullable()();
  TextColumn get sessionItemId =>
      text().nullable().references(SessionItems, #id, onDelete: KeyAction.setNull)();
  TextColumn get mockExamId =>
      text().nullable().references(MockExams, #id, onDelete: KeyAction.setNull)();

  // ── v17: soru = PDF koordinatı (tablet). Hepsi boşsa kart PDF'siz. ──
  /// `pdf_documents.id` (= sha256). Bağ yalnızca bilgidir: PDF bu cihazda
  /// olmayabilir, satır silinse de kart önizlemesiyle yaşar (yabancı anahtar yok).
  TextColumn get pdfDocumentId => text().nullable()();

  /// Sayfa, 0'dan (`ink_strokes.pdfPage` ile aynı).
  IntColumn get pdfPage => integer().nullable()();

  /// Kutu: sayfa birimi (1/72 inç), döndürülmüş sayfa, sol-üst başlangıç, y aşağı.
  RealColumn get pdfBoxLeft => real().nullable()();
  RealColumn get pdfBoxTop => real().nullable()();
  RealColumn get pdfBoxRight => real().nullable()();
  RealColumn get pdfBoxBottom => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  // v1'deki "doğru çözüm zorunlu" kuralı kaldırıldı: çözüm artık isteğe bağlı,
  // eksik kartlar Eksikler listesinde bekler.
  @override
  List<String> get customConstraints => ['CHECK (difficulty BETWEEN 1 AND 10)'];
}

/// SM-2 aralıklı tekrar durumu (kartla 1:1, ayrı tablo: zamanlayıcı değişirse
/// soru verisine dokunmadan yeni algoritmaya geçilebilir).
@DataClassName('ReviewStateRow')
@TableIndex(name: 'ix_review_due', columns: {#dueAt})
class ReviewStates extends Table {
  TextColumn get cardId => text().references(QuestionCards, #id, onDelete: KeyAction.cascade)();
  RealColumn get easeFactor => real()();
  IntColumn get intervalDays => integer()();
  IntColumn get repetitions => integer()();
  DateTimeColumn get dueAt => dateTime()();
  DateTimeColumn get lastReviewedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {cardId};
}

// ───────────────────────── Ders notları (v7) ─────────────────────────

/// Defterdeki serbest notlar: her not bir derse ("TYT Matematik") bağlıdır;
/// yazıldığı tarih ve saat kendiliğinden kaydedilir.
@DataClassName('StudyNoteRow')
class StudyNotes extends Table {
  TextColumn get id => text()();
  TextColumn get subject => text()();
  TextColumn get title => text().nullable()();
  TextColumn get body => text()();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Notun sayfa fotoğrafları (v9): el yazısı defter sayfaları, sırayla.
/// Asıl görüntü her zaman saklanır; ileride okunan metin bunun üstüne eklenir.
@DataClassName('NotePhotoRow')
class NotePhotos extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text().references(StudyNotes, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()(); // medya köküne göre göreli
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Fotoğraftaki metin (v10): ML Kit ile telefonda okunur. Her kayıt bir
/// fotoğrafa (soru, çözüm ya da not sayfası) bağlıdır; fotoğraf değişirse
/// yeniden okunur. Soru kökü ve şıklar ayrıştırılmış olarak da saklanır.
@DataClassName('OcrRow')
class OcrResults extends Table {
  /// "question:<kart>", "solution:<kart>" ya da "note:<not>:<sıra>".
  TextColumn get id => text()();
  TextColumn get ownerType => text()(); // question | solution | note
  TextColumn get ownerId => text()();
  TextColumn get imagePath => text()(); // okunan fotoğraf (değişirse yeniden okunur)
  TextColumn get status => text()(); // done | failed
  TextColumn get fullText => text().withDefault(const Constant(''))();
  TextColumn get stem => text().nullable()(); // soru kökü
  TextColumn get optionsJson => text().nullable()(); // {"A": "...", ...}
  IntColumn get detectedNumber => integer().nullable()();
  TextColumn get linesJson => text().nullable()(); // satırlar ve konumları
  TextColumn get engine => text().withDefault(const Constant('mlkit-latin'))();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get error => text().nullable()();
  TextColumn get structureJson => text().nullable()(); // v11: sayfa yapısı ve şekiller
  DateTimeColumn get processedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// ───────────────────────── Kitap ilerlemesi (v4) ─────────────────────────

/// Bir testin (ya da kitap ağacındaki bir yaprak başlığın) çözüldü kaydı.
/// Satır yoksa çözülmedi. Sayılar optikten gelir; elle işaretlemede boş kalır.
@DataClassName('TestResultRow')
class TestResults extends Table {
  TextColumn get contentNodeId => text().references(ContentNodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get bookId => text().references(Books, #id, onDelete: KeyAction.cascade)();
  IntColumn get correct => integer().nullable()();
  IntColumn get wrong => integer().nullable()();
  IntColumn get blank => integer().nullable()();
  IntColumn get total => integer().nullable()();
  DateTimeColumn get solvedAt => dateTime()();
  TextColumn get sessionId => text().nullable()();

  @override
  Set<Column> get primaryKey => {contentNodeId};
}

// ───────────────────────── Deneme sınavları (v2) ─────────────────────────

@DataClassName('MockExamRow')
class MockExams extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get kind => text()(); // tyt | ayt | ydt | branch
  DateTimeColumn get takenOn => dateTime()();
  IntColumn get durationMinutes => integer().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Denemenin ders bölümleri: "TYT Matematik, 40 soru, 28 D, 6 Y, 6 B".
@DataClassName('MockExamSectionRow')
class MockExamSections extends Table {
  TextColumn get id => text()();
  TextColumn get examId => text().references(MockExams, #id, onDelete: KeyAction.cascade)();
  TextColumn get subject => text()(); // "TYT Matematik"
  IntColumn get questionCount => integer()();
  IntColumn get correct => integer()();
  IntColumn get wrong => integer()();
  IntColumn get blank => integer()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
        'CHECK (correct >= 0 AND wrong >= 0 AND blank >= 0)',
        'CHECK (correct + wrong + blank <= question_count)',
      ];
}

/// Küçük anahtar-değer deposu (tohum veri sürümü, ayarlar…).
@DataClassName('AppMetaRow')
class AppMeta extends Table {
  TextColumn get metaKey => text()();
  TextColumn get metaValue => text()();

  @override
  Set<Column> get primaryKey => {metaKey};
}

// ───────────── Anlık notlar, ortak etiketler, kişiler (v12) ─────────────

/// Anlık not (v12): bir kelimeden bir sayfaya. Ders notundan (StudyNotes)
/// ayrıdır. `kind`: anlik | uyku_yattim | uyku_kalktim.
@DataClassName('AnlikNoteRow')
class AnlikNotes extends Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get body => text()();
  TextColumn get kind => text().withDefault(const Constant('anlik'))();
  IntColumn get mood => integer().nullable()(); // 1–5
  TextColumn get searchText => text().withDefault(const Constant(''))(); // normalizeTr
  TextColumn get subject => text().nullable()();
  TextColumn get mebNodeId => text().nullable()();
  TextColumn get topicText => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Not: bu Drift sürümü `references(...)` kuralını SQL'e yazmıyor; v12 tablolarında
/// yabancı anahtar `customConstraint` ile açıkça verilir (CASCADE çalışsın).
/// Ortak etiket (v12): notlarda ve soru kartlarında. `name` normalizeTr ile
/// benzersiz anahtardır, `label` görünen addır. `parentId`: üst etiket.
/// `source`: ben | claude | otomatik.
@DataClassName('TagRow')
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().unique()();
  TextColumn get label => text()();
  TextColumn get parentId => text().nullable().customConstraint('REFERENCES tags(id) ON DELETE SET NULL')();
  TextColumn get source => text().withDefault(const Constant('ben'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AnlikNoteTagRow')
class AnlikNoteTags extends Table {
  /// "<noteId>:<tagId>": tek sütunlu anahtar (birleştirme ve defter için).
  TextColumn get id => text()();
  TextColumn get noteId => text().customConstraint('NOT NULL REFERENCES anlik_notes(id) ON DELETE CASCADE')();
  TextColumn get tagId => text().customConstraint('NOT NULL REFERENCES tags(id) ON DELETE CASCADE')();
  TextColumn get source => text().withDefault(const Constant('ben'))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {noteId, tagId},
      ];
}

@DataClassName('QuestionCardTagRow')
class QuestionCardTags extends Table {
  /// "<cardId>:<tagId>": tek sütunlu anahtar (birleştirme ve defter için).
  TextColumn get id => text()();
  TextColumn get cardId => text().customConstraint('NOT NULL REFERENCES question_cards(id) ON DELETE CASCADE')();
  TextColumn get tagId => text().customConstraint('NOT NULL REFERENCES tags(id) ON DELETE CASCADE')();
  TextColumn get source => text().withDefault(const Constant('ben'))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {cardId, tagId},
      ];
}

/// Kişiler (v12). `aliases`: aynı kişinin diğer adları (JSON listesi).
@DataClassName('PersonRow')
class People extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get aliases => text().withDefault(const Constant('[]')).map(const StringListConverter())();
  TextColumn get about => text().withDefault(const Constant(''))(); // "sınıf arkadaşı"
  TextColumn get source => text().withDefault(const Constant('ben'))(); // ben | claude
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AnlikNotePersonRow')
class AnlikNotePeople extends Table {
  /// "<noteId>:<personId>": tek sütunlu anahtar (birleştirme ve defter için).
  TextColumn get id => text()();
  TextColumn get noteId => text().customConstraint('NOT NULL REFERENCES anlik_notes(id) ON DELETE CASCADE')();
  TextColumn get personId => text().customConstraint('NOT NULL REFERENCES people(id) ON DELETE CASCADE')();
  TextColumn get source => text().withDefault(const Constant('ben'))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {noteId, personId},
      ];
}

/// Nottan nota ya da soru kartına bağ (v12). Biri dolu, öbürü boş.
@DataClassName('AnlikLinkRow')
class AnlikLinks extends Table {
  TextColumn get id => text()();
  TextColumn get fromNoteId => text().customConstraint('NOT NULL REFERENCES anlik_notes(id) ON DELETE CASCADE')();
  TextColumn get toNoteId => text().nullable().customConstraint('REFERENCES anlik_notes(id) ON DELETE CASCADE')();
  TextColumn get toCardId => text().nullable().customConstraint('REFERENCES question_cards(id) ON DELETE CASCADE')();
  TextColumn get source => text().withDefault(const Constant('ben'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// ───────────── Değişiklik defteri ve senkron (v13) ─────────────

/// Her kullanıcı verisi değişikliği, SQLite tetikleyicileriyle buraya yazılır.
/// Telefon ve bilgisayar birbirinin satırlarını alır; Claude'un değişiklikleri
/// geri alınabilir. `eski` ve `yeni`: satırın tamamı (JSON); biri boş olabilir.
@DataClassName('DegisiklikRow')
class Degisiklikler extends Table {
  /// Yerel sıra: bu cihazdaki ekleniş sırası (karşıya "gördüğüm son sıra" için).
  IntColumn get yerelSira => integer().autoIncrement()();
  TextColumn get id => text().unique()(); // uuid benzeri; iki cihazda aynıdır
  TextColumn get cihazId => text()(); // değişikliği yapan cihaz
  /// telefon | pc | claude | senkron | geri_al
  TextColumn get kaynak => text()();
  TextColumn get oturumId => text().nullable()();
  TextColumn get tablo => text()();
  TextColumn get satirId => text()();
  TextColumn get islem => text()(); // ekle | degistir | sil
  TextColumn get eski => text().nullable()();
  TextColumn get yeni => text().nullable()();
  /// Hibrit mantıksal saat (bkz. core/ledger/hlc.dart).
  TextColumn get saat => text()();

  /// Karşı cihazdan geldi: geri gönderilmez.
  BoolColumn get uzak => boolean().withDefault(const Constant(false))();

  /// Bu değişikliği geri alan değişikliğin kimliği (geri alma kaydında dolu:
  /// "şu değişiklik geri alındı" bilgisi).
  TextColumn get geriAlinan => text().nullable()();

}

/// Tek satırlık bağlam: tetikleyiciler yazanın kim olduğunu ve saati buradan
/// alır. Dışarıdan yazan araçlar (kocum aracı) işlemden önce burayı doldurur.
@DataClassName('BaglamRow')
class Baglam extends Table {
  @override
  String get tableName => '_baglam';

  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get cihazId => text()();
  TextColumn get kaynak => text().withDefault(const Constant('telefon'))();
  TextColumn get varsayilan => text().withDefault(const Constant('telefon'))();
  TextColumn get oturumId => text().nullable()();

  /// 1: tetikleyiciler yazmaz (senkron uygulaması, yedek birleştirme).
  IntColumn get bastir => integer().withDefault(const Constant(0))();
  IntColumn get hlcMs => integer().withDefault(const Constant(0))();
  IntColumn get hlcN => integer().withDefault(const Constant(0))();

  /// Yalnızca testler: gerçek saat yerine bu değer (ms) kullanılır.
  IntColumn get saatMs => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// İki tarafta da değişen satırın kaybeden sürümü. Silinmez; iki uygulamada
/// da görünür ve istenirse geri alınır.
@DataClassName('CakismaRow')
class Cakismalar extends Table {
  TextColumn get id => text()();
  TextColumn get tablo => text()();
  TextColumn get satirId => text()();
  TextColumn get kazanan => text().nullable()(); // JSON (null: satır silinmişti)
  TextColumn get kaybeden => text().nullable()();

  /// yerel | uzak: kazanan taraf. geri_al: geri alma satırın değişmiş olması yüzünden yapılamadı.
  TextColumn get taraf => text()();
  TextColumn get saat => text()();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get cozuldu => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Senkron imleçleri (anahtar → değer). Bilgisayara ve yedeğe gitmez.
@DataClassName('EsitlemeDurumRow')
class EsitlemeDurum extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Silme önerisi (v14): Claude bir satırı silmez, yalnızca işaretler; kullanıcı
/// iki uygulamadan birinde onaylar ya da reddeder. Senkronlanır.
@DataClassName('SilmeOnerisiRow')
class SilmeOnerileri extends Table {
  TextColumn get id => text()();
  TextColumn get tablo => text()();
  TextColumn get satirId => text()();
  TextColumn get neden => text().withDefault(const Constant(''))();
  TextColumn get oneren => text().withDefault(const Constant('claude'))();
  TextColumn get oturumId => text().nullable()();

  /// bekliyor | onaylandi | reddedildi
  TextColumn get durum => text().withDefault(const Constant('bekliyor'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// ───────────── Çizgi verisi (v15) ─────────────

/// Kalemle çizilmiş tek çizgi (T2). Sahibi ya bir PDF sayfası (`pdfDocumentId` +
/// `pdfPage`) ya da bir not sayfasıdır (`noteId` + `notePage`); koordinatlar
/// sayfa/not koordinatındadır. Belge ve not tabloları sonraki adımlarda
/// gelecek: şimdilik düz metin sütunları (yabancı anahtar yok).
/// `points`: `stroke_codec.dart` ikilisi (delta + zigzag + varint).
/// Silme yumuşaktır (`deleted`): defterle senkronda satır kalır.
@DataClassName('InkStrokeRow')
class InkStrokes extends Table {
  TextColumn get id => text()();
  TextColumn get pdfDocumentId => text().nullable()();
  IntColumn get pdfPage => integer().nullable()();
  TextColumn get noteId => text().nullable()();
  IntColumn get notePage => integer().nullable()();
  IntColumn get layer => integer().withDefault(const Constant(0))();

  /// Çözüm denemesi (1, 2, …); not çizgilerinde 0.
  IntColumn get attemptNo => integer().withDefault(const Constant(0))();

  /// Çözüm çizgisinin ait olduğu soru kartı (T5); not ve sayfa çizgilerinde null.
  TextColumn get questionId => text().nullable()();
  TextColumn get tool => text().withDefault(const Constant('pen'))();
  IntColumn get color => integer().withDefault(const Constant(0xFF000000))(); // ARGB
  RealColumn get width => real().withDefault(const Constant(1.0))();
  IntColumn get startedAtMs => integer()(); // epoch ms
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  BlobColumn get points => blob()();
  IntColumn get pointCount => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// PDF belgeleri (T3). Yalnızca SATIR senkron olur; PDF dosyası olmaz
/// (`<veri klasörü>/pdfs/<sha256>.pdf`, her cihaz kendisi ekler).
/// `id` = `sha256` (CHECK ile zorlanır): iki cihazda aynı PDF aynı satır olur.
/// İki cihaz aynı PDF'i senkrondan ÖNCE ayrı içe aktarırsa iki "ekle" gelir ve
/// defter satırı HLC'si yeni olan sürümle tümden yazar; kaybeden sürüm
/// (kitap bağı, ofset) Çakışmalar'da kalır (geri alınabilir). Alan alan
/// birleştirme yoktur. `ink_strokes.pdfDocumentId` bu kimliği taşır.
/// Kitap sayfa no = pdf sayfa no (1'den) + `pageOffset`. Silme yumuşaktır.
@DataClassName('PdfDocumentRow')
class PdfDocuments extends Table {
  TextColumn get id => text()();
  TextColumn get sha256 => text()();
  TextColumn get title => text().withLength(min: 1, max: 300)();
  IntColumn get pageCount => integer()();
  TextColumn get fileName => text()();
  TextColumn get bookId => text().nullable()();
  IntColumn get pageOffset => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  /// `sha256` ayrı benzersiz değil: defterin `ON CONFLICT(id)` yazımıyla
  /// uyuşmazdı. id = sha256 kuralı burada; bozuk gelen satır uygulanmaz,
  /// defter onu Çakışmalar'a (kaybeden) düşürür, eşitleme takılmaz.
  @override
  List<String> get customConstraints => ['CHECK (id = sha256)'];
}
