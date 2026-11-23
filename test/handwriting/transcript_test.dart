import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/handwriting/domain/handwriting_recognizer.dart';
import 'package:kocum/features/handwriting/domain/line_grouping.dart';
import 'package:kocum/features/handwriting/domain/page_transcriber.dart';
import 'package:kocum/features/handwriting/domain/transcript.dart';

import '_helpers.dart';

TranscriptLine tl(String text, double top, double bottom) =>
    TranscriptLine(text: text, strokeIds: const ['a'], left: 0, top: top, right: 100, bottom: bottom);

void main() {
  group('sayfa metni', () {
    test('satırlar alt alta; büyük boşluk paragraf olur; boş satır atlanır', () {
      final t = assemblePageText([
        tl('Merhaba dünya', 100, 140),
        tl('ikinci satır', 160, 200),
        tl('', 220, 260),
        tl('yeni paragraf', 400, 440),
      ]);
      expect(t, 'Merhaba dünya\nikinci satır\n\nyeni paragraf');
      expect(assemblePageText(const []), '');
    });

    test('JSON gidiş dönüş; bozuk JSON boş liste', () {
      final src = [
        tl('a', 0, 10),
        const TranscriptLine(text: '[şekil]', strokeIds: ['x', 'y'], left: 1, top: 2, right: 3, bottom: 4, isShape: true),
      ];
      final back = TranscriptLine.decodeAll(TranscriptLine.encodeAll(src));
      expect(back, hasLength(2));
      expect(back[1].isShape, isTrue);
      expect(back[1].strokeIds, ['x', 'y']);
      expect(TranscriptLine.decodeAll('{bozuk'), isEmpty);
      expect(TranscriptLine.decodeAll(null), isEmpty);
      expect(TranscriptLine.decodeAll('{"a":1}'), isEmpty);
    });

    test('çizgi özeti: sıradan bağımsız, değişince değişir, boşta boş', () {
      final a = strokeSignature([(id: 'a', updatedAtMs: 1), (id: 'b', updatedAtMs: 2)]);
      expect(strokeSignature([(id: 'b', updatedAtMs: 2), (id: 'a', updatedAtMs: 1)]), a);
      expect(strokeSignature([(id: 'a', updatedAtMs: 1), (id: 'b', updatedAtMs: 3)]), isNot(a));
      expect(strokeSignature([(id: 'a', updatedAtMs: 1)]), isNot(a));
      expect(strokeSignature(const []), '');
      expect(isTextStale(storedSig: a, currentSig: a), isFalse);
      expect(isTextStale(storedSig: a, currentSig: 'x'), isTrue);
      expect(isTextStale(storedSig: null, currentSig: 'x'), isFalse);
    });

    test('defter metni: sayfa başlıkları, boş sayfalar atlanır', () {
      final t = assembleNotebookText(const [
        PageTextEntry(pageNumber: 1, text: 'bir'),
        PageTextEntry(pageNumber: 2, text: ' '),
        PageTextEntry(pageNumber: 3, text: 'üç'),
      ], title: 'Fizik');
      expect(t, 'Fizik\n\n— Sayfa 1 —\nbir\n\n— Sayfa 3 —\nüç');
      expect(assembleNotebookText(const [PageTextEntry(pageNumber: 2, text: '')], includeEmpty: true), '— Sayfa 2 —');
    });
  });

  group('transcribeStrokes', () {
    test('iki satır: sırayla tanınır, bağlam önceki satırın son 20 karakteri, ilerleme bildirilir', () async {
      final rec = FakeRecognizer(['  Newton  kanunları   üzerine çalışma notları ', 'F = m a']);
      final prog = <String>[];
      final r = await transcribeStrokes([...letters('b', 3, 300), ...letters('a', 4, 100)], rec,
          onProgress: (d, t) => prog.add('$d/$t'));
      expect(r.text, 'Newton kanunları üzerine çalışma notları\n\nF = m a');
      expect(r.lines, hasLength(2));
      expect(rec.calls[0].preContext, '');
      expect(rec.calls[1].preContext, hasLength(20));
      expect(rec.calls[1].preContext, endsWith('notları'));
      expect(rec.calls[0].area!.height, lessThan(100));
      expect(prog, ['0/2', '1/2', '2/2']);
      expect(r.lines[0].strokeIds, ['a0', 'a1', 'a2', 'a3']);
    });

    test('boş sayfada tanıyıcı çağrılmaz ve model sorulmaz', () async {
      final rec = FakeRecognizer([], status: HandwritingModelStatus.notDownloaded);
      final r = await transcribeStrokes(const [], rec);
      expect(r.text, '');
      expect(rec.calls, isEmpty);
    });

    test('tek harf', () async {
      final rec = FakeRecognizer(['a']);
      final r = await transcribeStrokes([box('x', 10, 10, 30, 40)], rec);
      expect(r.text, 'a');
    });

    test('model yoksa modelMissing, desteklenmiyorsa unsupported', () async {
      final s = letters('a', 3, 100);
      await expectLater(
        transcribeStrokes(s, FakeRecognizer([], status: HandwritingModelStatus.notDownloaded)),
        throwsA(isA<HandwritingException>().having((e) => e.kind, 'kind', HandwritingErrorKind.modelMissing)),
      );
      await expectLater(
        transcribeStrokes(s, FakeRecognizer([], status: HandwritingModelStatus.unsupported)),
        throwsA(isA<HandwritingException>().having((e) => e.kind, 'kind', HandwritingErrorKind.unsupported)),
      );
    });

    test('tek satırın hatası yalnız o satırı boş bırakır; ağ hatası yükselir', () async {
      final s = [...letters('a', 3, 100), ...letters('b', 3, 300)];
      final r = await transcribeStrokes(s, FakeRecognizer(['ilk', 'ikinci'], failAt: {0}));
      expect(r.failedLines, 1);
      expect(r.text, 'ikinci');
      expect(r.lines[0].failed, isTrue);

      final net = _Net();
      await expectLater(transcribeStrokes(s, net),
          throwsA(isA<HandwritingException>().having((e) => e.kind, 'kind', HandwritingErrorKind.network)));
    });

    test('iptal: o ana kadarki satırlar döner', () async {
      final s = [...letters('a', 3, 100), ...letters('b', 3, 300), ...letters('c', 3, 500)];
      var n = 0;
      final r = await transcribeStrokes(s, FakeRecognizer(['bir', 'iki', 'üç']), isCancelled: () => n++ >= 1);
      expect(r.cancelled, isTrue);
      expect(r.lines, hasLength(1));
      expect(r.text, 'bir');
    });

    test('şekil isteğe bağlı "[şekil]" satırı olur ve tanıyıcıya gitmez', () async {
      final s = [...letters('a', 3, 100), box('c', 300, 400, 200, 200, closed: true)];
      final rec = FakeRecognizer(['metin']);
      final r = await transcribeStrokes(s, rec, options: const GroupingOptions(markShapes: true));
      expect(r.text, contains('[şekil]'));
      expect(rec.calls, hasLength(1));
      expect(r.lines.last.isShape, isTrue);
    });

    test('aday yoksa (null) satır boş, hata değil', () async {
      final r = await transcribeStrokes(letters('a', 3, 100), FakeRecognizer([null]));
      expect(r.text, '');
      expect(r.failedLines, 0);
    });
  });
}

class _Net extends FakeRecognizer {
  _Net() : super([]);
  @override
  Future<String?> recognizeLine(List<List<InkSample>> strokes, {String preContext = '', RecognizerArea? area}) =>
      throw const HandwritingException(HandwritingErrorKind.network, 'ağ yok');
}
