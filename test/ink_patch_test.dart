import 'package:flutter_test/flutter_test.dart';

import 'package:kocum/features/ink/domain/predict_limit.dart';

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
    final i = lines.indexWhere(
      (l) => l.contains('super.configureFlutterEngine'),
    );
    expect(lines[i + 1].trim(), inkRegisterCall);
    expect(patchInkMainActivity(once), once);
    expect(patchInkMainActivity('class A'), 'class A'); // satır yoksa dokunmaz
  });

  test('Kotlin dosyası: sözleşme adları, dengeli, şablon yok', () {
    final kt = inkKotlin('com.kocum.kocum');
    expect(kt, startsWith('package com.kocum.kocum'));
    for (final s in [
      '"kocum/ink_surface"',
      '"kocum/ink/"',
      '"setBrush"',
      '"clear"',
      '"setInputMode"',
      '"strokeStart"',
      '"strokePoint"',
      '"strokeEnd"',
      'TOOL_TYPE_STYLUS',
      'Log.i("KocumInk", "A giris->vsync ms="',
      'ACTION_CANCEL',
      '"strokeCancel"',
      'MotionEvent.ACTION_POINTER_DOWN',
      'MotionEvent.ACTION_POINTER_UP',
      'e.actionIndex',
      'e.getPointerId(idx) == activePointer',
    ]) {
      expect(kt, contains(s));
    }
    expect(kt, isNot(contains(r'$')));
    // Avuç ilk DOWN'da bile true: kalemin POINTER_DOWN'u gelebilsin.
    final down = kt.substring(
      kt.indexOf('MotionEvent.ACTION_DOWN ->'),
      kt.indexOf('MotionEvent.ACTION_POINTER_DOWN ->'),
    );
    expect(down, contains('if (accepts(e, 0)) startStroke(e, 0)'));
    expect(down, isNot(contains('return false')));
    expect(kt, isNot(contains('A giris->kare')));
    expect('{'.allMatches(kt).length, '}'.allMatches(kt).length);
    expect('('.allMatches(kt).length, ')'.allMatches(kt).length);
  });

  test(
    'Kotlin: tahmin sınırı sabitleri Dart ile aynı, durma yolunda tahmin yok',
    () {
      final kt = inkKotlin('com.kocum.kocum');
      for (final s in [
        'const val WINDOW = ${PredictLimits.window}',
        'const val STILL_SPEED = ${PredictLimits.stillSpeed}f',
        'const val STILL_COUNT = ${PredictLimits.stillCount}',
        'const val STILL_MOVE = ${PredictLimits.stillMove}f',
        'const val HORIZON_MS = ${PredictLimits.horizonMs}f',
        'const val LEAD_SCALE = ${PredictLimits.leadScale}f',
        'const val MAX_LEAD_DP = ${PredictLimits.maxLeadDp}f',
        'class PredictLimiter',
        'limiter.clip(predX, predY, predT, n)',
      ]) {
        expect(kt, contains(s));
      }
      // Durmuşken tahminciye sorulmaz, boş (prediction = null) toplu verilir.
      final cp = kt.substring(
        kt.indexOf('private fun collectPredicted'),
        kt.indexOf('private fun push'),
      );
      expect(cp, contains('predictedBatch.clear()'));
      expect(cp, contains('if (limiter.isStill()) return'));
      expect(
        cp.indexOf('isStill()'),
        lessThan(cp.indexOf('predictor.predict()')),
      );
      expect(
        kt,
        contains('if (withPrediction) predictedBatch else noPrediction'),
      );
      // Bitişte ve ilk noktada tahmin yok.
      expect(kt, contains('push(s, false) // bitişte tahmin yok'));
      expect(kt, contains('pe.recycle()'));
    },
  );

  test(
    'Kotlin: ön tampon (InProgressStrokesView) yok, çizim kendi onDraw\'unda',
    () {
      final kt = inkKotlin('com.kocum.kocum');
      expect(kt, isNot(contains('InProgressStrokesView')));
      expect(kt, isNot(contains('SurfaceView')));
      expect(kt, contains('InProgressStroke()'));
      expect(kt, contains('renderer.draw(canvas, l, worldToView)'));
      expect(kt, contains('renderer.draw(canvas, s, worldToView)'));
    },
  );

  test('Kotlin: setTransform ve koordinat semantiği (dünya <-> görünüm)', () {
    final kt = inkKotlin('com.kocum.kocum');
    expect(kt, contains('"setTransform" ->'));
    expect(kt, contains('worldToView.setScale(scale, scale)'));
    expect(kt, contains('worldToView.postTranslate(tx, ty)'));
    expect(kt, contains('tx = if (dx.isNaN()) 0f else dx * density'));
    expect(
      kt,
      contains(
        'private fun worldX(viewPx: Float): Float = (viewPx - tx) / scale',
      ),
    );
    // Dart'a mantıksal dünya koordinatı gider.
    expect(kt, contains('"x" to (worldX(x) / density).toDouble()'));
    // Ink'e dünya koordinatı girer (görünüm pikseli değil).
    expect(kt, contains('worldX(x), worldY(y), el'));
  });
}
