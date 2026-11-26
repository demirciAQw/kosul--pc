import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/genai_patch.dart';
import '../tool/health_patch.dart';
import '../tool/ink_patch.dart';
import '../tool/secure_store_patch.dart';

void main() {
  test('MainActivity: kayıt satırı genai/ink/health ile çakışmadan, bir kez eklenir', () {
    var a = genAiMainActivity('com.kocum.kocum');
    a = patchInkMainActivity(a);
    a = patchHealthMainActivity(a);
    a = patchSecureMainActivity(a);
    expect(a, contains(secureRegisterCall));
    expect(a, contains(healthRegisterCall));
    expect(a, contains(inkRegisterCall));
    expect(patchSecureMainActivity(a), a);
    expect(secureRegisterCall.allMatches(a), hasLength(1));
    // Sıra: sağlık yaması da sonradan çalışsa bozulmaz.
    expect(patchHealthMainActivity(a), a);
  });

  test('Kotlin: Keystore AES/GCM, noBackupFilesDir, kanal; dizge şablonu ve günlük yok', () {
    final k = secureKotlin('com.kocum.kocum');
    expect(k, startsWith('package com.kocum.kocum'));
    expect(k, contains('"kocum/secure"'));
    expect(k, contains('AndroidKeyStore'));
    expect(k, contains('AES/GCM/NoPadding'));
    expect(k, contains('noBackupFilesDir'));
    expect(k, contains('"kaydet"'));
    expect(k, contains('"oku"'));
    expect(k, contains('"sil"'));
    expect(k, contains('"varMi"'));
    expect(k, isNot(contains(r'$')));
    expect(k, isNot(contains('Log.')));
    expect(k, isNot(contains('println')));
    // Sır hata iletisine girmez: catch yalnız sabit ileti verir.
    expect(k, contains('"islem basarisiz"'));
    expect(k, isNot(contains('t.message')));
    // Harici depolama / SharedPreferences yok.
    expect(k, isNot(contains('getExternal')));
    expect(k, isNot(contains('SharedPreferences')));
  });

  test('patch_android.dart güvenli depo yamasını genai sonrasında çağırır', () {
    final s = File('tool/patch_android.dart').readAsStringSync();
    expect(s.indexOf('_patchGenAi(kts, groovy);'), lessThan(s.indexOf('_patchSecureStore();')));
  });
}
