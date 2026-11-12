import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../core/database/database_snapshot.dart';
import '../../core/di/core_providers.dart';
import '../library/library_providers.dart';
import '../mock_exam/mock_exam_providers.dart';
import '../notes/domain/notes.dart';
import '../notes/notes_providers.dart';
import '../ocr/ocr_providers.dart';
import '../planning/planning_providers.dart';
import '../question_bank/domain/question_card.dart';
import '../question_bank/question_bank_providers.dart';
import '../study_session/study_session_providers.dart';
import 'data/full_export.dart';

/// Sağlayıcı okuyucu: hem `WidgetRef.read` hem `Ref.read` verilebilir.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Tüm veri yedeğinin içeriği. "Tüm veriyi dışa aktar" bunu ZIP'leyip
/// paylaşır, "Bilgisayara gönder" fotoğrafsız hâlini bilgisayara yollar.
class FullBackup {
  const FullBackup({
    required this.data,
    required this.cards,
    required this.notes,
    required this.extraFiles,
    required this.database,
    required this.databaseError,
  });

  final Map<String, dynamic> data;
  final List<QuestionCard> cards;
  final List<StudyNote> notes;

  /// Uygulamanın tuttuğu veri setleri (arama ve okuma kayıtları).
  final Map<String, List<int>> extraFiles;

  /// Veritabanının birebir kopyası; alınamadıysa null ve [databaseError].
  final List<int>? database;
  final String? databaseError;
}

/// Yedeğin içeriğini toplar. Listeler doğrudan veritabanından (depoların
/// akışının ilk değeri) okunur: o an hiçbir ekran dinlemese ya da sağlayıcı
/// duraklatılmış olsa da yedek eksik çıkmaz.
/// [scratch]: veritabanı kopyası için geçici dosya (iş bitince silinir).
Future<FullBackup> collectFullBackup(
  ProviderReader read, {
  required File scratch,
  bool withDataSets = true,
}) async {
  final now = read(clockProvider)();
  final cards = await read(questionCardRepositoryProvider).watch(const QuestionFilter()).first;
  final notes = await read(noteRepositoryProvider).watchAll().first;
  final data = fullDataJson(
    now: now,
    cards: cards,
    books: await read(libraryRepositoryProvider).watchLibrary().first,
    results: await read(testProgressRepositoryProvider).watchAll().first,
    sessions: await read(studySessionRepositoryProvider).watchHistory(limit: 100000).first,
    exams: await read(mockExamRepositoryProvider).watchAll().first,
    plans: await read(planRepositoryProvider).watchPlans().first,
    notes: notes,
    ocr: [for (final r in (await read(ocrRepositoryProvider).watchAll().first).values) r.toDatasetJson()],
  );
  // Arama veri seti (varsa) de pakete girer.
  final extra = <String, List<int>>{};
  if (withDataSets) {
    final log = await read(searchLogProvider).file();
    final ocrLog = await read(ocrLogProvider).file();
    for (final f in [log, File('${log.path}.1'), ocrLog, File('${ocrLog.path}.1')]) {
      if (await f.exists()) extra['veri/${f.uri.pathSegments.last}'] = await f.readAsBytes();
    }
  }
  // Veritabanının birebir kopyası: bilgisayar uygulaması bununla eksiksiz
  // içe aktarır. Alınamazsa yedek yine çıkar (JSON ve fotoğraflar).
  List<int>? database;
  String? databaseError;
  try {
    database = await databaseSnapshot(read(appDatabaseProvider), scratch);
  } on Exception catch (e) {
    databaseError = '$e';
  }
  return FullBackup(
    data: data,
    cards: cards,
    notes: notes,
    extraFiles: extra,
    database: database,
    databaseError: databaseError,
  );
}
