import 'package:flutter_test/flutter_test.dart';

import '../tool/genai_patch.dart';
import '../tool/ink_patch.dart';

void main() {
  const kts = 'android {\n    defaultConfig {\n        minSdk = 31\n    }\n}\n';

  test('build.gradle.kts: Ink bağımlılıkları, ikinci kez değişmez', () {
    final once = patchInkKts(kts);
    for (final d in inkDependencies) {
      expect(once, contains('implementation("$d")'));
    }
    expect(once, contains('androidx.input:input-motionprediction'));
    expect(patchInkKts(once), once);
  });

  test('build.gradle (Groovy)', () {
    final once = patchInkGroovy('android {}\n');
    expect(once, contains("implementation 'androidx.ink:ink-authoring:1.0.0'"));
    expect(patchInkGroovy(once), once);
  });

  test('proguard: eklenir, mevcut korunur, tekrar eklenmez', () {
    final fromNull = patchInkProguard(null);
    expect(fromNull, contains('-dontwarn androidx.test.espresso.**'));
    final withOld = patchInkProguard('# eski\n-keep class a.B\n');
    expect(withOld, startsWith('# eski'));
    expect(withOld, contains(inkProguardMarker));
    expect(patchInkProguard(withOld), withOld);
  });

  test('MainActivity: kayıt genai şablonuna eklenir, idempotent', () {
    final base = genAiMainActivity('com.kocum.kocum');
    final once = patchInkMainActivity(base);
    expect(once, contains(inkRegisterCall));
    expect(once, contains('"kocum/genai"')); // genai köprüsü bozulmaz
    expect('KocumInk.register'.allMatches(once).length, 1);
    final lines = once.split('\n');
    final i = lines.indexWhere((l) => l.contains('super.configureFlutterEngine'));
    expect(lines[i + 1].trim(), inkRegisterCall);
    expect(patchInkMainActivity(once), once);
    expect(patchInkMainActivity('class A'), 'class A'); // satır yoksa dokunmaz
  });

  test('Kotlin dosyası: sözleşme adları, dengeli, şablon yok', () {
    final kt = inkKotlin('com.kocum.kocum');
    expect(kt, startsWith('package com.kocum.kocum'));
    for (final s in [
      '"kocum/ink_surface"', '"kocum/ink/"', '"setBrush"', '"clear"', '"setInputMode"',
      '"strokeStart"', '"strokePoint"', '"strokeEnd"', 'TOOL_TYPE_STYLUS',
      'Log.i("KocumInk", "A giris->vsync ms="', 'ACTION_CANCEL',
      '"strokeCancel"', 'MotionEvent.ACTION_POINTER_DOWN', 'MotionEvent.ACTION_POINTER_UP',
      'predicted?.recycle()', 'e.actionIndex', 'e.getPointerId(idx) == activePointer',
    ]) {
      expect(kt, contains(s));
    }
    expect(kt, isNot(contains(r'$')));
    // Avuç ilk DOWN'da bile true: kalemin POINTER_DOWN'u gelebilsin.
    final down = kt.substring(kt.indexOf('MotionEvent.ACTION_DOWN ->'), kt.indexOf('MotionEvent.ACTION_POINTER_DOWN ->'));
    expect(down, contains('if (accepts(e, 0)) startStroke(e, 0)'));
    expect(down, isNot(contains('return false')));
    expect(kt, isNot(contains('A giris->kare')));
    expect('{'.allMatches(kt).length, '}'.allMatches(kt).length);
    expect('('.allMatches(kt).length, ')'.allMatches(kt).length);
  });
}
