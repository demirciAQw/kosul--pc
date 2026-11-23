import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/genai_patch.dart';
import '../tool/health_patch.dart';
import '../tool/ink_patch.dart';

const _manifest = '''
<manifest xmlns:tools="http://schemas.android.com/tools" xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <application android:label="x">
        <activity android:name=".MainActivity">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
            </intent-filter>
        </activity>
    </application>
    <queries>
        <intent>
            <action android:name="android.intent.action.PROCESS_TEXT"/>
        </intent>
    </queries>
</manifest>
''';

void main() {
  test('bildirim: izinler, gerekçe etkinliği, alias ve queries bir kez eklenir (idempotent)', () {
    final out = patchHealthManifest(_manifest);
    for (final p in healthPermissions) {
      expect(out, contains('android:name="$p"'));
    }
    expect(out, contains('ACTION_SHOW_PERMISSIONS_RATIONALE'));
    expect(out, contains('VIEW_PERMISSION_USAGE'));
    expect(out, contains('android.permission.START_VIEW_PERMISSION_USAGE'));
    expect(out, contains('<package android:name="com.google.android.apps.healthdata"/>'));
    // Mevcut queries korunur, tek <queries> bloğu kalır.
    expect(out, contains('PROCESS_TEXT'));
    expect('<queries>'.allMatches(out), hasLength(1));
    expect(patchHealthManifest(out), out);
    // Yalnız okuma izni: yazma izni yok.
    expect(out, isNot(contains('permission.health.WRITE')));
  });

  test('bildirimde queries yoksa eklenir', () {
    final m = _manifest.replaceAll(RegExp(r'<queries>[\s\S]*</queries>\n'), '');
    final out = patchHealthManifest(m);
    expect('<queries>'.allMatches(out), hasLength(1));
    expect(out, contains('healthdata'));
  });

  test('gradle: bağımlılık bir kez, ink bağımlılıklarıyla yan yana', () {
    const kts = 'plugins {}\nandroid {}\n';
    final out = patchHealthKts(patchInkKts(kts));
    expect(out, contains(healthDependency));
    expect(out, contains('androidx.ink:ink-authoring'));
    expect(patchHealthKts(out), out);
    final g = patchHealthGroovy('apply plugin: "x"\n');
    expect(g, contains("implementation '$healthDependency'"));
    expect(patchHealthGroovy(g), g);
  });

  test('MainActivity: kayıt satırı genai ve ink ile çakışmadan, bir kez eklenir', () {
    var a = genAiMainActivity('com.kocum.kocum');
    a = patchInkMainActivity(a);
    a = patchHealthMainActivity(a);
    expect(a, contains(healthRegisterCall));
    expect(a, contains(inkRegisterCall));
    expect(a, contains('super.configureFlutterEngine(flutterEngine)'));
    expect(patchHealthMainActivity(a), a);
    expect(healthRegisterCall.allMatches(a), hasLength(1));
  });

  test('Kotlin: paket, kanal adı, yalnız okuma çağrıları; dizge şablonu yok', () {
    final k = healthKotlin('com.kocum.kocum');
    expect(k, startsWith('package com.kocum.kocum'));
    expect(k, contains('"kocum/health"'));
    expect(k, contains('getReadPermission'));
    expect(k, isNot(contains('getWritePermission')));
    expect(k, isNot(contains('insertRecords')));
    expect(k, isNot(contains(r'$')));
  });

  test('patch_android.dart sağlık yamasını ink/genai sonrasında çağırır', () {
    final s = File('tool/patch_android.dart').readAsStringSync();
    expect(s.indexOf('_patchGenAi(kts, groovy);'), lessThan(s.indexOf('_patchHealth(kts, groovy, manifest);')));
    expect(s.indexOf('_patchInk(kts, groovy);'), lessThan(s.indexOf('_patchHealth(kts, groovy, manifest);')));
  });
}
