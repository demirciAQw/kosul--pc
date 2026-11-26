import 'package:flutter_test/flutter_test.dart';

import '../tool/gece_patch.dart';

const _kts = '''
android {
    defaultConfig {
        applicationId = "com.kocum.kocum.gece"
        minSdk = 31
    }
    buildTypes {
        release {
        }
    }
}
''';

const _groovy = '''
android {
    defaultConfig {
        applicationId "com.kocum.kocum"
        minSdk 31
    }
}
''';

void main() {
  test('manifest etiketi yer tutucu olur, tekrar çalışınca değişmez', () {
    const m = '<application\n        android:label="Koçum Gece"\n        android:icon="@mipmap/ic_launcher">\n'
        '<activity android:name=".MainActivity" android:label="Ana"/>\n</application>';
    final out = patchGeceManifest(m);
    expect(out, contains('<application\n        android:label="\${appLabel}"'));
    expect(out, contains('<activity android:name=".MainActivity" android:label="Ana"/>'));
    expect('android:label='.allMatches(out).length, 2);
    expect(patchGeceManifest(out), out);
  });

  test('kts: debug son eki ve adı eklenir, release kimliği temiz kalır', () {
    final out = patchGeceKts(_kts);
    expect(out, contains('applicationId = "com.kocum.kocum"'));
    expect(out, isNot(contains('applicationId = "com.kocum.kocum.gece"')));
    expect(out, contains('manifestPlaceholders["appLabel"] = "Koçum"'));
    expect(out, contains('getByName("debug")'));
    expect('applicationIdSuffix'.allMatches(out).length, 1); // profile buildType'a SON EK YAZILMAZ (kütüphaneler bozulur)
    expect(out, contains('selector().withBuildType("profile")'));
    expect(out, contains('variant.applicationId.get() + ".gece"'));
    final dbg = out.substring(out.indexOf('getByName("debug")'));
    expect(dbg, contains('applicationIdSuffix = ".gece"'));
    expect(dbg, contains('manifestPlaceholders["appLabel"] = "Koçum (deneme)"'));
    expect(out.substring(0, out.indexOf('// kocum-gece')),
        isNot(contains('applicationIdSuffix')));
    expect(patchGeceKts(out), out);
  });

  test('groovy: debug son eki ve adı eklenir, idempotent', () {
    final out = patchGeceGroovy(_groovy);
    expect(out, contains('applicationId "com.kocum.kocum"'));
    expect(out, contains("manifestPlaceholders += [appLabel: 'Koçum']"));
    expect('applicationIdSuffix'.allMatches(out).length, 1);
    expect(out, contains("selector().withBuildType('profile')"));
    final dbg = out.substring(out.indexOf('debug {'));
    expect(dbg, contains("applicationIdSuffix '.gece'"));
    expect(dbg, contains("manifestPlaceholders += [appLabel: 'Koçum (deneme)']"));
    expect(patchGeceGroovy(out), out);
  });

  test('eski (profile öncesi) yamalı dosyaya profile bloğu bir kez eklenir', () {
    final eski = patchGeceKts(_kts).split('// kocum-gece-profile').first;
    expect(eski, isNot(contains('"profile"')));
    final yeni = patchGeceKts(eski);
    expect(yeni, contains('kocum-gece-profile'));
    expect('kocum-gece-profile'.allMatches(yeni).length, 1);
    expect(patchGeceKts(yeni), yeni);
    final g = patchGeceGroovy(_groovy).split('// kocum-gece-profile').first;
    final gy = patchGeceGroovy(g);
    expect(gy, contains("withBuildType('profile')"));
    expect(patchGeceGroovy(gy), gy);
  });

  test('defaultConfig yoksa istisna atılır', () {
    expect(() => patchGeceKts('android {}'), throwsA(isA<GeceYamaHatasi>()));
    expect(() => patchGeceGroovy('android {}'), throwsA(isA<GeceYamaHatasi>()));
  });
}
