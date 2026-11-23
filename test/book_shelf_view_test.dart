import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/library/domain/progress.dart';
import 'package:kocum/features/library/presentation/widgets/book_shelf_view.dart';

Book _book(String id, String title, {String subject = 'Fizik', String? publisher = 'Bilgi Sarmal'}) => Book(
      id: id,
      title: title,
      examType: 'TYT',
      subject: subject,
      pageCount: 100,
      avgQuestionsPerPage: 1,
      createdAt: DateTime(2026),
      publisher: publisher,
    );

BookProgress _p(Book b, {int done = 3, int total = 10}) => BookProgress(
      book: b,
      totalLeaves: total,
      doneLeaves: done,
      correct: 0,
      wrong: 0,
      blank: 0,
      totalQuestions: 0,
      doneQuestions: 0,
    );

Future<void> _pump(WidgetTester t, double w, List<BookProgress> items, {void Function(Book)? onOpen, Brightness b = Brightness.light}) async {
  t.view.physicalSize = Size(w, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: b),
    home: Scaffold(body: BookShelfView(items: items, onOpen: onOpen ?? (_) {})),
  ));
}

void main() {
  test('kapak rengi kararlı: aynı ders hep aynı renk', () {
    expect(bookCoverColor(_book('a', 'Kitap 1')), bookCoverColor(_book('b', 'Başka', subject: 'fizik')));
    expect(bookCoverPalette, contains(bookCoverColor(_book('a', 'x', subject: 'Kimya'))));
    expect(bookCoverColor(_book('a', 'Adı', subject: '')), bookCoverColor(_book('z', 'Adı', subject: ' ')));
  });

  test('sütun sayıları', () {
    expect(shelfColumnsFor(412), 3);
    expect(shelfColumnsFor(320), 2);
    expect(shelfColumnsFor(1250), 6);
    expect(shelfColumnsFor(1000), 5);
    expect(shelfColumnsFor(700), 4);
  });

  for (final w in [412.0, 1250.0]) {
    for (final br in Brightness.values) {
      testWidgets('$w dp ${br.name}: taşma yok, başlık ve ilerleme görünür', (t) async {
        final items = [
          for (var i = 0; i < 9; i++)
            _p(_book('b$i', 'Çok uzun bir kitap adı örneği numara $i ile devam eder', subject: i.isEven ? 'Fizik' : 'Kimya')),
        ];
        await _pump(t, w, items, b: br);
        expect(t.takeException(), isNull);
        expect(find.byType(BookCover), findsWidgets);
        expect(find.textContaining('%30'), findsWidgets);
        final cover = t.getSize(find.byType(BookCover).first);
        expect(cover.height / cover.width, closeTo(1.5, 0.01));
        final firstRowTop = t.getTopLeft(find.byType(BookCover).first).dy;
        final sameRow = find.byType(BookCover).evaluate().where((e) => (t.getTopLeft(find.byWidget(e.widget)).dy - firstRowTop).abs() < 1).length;
        expect(sameRow, shelfColumnsFor(w));
      });
    }
  }

  testWidgets('dokununca onOpen çağrılır', (t) async {
    Book? opened;
    await _pump(t, 412, [_p(_book('x', 'Optik Fizik'))], onOpen: (b) => opened = b);
    expect(find.text('Optik Fizik'), findsOneWidget);
    await t.tap(find.text('Optik Fizik'));
    expect(opened?.id, 'x');
  });

  testWidgets('yayınevsiz ve sıfır sayfalı kitap çökmez', (t) async {
    await _pump(t, 412, [_p(_book('x', 'A', publisher: null), done: 0, total: 0)]);
    expect(t.takeException(), isNull);
    expect(find.textContaining('%0'), findsOneWidget);
  });

  testWidgets('raf tembel kurulur: uzun listede yalnız görünen satırlar; başlık ilk öğe', (t) async {
    final items = [for (var i = 0; i < 200; i++) _p(_book('k$i', 'Kitap $i'))];
    t.view.physicalSize = const Size(412, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ShelfLayout<BookProgress>(
          items: items,
          header: const Text('BASLIK', key: Key('hdr')),
          itemBuilder: (_, p) => Text(p.book.title),
        ),
      ),
    ));
    expect(find.byKey(const Key('hdr')), findsOneWidget);
    expect(find.text('Kitap 0'), findsOneWidget);
    expect(find.text('Kitap 199'), findsNothing); // ekran dışı: kurulmadı
    expect(find.byType(ListView), findsOneWidget);
    await t.scrollUntilVisible(find.text('Kitap 199'), 500, scrollable: find.byType(Scrollable));
    expect(find.text('Kitap 199'), findsOneWidget);
    expect(find.byKey(const Key('hdr')), findsNothing);
  });
}
