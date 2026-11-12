import 'package:flutter_test/flutter_test.dart';

import '../tool/network_patch.dart';

void main() {
  test('INTERNET izni application öncesine bir kez eklenir', () {
    const m = '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <application android:label="kocum">\n    </application>\n</manifest>\n';
    final out = addInternetPermission(m);
    expect(out, contains('<uses-permission android:name="android.permission.INTERNET"/>'));
    expect(out.indexOf('android.permission.INTERNET'), lessThan(out.indexOf('<application')));
    expect(addInternetPermission(out), out);
    expect('android.permission.INTERNET'.allMatches(out), hasLength(1));
  });

  test('izin zaten varsa dokunulmaz', () {
    const m = '<manifest>\n<uses-permission android:name="android.permission.INTERNET" />\n<application/>\n</manifest>';
    expect(addInternetPermission(m), m);
  });
}
