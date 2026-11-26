import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/core/media/photo_capture_service.dart' show CropOutput;
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/entry/image_tools.dart';
import 'package:kocum/desktop/entry/question_editor.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'e${_n++}';
}

class _FakeMedia implements MediaStorage {
  final imported = <String>[];
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async {
    imported.add(sourcePath);
    return '$bucket/2026/10/${sourcePath.split('/').last}';
  }

  @override
  File resolve(String relativePath) => File('/yok/$relativePath');
  @override
  Future<void> delete(String relativePath) async {}
  @override
  Future<void> discardTemp(String? absolutePath) async {}
}

void main() {
  late AppDatabase db;
  late ProviderContainer c;
  final media = _FakeMedia();

  Future<void> open(WidgetTester tester, {QuestionCard? card, void Function(QuestionCard?)? onResult}) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = AppDatabase(NativeDatabase.memory(), 'pc');
    c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      mediaStorageProvider.overrideWithValue(media),
      idGeneratorProvider.overrideWithValue(_Ids()),
      clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 10)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  final r = await showDesktopQuestionEditor(context, card: card);
                  onResult?.call(r);
                },
                child: const Text('aç'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('aç'));
    await tester.pumpAndSettle();
  }

  Future<void> wait(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
  }

  testWidgets('yeni soru: ders zorunlu; kaydedince kart yazılır; okuma telefonda notu görünür', (tester) async {
    QuestionCard? result;
    await open(tester, onResult: (r) => result = r);
    expect(find.textContaining('okunması telefonda yapılacak'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('soru-kaydet')));
    await tester.pump();
    expect(find.text('Dersi seç.'), findsOneWidget);
    expect(await db.select(db.questionCards).get(), isEmpty);

    await tester.tap(find.byKey(const ValueKey('ders')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TYT Matematik').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('Doğru şık:C')));
    await tester.tap(find.byKey(const ValueKey('İşaretlediğim şık:B')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('soru-kaydet')));
    await wait(tester);

    final row = (await db.select(db.questionCards).get()).single;
    expect((row.subject, row.status, row.correctAnswer, row.givenAnswer), ('TYT Matematik', 'wrong', 'C', 'B'));
    expect(result?.id, row.id);
    expect(find.byType(DesktopQuestionEditor), findsNothing); // pencere kapandı
  });

  testWidgets('Esc pencereyi kapatır, kayıt yapılmaz', (tester) async {
    await open(tester);
    expect(find.byType(DesktopQuestionEditor), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopQuestionEditor), findsNothing);
    expect(await db.select(db.questionCards).get(), isEmpty);
  });

  testWidgets('düzenleme: mevcut değerler gelir; Ctrl+S ile zorluk güncellenir', (tester) async {
    final card = QuestionCard(
      id: 'k1',
      status: QuestionStatus.wrong,
      origin: QuestionOrigin.independent,
      sourceName: 'Kaynak belirtilmemiş',
      subject: 'TYT Fizik',
      difficulty: 4,
      createdAt: DateTime(2026, 10, 1),
    );
    await open(tester, card: card);
    // Aynı kartı veritabanına koy (güncelleme için).
    await db.customStatement(
        "INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, search_text, created_at) "
        "VALUES ('k1', 'wrong', 'independent', 'Kaynak belirtilmemiş', 'TYT Fizik', 4, '', 1760000000)");
    expect(find.text('Soruyu düzenle'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byKey(const ValueKey('zorluk')));
    expect(slider.value, 4);

    await tester.drag(find.byKey(const ValueKey('zorluk')), const Offset(120, 0));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await wait(tester);
    final row = (await db.select(db.questionCards).get()).single;
    expect(row.difficulty, greaterThan(4));
    expect(row.subject, 'TYT Fizik');
  });

  test('kırpma çıktısı PNG dosyası olur; resim uzantıları ayırt edilir', () async {
    final dir = await Directory.systemTemp.createTemp('kirpma');
    addTearDown(() => dir.delete(recursive: true));
    final rgba = Uint8List.fromList(List.generate(4 * 4 * 4, (i) => i % 4 == 3 ? 255 : i * 3 % 256));
    final path = await writeCropAsPng(CropOutput(rgba, 4, 4), dir, 'a');
    final bytes = await File(path).readAsBytes();
    expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]); // PNG imzası
    expect(isImagePath('/x/Soru.JPG'), isTrue);
    expect(isImagePath('/x/not.pdf'), isFalse);
  });
}
