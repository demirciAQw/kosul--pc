import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/ink_command_stack.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_object.dart';
import 'package:kocum/features/ink/domain/lasso.dart';

InkObject o(String id, [double x = 0]) =>
    InkObject(id: id, points: [InkPoint(x: x, y: 0), InkPoint(x: x + 1, y: 0)]);

List<String> ids(InkCommandStack s) => s.objects.map((e) => e.id).toList();

void main() {
  test('ekle, geri al, yinele', () {
    final s = InkCommandStack();
    s.add([o('a')]);
    s.add([o('b'), o('c')]);
    expect(ids(s), ['a', 'b', 'c']);
    expect(s.undo(), isTrue);
    expect(ids(s), ['a']);
    expect(s.undo(), isTrue);
    expect(s.canUndo, isFalse);
    expect(s.undo(), isFalse);
    expect(s.redo(), isTrue);
    expect(s.redo(), isTrue);
    expect(ids(s), ['a', 'b', 'c']);
    expect(s.redo(), isFalse);
  });

  test('yeni komut yinele yığınını siler', () {
    final s = InkCommandStack()..add([o('a')])..add([o('b')]);
    s.undo();
    s.add([o('c')]);
    expect(s.canRedo, isFalse);
    expect(ids(s), ['a', 'c']);
  });

  test('sil: z-sırası geri alınca korunur; olmayan silme komut eklemez', () {
    final s = InkCommandStack(initial: [o('a'), o('b'), o('c')]);
    expect(s.remove(['x']), 0);
    expect(s.canUndo, isFalse);
    expect(s.remove(['b']), 1);
    expect(ids(s), ['a', 'c']);
    s.undo();
    expect(ids(s), ['a', 'b', 'c']);
  });

  test('dönüştür', () {
    final s = InkCommandStack(initial: [o('a'), o('b')]);
    s.transform(['a'], (e) => translateObject(e, 10, 0));
    expect(s.objects[0].points[0].x, 10);
    expect(s.objects[1].points[0].x, 0);
    s.undo();
    expect(s.objects[0].points[0].x, 0);
    s.transform(['yok'], (e) => e);
    expect(s.canRedo, isTrue); // boş dönüşüm yığını bozmaz
  });

  test('böl: parçalar yerinde, geri al özgünü getirir', () {
    final s = InkCommandStack(initial: [o('a'), o('b'), o('c')]);
    s.split('b', [o('b#0'), o('b#1')]);
    expect(ids(s), ['a', 'b#0', 'b#1', 'c']);
    s.split('a', const []);
    expect(ids(s), ['b#0', 'b#1', 'c']);
    s.undo();
    s.undo();
    expect(ids(s), ['a', 'b', 'c']);
    s.redo();
    expect(ids(s), ['a', 'b#0', 'b#1', 'c']);
    s.split('yok', [o('z')]);
    expect(ids(s), ['a', 'b#0', 'b#1', 'c']);
  });

  test('replaceMany: çok nesne tek harekette, tek geri al tümünü alır', () {
    final s = InkCommandStack(initial: [o('a'), o('b'), o('c'), o('d')]);
    final n = s.replaceMany({
      'a': [o('a1'), o('a2')],
      'c': const [],
      'yok': [o('z')],
    });
    expect(n, 2);
    expect(ids(s), ['a1', 'a2', 'b', 'd']);
    expect(s.undo(), isTrue);
    expect(ids(s), ['a', 'b', 'c', 'd']);
    expect(s.canUndo, isFalse); // tek kayıt
    expect(s.redo(), isTrue);
    expect(ids(s), ['a1', 'a2', 'b', 'd']);
    expect(s.replaceMany({'yok': [o('z')]}), 0);
    expect(s.replaceMany({}), 0);
    expect(s.canRedo, isFalse);
  });

  test('replaceMany: maxDepth hareketleri sayar', () {
    final s = InkCommandStack(initial: [for (var i = 0; i < 20; i++) o('s$i')], maxDepth: 2);
    for (var k = 0; k < 4; k++) {
      s.replaceMany({for (var i = 0; i < 5; i++) 's${k * 5 + i}': [o('r${k * 5 + i}')]});
    }
    var n = 0;
    while (s.undo()) {
      n++;
    }
    expect(n, 2);
    expect(s.objects.where((e) => e.id.startsWith('r')).length, 10);
  });

  test('derinlik sınırı', () {
    final s = InkCommandStack(maxDepth: 3);
    for (var i = 0; i < 6; i++) {
      s.add([o('n$i')]);
    }
    var n = 0;
    while (s.undo()) {
      n++;
    }
    expect(n, 3);
    expect(ids(s), ['n0', 'n1', 'n2']);
  });

  test('objects dışarıdan değiştirilemez', () {
    final s = InkCommandStack(initial: [o('a')]);
    expect(() => s.objects.add(o('b')), throwsUnsupportedError);
  });
}
