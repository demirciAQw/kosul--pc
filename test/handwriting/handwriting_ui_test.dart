import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/handwriting/data/page_text_repository.dart';
import 'package:kocum/features/handwriting/domain/handwriting_recognizer.dart';
import 'package:kocum/features/handwriting/handwriting_providers.dart';
import 'package:kocum/features/handwriting/presentation/handwriting_settings_card.dart';
import 'package:kocum/features/handwriting/presentation/notebook_text_screen.dart';
import 'package:kocum/features/handwriting/presentation/page_text_sheet.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/domain/ink_notebook.dart';
import 'package:kocum/features/notes/presentation/ink_notebook_screen.dart';
import 'package:kocum/features/notes/presentation/notebooks_screen.dart';

import '_helpers.dart';

class _H {
  _H(this.db)
      : nbs = InkNotebookRepository(db),
        strokes = InkStrokeRepository(db),
        texts = PageTextRepository(db);
  final AppDatabase db;
  final InkNotebookRepository nbs;
  final InkStrokeRepository strokes;
  final PageTextRepository texts;
}

Future<_H> _open(WidgetTester t) async {
  late _H h;
  await t.runAsync(() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    h = _H(db);
  });
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.runAsync(h.db.close);
  });
  t.view.physicalSize = const Size(1200, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  return h;
}

Future<void> _wait(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget _app(_H h, FakeRecognizer rec, Widget home) => ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(h.db), handwritingRecognizerProvider.overrideWithValue(rec)],
      child: MaterialApp(home: home),
    );

/// Bir sayfaya üç harflik tek satır çizgi ekler.
Future<List<String>> _write(_H h, InkNotePageRecord page, {double y = 100}) async => [
      for (var i = 0; i < 3; i++)
        await h.strokes.add(
          owner: NotePageOwner(page.id, page.pageNo),
          points: [StrokePoint(100.0 + i * 40, y, t: 0), StrokePoint(130.0 + i * 40, y + 40, t: 20)],
          startedAtMs: i,
        ),
    ];

class _Host extends StatelessWidget {
  const _Host(this.page, {this.ids});
  final InkNotePageRecord page;
  final Set<String>? ids;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('open'),
            onPressed: () => showPageTextSheet(context, page: page, selectedIds: ids),
            child: const Text('aç'),
          ),
        ),
      );
}

void main() {
  group('Ayarlar kartı', () {
    Future<_H> pump(WidgetTester t, FakeRecognizer rec) async {
      final h = await _open(t);
      await t.pumpWidget(_app(h, rec, const Scaffold(body: SingleChildScrollView(child: HandwritingSettingsCard()))));
      await _wait(t, 2);
      return h;
    }

    testWidgets('indirilmemiş: onay, indirme, silme', (t) async {
      final rec = FakeRecognizer([], status: HandwritingModelStatus.notDownloaded);
      await pump(t, rec);
      expect(find.text('Türkçe model: indirilmedi'), findsOneWidget);
      expect(find.textContaining('~20 MB'), findsOneWidget);
      await t.tap(find.byKey(const Key('hw-download')));
      await t.pumpAndSettle();
      expect(find.textContaining('internet gerekir'), findsWidgets); // veri kullanımı uyarısı
      expect(rec.downloads, 0); // onaydan önce indirme yok
      await t.tap(find.byKey(const Key('hw-download-confirm')));
      await _wait(t, 2);
      expect(rec.downloads, 1);
      expect(find.text('Türkçe model: indirildi'), findsOneWidget);
      await t.tap(find.byKey(const Key('hw-delete')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hw-delete-confirm')));
      await _wait(t, 2);
      expect(rec.deletes, 1);
      expect(find.text('Türkçe model: indirilmedi'), findsOneWidget);
    });

    testWidgets('onaydan vazgeçilirse indirilmez; ağ hatası anlaşılır iletiyle', (t) async {
      final rec = FakeRecognizer([],
          status: HandwritingModelStatus.notDownloaded,
          downloadError: const HandwritingException(HandwritingErrorKind.network, 'Model indirilemedi. İnternet bağlantını kontrol edip yeniden dene.'));
      await pump(t, rec);
      await t.tap(find.byKey(const Key('hw-download')));
      await t.pumpAndSettle();
      await t.tap(find.text('Vazgeç'));
      await t.pumpAndSettle();
      expect(rec.downloads, 0);
      await t.tap(find.byKey(const Key('hw-download')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hw-download-confirm')));
      await _wait(t, 2);
      expect(find.byKey(const Key('hw-error')), findsOneWidget);
      expect(find.textContaining('İnternet bağlantını'), findsOneWidget);
      expect(find.byKey(const Key('hw-download')), findsOneWidget); // yeniden denenebilir
    });

    testWidgets('indirme sürerken ilerleme ve "beklemeyi bırak"', (t) async {
      final gate = Completer<void>();
      final rec = FakeRecognizer([], status: HandwritingModelStatus.notDownloaded, gate: gate);
      await pump(t, rec);
      await t.tap(find.byKey(const Key('hw-download')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hw-download-confirm')));
      await t.pump();
      expect(find.byKey(const Key('hw-progress')), findsOneWidget);
      await t.tap(find.byKey(const Key('hw-cancel')));
      await t.pump();
      expect(find.byKey(const Key('hw-progress')), findsNothing);
      gate.complete();
      await _wait(t, 2);
    });

    testWidgets('masaüstünde (desteklenmeyen) kart görünmez', (t) async {
      await pump(t, FakeRecognizer([], supported: false, status: HandwritingModelStatus.unsupported));
      expect(find.byKey(const Key('hw-card')), findsNothing);
    });
  });

  group('sayfa metni alt sayfası', () {
    testWidgets('model yok: indir -> tanı -> düzelt -> kaydet; sayfa rozeti için kayıt oluşur', (t) async {
      final h = await _open(t);
      late InkNotePageRecord page;
      await t.runAsync(() async {
        final nb = await h.nbs.createNotebook(title: 'Fizik');
        page = (await h.nbs.pages(nb)).first;
        await _write(h, page);
      });
      final rec = FakeRecognizer(['Isı ve sicaklik'], status: HandwritingModelStatus.notDownloaded);
      await t.pumpWidget(_app(h, rec, _Host(page)));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 3);
      expect(find.byKey(const Key('page-text-download')), findsOneWidget);
      await t.tap(find.byKey(const Key('page-text-download')));
      await t.pump(const Duration(milliseconds: 400)); // iniş sırasında dönen gösterge: pumpAndSettle olmaz
      await t.tap(find.byKey(const Key('hw-download-confirm')));
      await _wait(t, 6);
      expect(rec.downloads, 1);
      expect(rec.calls, hasLength(1));
      expect(t.widget<TextField>(find.byKey(const Key('page-text-field'))).controller!.text, 'Isı ve sicaklik');
      await t.enterText(find.byKey(const Key('page-text-field')), 'Isı ve sıcaklık');
      await t.tap(find.byKey(const Key('page-text-save')));
      await _wait(t, 3);
      final saved = await t.runAsync(() => h.texts.get(page.id));
      expect(saved!.text, 'Isı ve sıcaklık');
      expect(saved.lines, hasLength(1));
      expect(await t.runAsync(() => h.texts.isStale(page.id)), isFalse);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('page-text-field')), findsNothing); // kapandı
    });

    testWidgets('tanıma sürerken ilerleme ve iptal; iptalde kısmi sonuç', (t) async {
      final h = await _open(t);
      late InkNotePageRecord page;
      await t.runAsync(() async {
        final nb = await h.nbs.createNotebook();
        page = (await h.nbs.pages(nb)).first;
        await _write(h, page, y: 100);
        await _write(h, page, y: 400);
      });
      final slow = _Slow(['bir', 'iki']);
      await t.pumpWidget(_app(h, slow, _Host(page)));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 3);
      expect(find.byKey(const Key('page-text-progress')), findsOneWidget);
      expect(find.textContaining('okunuyor'), findsOneWidget);
      await t.tap(find.byKey(const Key('page-text-cancel')));
      slow.lineGate.complete();
      await _wait(t, 4);
      expect(find.textContaining('İptal ettin'), findsOneWidget);
      expect(find.byKey(const Key('page-text-field')), findsOneWidget);
    });

    testWidgets('kayıtlı metin gösterilir; çizgi eklenince "güncel değil"; yeniden tanı', (t) async {
      final h = await _open(t);
      late InkNotePageRecord page;
      await t.runAsync(() async {
        final nb = await h.nbs.createNotebook();
        page = (await h.nbs.pages(nb)).first;
        await _write(h, page);
        await h.texts.save(pageId: page.id, text: 'kayıtlı', lines: const [], strokeSig: await h.texts.currentSig(page.id));
      });
      final rec = FakeRecognizer(['yeni metin']);
      await t.pumpWidget(_app(h, rec, _Host(page)));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 4);
      expect(t.widget<TextField>(find.byKey(const Key('page-text-field'))).controller!.text, 'kayıtlı');
      expect(find.byKey(const Key('page-text-stale')), findsNothing);
      expect(rec.calls, isEmpty); // kayıtlı metin varken tanıma çağrılmaz
      // Kapat, sayfaya çizgi ekle, yeniden aç.
      Navigator.of(t.element(find.byKey(const Key('page-text-field')))).pop();
      await t.pumpAndSettle();
      await t.runAsync(() => _write(h, page, y: 500));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 4);
      expect(find.byKey(const Key('page-text-stale')), findsOneWidget);
      await t.tap(find.byKey(const Key('page-text-redo')));
      await _wait(t, 4);
      expect(rec.calls, hasLength(2)); // iki satır artık
      expect(find.byKey(const Key('page-text-stale')), findsNothing);
    });

    testWidgets('kement seçimi: yalnız seçili çizgiler okunur, kaydet düğmesi yok, kopyala var', (t) async {
      final h = await _open(t);
      late InkNotePageRecord page;
      late List<String> ids;
      await t.runAsync(() async {
        final nb = await h.nbs.createNotebook();
        page = (await h.nbs.pages(nb)).first;
        ids = await _write(h, page);
        await _write(h, page, y: 600);
      });
      final rec = FakeRecognizer(['seçili']);
      await t.pumpWidget(_app(h, rec, _Host(page, ids: ids.toSet())));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 5);
      expect(rec.calls, hasLength(1));
      expect(rec.calls.single.strokes, hasLength(3));
      expect(find.text('Seçimin metni'), findsOneWidget);
      expect(find.byKey(const Key('page-text-save')), findsNothing);
      expect(find.byKey(const Key('page-text-copy')), findsOneWidget);
      expect(await t.runAsync(() => h.texts.get(page.id)), isNull); // sayfa metni yazılmadı
    });

    testWidgets('kopyala panoya yazar', (t) async {
      final h = await _open(t);
      late InkNotePageRecord page;
      await t.runAsync(() async {
        final nb = await h.nbs.createNotebook();
        page = (await h.nbs.pages(nb)).first;
        await _write(h, page);
      });
      String? clip;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await t.pumpWidget(_app(h, FakeRecognizer(['merhaba dünya']), _Host(page)));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 5);
      await t.tap(find.byKey(const Key('page-text-copy')));
      await t.pump();
      expect(clip, 'merhaba dünya');
    });

    testWidgets('masaüstü (tanıma yok): kayıtlı metin görünür, tanıma düğmesi yok; metin yoksa açıklama', (t) async {
      final h = await _open(t);
      late InkNotePageRecord p1, p2;
      await t.runAsync(() async {
        final nb = await h.nbs.createNotebook();
        p1 = (await h.nbs.pages(nb)).first;
        p2 = await h.nbs.findPage(await h.nbs.addPage(nb)) as InkNotePageRecord;
        await h.texts.save(pageId: p1.id, text: 'telefondan geldi', lines: const [], strokeSig: 'x');
      });
      final rec = FakeRecognizer([], supported: false, status: HandwritingModelStatus.unsupported);
      await t.pumpWidget(_app(h, rec, _Host(p1)));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 4);
      expect(t.widget<TextField>(find.byKey(const Key('page-text-field'))).controller!.text, 'telefondan geldi');
      expect(find.byKey(const Key('page-text-redo')), findsNothing);
      expect(find.byKey(const Key('page-text-stale')), findsOneWidget); // özet uyuşmuyor
      Navigator.of(t.element(find.byKey(const Key('page-text-field')))).pop();
      await t.pumpAndSettle();
      await t.pumpWidget(_app(h, rec, _Host(p2)));
      await t.tap(find.byKey(const Key('open')));
      await _wait(t, 4);
      expect(find.byKey(const Key('page-text-empty')), findsOneWidget);
      expect(rec.calls, isEmpty);
    });
  });

  group('defterin metin kopyası', () {
    testWidgets('sayfalar sırayla, güncel değil işareti, kopyala', (t) async {
      final h = await _open(t);
      late String nb;
      late InkNotePageRecord p1, p2;
      await t.runAsync(() async {
        nb = await h.nbs.createNotebook(title: 'Fizik');
        p1 = (await h.nbs.pages(nb)).first;
        p2 = (await h.nbs.findPage(await h.nbs.addPage(nb)))!;
        await _write(h, p1);
        await h.texts.save(pageId: p1.id, text: 'birinci sayfa', lines: const [], strokeSig: await h.texts.currentSig(p1.id));
        await h.texts.save(pageId: p2.id, text: 'ikinci sayfa', lines: const [], strokeSig: 'eski');
        await _write(h, p2);
      });
      String? clip;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await t.pumpWidget(_app(h, FakeRecognizer([], supported: false), NotebookTextScreen(notebookId: nb)));
      await _wait(t, 5);
      expect(find.text('Sayfa 1'), findsOneWidget);
      expect(find.text('birinci sayfa'), findsOneWidget);
      expect(find.text('ikinci sayfa'), findsOneWidget);
      expect(find.byKey(Key('nbtext-stale-${p2.id}')), findsOneWidget);
      expect(find.byKey(Key('nbtext-stale-${p1.id}')), findsNothing);
      expect(find.byKey(const Key('nbtext-all')), findsNothing); // masaüstü: tanıma yok
      await t.tap(find.byKey(const Key('nbtext-copy')));
      await t.pump();
      expect(clip, contains('— Sayfa 1 —\nbirinci sayfa'));
      expect(clip, contains('— Sayfa 2 —\nikinci sayfa'));
      expect(clip, startsWith('Fizik'));
    });

    testWidgets('"Tümünü tanı": yalnız metni olmayan sayfalar sırayla tanınır ve kaydedilir; boş sayfa kayıt açmaz', (t) async {
      final h = await _open(t);
      late String nb;
      late InkNotePageRecord p1, p2, p3;
      await t.runAsync(() async {
        nb = await h.nbs.createNotebook(title: 'D');
        p1 = (await h.nbs.pages(nb)).first;
        p2 = (await h.nbs.findPage(await h.nbs.addPage(nb)))!;
        p3 = (await h.nbs.findPage(await h.nbs.addPage(nb)))!;
        await _write(h, p1);
        await _write(h, p2);
        await h.texts.save(pageId: p1.id, text: 'var olan', lines: const [], strokeSig: await h.texts.currentSig(p1.id));
        // p3 boş sayfa
      });
      final rec = FakeRecognizer(['p2 metni']);
      await t.pumpWidget(_app(h, rec, NotebookTextScreen(notebookId: nb)));
      await _wait(t, 4);
      expect(find.text('2 sayfanın metni yok.'), findsOneWidget);
      await t.tap(find.byKey(const Key('nbtext-all')));
      await _wait(t, 10);
      expect(rec.calls, hasLength(1));
      expect((await t.runAsync(() => h.texts.get(p2.id)))!.text, 'p2 metni');
      expect((await t.runAsync(() => h.texts.get(p1.id)))!.text, 'var olan'); // dokunulmadı
      expect(await t.runAsync(() => h.texts.get(p3.id)), isNull);
      await _wait(t, 6);
      expect(find.text('p2 metni'), findsOneWidget);
    });

    testWidgets('"Tümünü tanı": model yoksa indirme önerilir; vazgeçilirse hiçbir şey okunmaz', (t) async {
      final h = await _open(t);
      late String nb;
      await t.runAsync(() async {
        nb = await h.nbs.createNotebook();
        await _write(h, (await h.nbs.pages(nb)).first);
      });
      final rec = FakeRecognizer(['x'], status: HandwritingModelStatus.notDownloaded);
      await t.pumpWidget(_app(h, rec, NotebookTextScreen(notebookId: nb)));
      await _wait(t, 4);
      await t.tap(find.byKey(const Key('nbtext-all')));
      await t.pumpAndSettle();
      expect(find.textContaining('indirilsin mi'), findsOneWidget);
      await t.tap(find.text('Vazgeç'));
      await t.pumpAndSettle();
      expect(rec.downloads, 0);
      expect(rec.calls, isEmpty);
    });
  });

  group('defter listesi araması', () {
    testWidgets('ad ve el yazısı metni (Türkçe duyarsız); sonuç sayfaya götürür', (t) async {
      final h = await _open(t);
      late String a, b;
      late InkNotePageRecord pb;
      await t.runAsync(() async {
        a = await h.nbs.createNotebook(title: 'Fizik');
        b = await h.nbs.createNotebook(title: 'Kimya');
        await h.nbs.addPage(b);
        pb = (await h.nbs.pages(b)).last;
        await h.texts.save(pageId: pb.id, text: 'Isıl denge ve SICAKLIK', lines: const [], strokeSig: '');
      });
      InkNotebookRecord? opened;
      await t.pumpWidget(_app(h, FakeRecognizer([], supported: false),
          Scaffold(body: NotebooksScreen(embedded: true, onOpen: (c, n) => opened = n))));
      await _wait(t, 4);
      expect(find.text('Fizik'), findsOneWidget);
      expect(find.text('Kimya'), findsOneWidget);
      await t.enterText(find.byKey(const Key('notebook-search')), 'sıcaklık');
      await _wait(t, 4);
      // "sıcaklık" ile "SICAKLIK" eşleşir; ad eşleşmediği için ikisi de listeden kalkar.
      expect(find.byKey(Key('notebook-hit-${pb.id}')), findsOneWidget);
      expect(find.textContaining('Sayfa 2 ·'), findsOneWidget);
      expect(find.byKey(Key('notebook-$a')), findsNothing);
      await t.tap(find.byKey(Key('notebook-hit-${pb.id}')));
      expect(opened?.id, b);
      // Ad araması.
      await t.enterText(find.byKey(const Key('notebook-search')), 'FİZİK');
      await _wait(t, 4);
      expect(find.byKey(Key('notebook-$a')), findsOneWidget);
      expect(find.byKey(Key('notebook-$b')), findsNothing);
      expect(find.byKey(Key('notebook-hit-${pb.id}')), findsNothing);
      await t.enterText(find.byKey(const Key('notebook-search')), 'olmayan şey');
      await _wait(t, 4);
      expect(find.textContaining('eşleşen defter ya da metin yok'), findsOneWidget);
      await t.tap(find.byKey(const Key('notebook-search-clear')));
      await _wait(t, 3);
      expect(find.byKey(Key('notebook-$a')), findsOneWidget);
      expect(find.byKey(Key('notebook-$b')), findsOneWidget);
    });
  });

  group('defter ekranı', () {
    testWidgets('sayfa şeridinde "Aa" rozeti; sayfa menüsünden metne çevir; seçim menüsü yok', (t) async {
      final h = await _open(t);
      late String nb;
      late InkNotePageRecord p1, p2;
      await t.runAsync(() async {
        nb = await h.nbs.createNotebook(title: 'D');
        p1 = (await h.nbs.pages(nb)).first;
        p2 = (await h.nbs.findPage(await h.nbs.addPage(nb)))!;
        await _write(h, p1);
        await h.texts.save(pageId: p1.id, text: 'kayıtlı', lines: const [], strokeSig: await h.texts.currentSig(p1.id));
      });
      final rec = FakeRecognizer(['x']);
      await t.pumpWidget(_app(h, rec, InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true)));
      await _wait(t);
      await t.tap(find.byKey(const Key('note-strip-toggle')));
      await _wait(t, 3);
      expect(find.byKey(Key('note-thumb-text-${p1.id}')), findsOneWidget);
      expect(find.byKey(Key('note-thumb-text-${p2.id}')), findsNothing);
      await t.tap(find.byKey(const Key('note-page-menu')));
      await t.pumpAndSettle();
      expect(find.text('Sayfayı metne çevir'), findsOneWidget);
      expect(find.byKey(const Key('note-sel-totext')), findsNothing); // seçim yok
      expect(find.byKey(const Key('note-nb-text')), findsOneWidget);
      await t.tap(find.byKey(const Key('note-page-totext')));
      await _wait(t, 5);
      expect(find.text('Sayfa metni'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const Key('page-text-field'))).controller!.text, 'kayıtlı');
    });

    testWidgets('masaüstü: menüde "Sayfa metnini göster", tanıma çağrılmaz', (t) async {
      final h = await _open(t);
      late String nb;
      await t.runAsync(() async {
        nb = await h.nbs.createNotebook(title: 'D');
      });
      final rec = FakeRecognizer([], supported: false, status: HandwritingModelStatus.unsupported);
      await t.pumpWidget(_app(h, rec, InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true)));
      await _wait(t);
      await t.tap(find.byKey(const Key('note-page-menu')));
      await t.pumpAndSettle();
      expect(find.text('Sayfa metnini göster'), findsOneWidget);
      expect(find.text('Sayfayı metne çevir'), findsNothing);
      expect(rec.calls, isEmpty);
    });
  });
}

/// Tanıma, [gate] açılana kadar bekler.
class _Slow extends FakeRecognizer {
  _Slow(super.answers);
  final lineGate = Completer<void>();
  @override
  Future<String?> recognizeLine(List<List<InkSample>> strokes, {String preContext = '', RecognizerArea? area}) async {
    await lineGate.future;
    return super.recognizeLine(strokes, preContext: preContext, area: area);
  }
}
