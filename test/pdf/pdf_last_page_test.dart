import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/pdf/data/pdf_last_page_store.dart';

void main() {
  test('startPage: bağlantı önce, sonra kayıtlı sayfa, geçersizse başa', () {
    expect(startPage(linked: 5, saved: 203, pageCount: 300), 5);
    expect(startPage(linked: null, saved: 203, pageCount: 300), 203);
    expect(startPage(linked: null, saved: 300, pageCount: 300), isNull);
    expect(startPage(linked: 400, saved: 10, pageCount: 300), 10);
    expect(startPage(linked: null, saved: null, pageCount: 300), isNull);
    expect(startPage(linked: null, saved: -1, pageCount: 300), isNull);
  });

  test('PdfLastPageStore: yaz, oku, ayrı belgeler karışmaz', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = PdfLastPageStore(db);
    expect(await s.load('a'), isNull);
    await s.save('a', 203);
    await s.save('b', 4);
    await s.save('a', 204);
    expect(await s.load('a'), 204);
    expect(await s.load('b'), 4);
    await s.save('a', -3); // geçersiz: yok sayılır
    expect(await s.load('a'), 204);
  });
}
