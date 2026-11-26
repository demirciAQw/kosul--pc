import 'package:flutter_test/flutter_test.dart';

import '../tool/genai_patch.dart';
import '../tool/health_patch.dart';
import '../tool/ink_overlay_patch.dart';
import '../tool/ink_patch.dart';

void main() {
  test('MainActivity: tek satır, idempotent, diğer yamalarla birlikte bozulmaz', () {
    var s = genAiMainActivity('com.kocum.kocum');
    s = patchHealthMainActivity(s);
    s = patchInkMainActivity(s);
    final once = patchInkOverlayMainActivity(s);
    expect(once, contains(inkOverlayCall));
    expect(inkOverlayCall.allMatches(once).length, 1);
    expect(once, contains(healthRegisterCall));
    expect(once, contains(inkRegisterCall));
    expect(once, contains('"kocum/genai"'));
    expect(patchInkOverlayMainActivity(once), once);
    // Önce biz, sonra diğerleri: her yama kendi satırını tek kez ekler.
    final other = patchInkMainActivity(patchHealthMainActivity(patchInkOverlayMainActivity(genAiMainActivity('p'))));
    for (final call in [inkOverlayCall, inkRegisterCall, healthRegisterCall]) {
      expect(call.allMatches(other).length, 1, reason: call);
    }
    expect(patchInkOverlayMainActivity('class A'), 'class A'); // satır yoksa dokunmaz
  });

  test('satır super.configureFlutterEngine sonrasında, aynı girintide', () {
    final once = patchInkOverlayMainActivity(genAiMainActivity('com.kocum.kocum'));
    final lines = once.split('\n');
    final i = lines.indexWhere((l) => l.contains('super.configureFlutterEngine'));
    expect(lines[i + 1].trim(), inkOverlayCall);
    expect(lines[i + 1].length - lines[i + 1].trimLeft().length, lines[i].length - lines[i].trimLeft().length);
  });

  test('Kotlin: sözleşme adları, resmi Ink akışı, dengeli, şablon yok', () {
    final kt = inkOverlayKotlin('com.kocum.kocum');
    expect(kt, startsWith('package com.kocum.kocum'));
    for (final s in [
      '"kocum/ink_overlay"',
      '"ping"',
      '"setMode"',
      '"setBrush"',
      '"setRegions"',
      '"setMask"',
      '"releaseStrokes"',
      '"cancelCurrent"',
      '"strokeStart"',
      '"strokeFinished"',
      '"strokeCanceled"',
      'InProgressStrokesView',
      'requestUnbufferedDispatch',
      'startStroke',
      'addToStroke',
      'finishStroke',
      'cancelStroke',
      'addFinishedStrokesListener',
      'removeFinishedStrokes',
      'maskPath',
      'eagerInit',
      'MotionEventPredictor',
      'TOOL_TYPE_STYLUS',
      'BUTTON_STYLUS_PRIMARY',
      'setMotionEventSplittingEnabled(false)',
      'fun attach(activity: Activity, engine: FlutterEngine)',
    ]) {
      expect(kt, contains(s), reason: s);
    }
    int count(String c) => c.allMatches(kt).length;
    expect(count('{'), count('}'));
    expect(count('('), count(')'));
    // Dart dizge şablonu sızmaz: yalnız paket adı basılır.
    expect(kt.contains(r'$'), isFalse);
    expect(kt, isNot(contains('INTERPOLATION')));
  });

  test('Kotlin: yalnız Dart\'ın bildirdiği bölgede, yalnız kalemle, yan düğmesiz tüketir', () {
    final kt = inkOverlayKotlin('x.y');
    expect(kt, contains('e.getToolType(0) != MotionEvent.TOOL_TYPE_STYLUS'));
    expect(kt, contains('return inRegion(e.x, e.y)'));
    expect(kt, contains('"off"'));
  });

  test('ortak bağımlılıklar ink_patch içinde (yeni paket yok)', () {
    expect(inkDependencies, contains('androidx.ink:ink-authoring:1.0.0'));
    expect(inkDependencies, contains('androidx.input:input-motionprediction:1.0.1'));
  });
}
