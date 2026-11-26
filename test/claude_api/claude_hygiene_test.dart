import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Anahtar/istek/yanıt günlüğe yazılmasın: Claude API kodunda günlük çağrısı yok.
void main() {
  test('claude_api kodunda print/debugPrint/log/stderr yazımı yok', () {
    final files = Directory('lib/features/claude_api').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    final bad = RegExp(r'\b(print|debugPrint|developer\.log|stderr\.write\w*|stdout\.write\w*)\s*\(');
    for (final f in files) {
      expect(bad.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
  });

  test('anahtar app_meta / veritabanı / eşitleme koduna girmez', () {
    final src = [
      for (final f in Directory('lib/features/claude_api').listSync(recursive: true).whereType<File>()) f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n'),
    ].join('\n');
    expect(src, isNot(contains('app_meta')));
    expect(src, isNot(contains('appDatabaseProvider')));
    expect(src, isNot(contains('customStatement')));
  });
}
