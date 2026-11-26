import 'package:flutter_test/flutter_test.dart';

import '../tool/abi_patch.dart';

void main() {
  test('kts: yalnız arm64-v8a eklenir, idempotent', () {
    final out = patchAbiKts('android {\n}\n');
    expect(out, contains('abiFilters.add("arm64-v8a")'));
    expect('abiFilters.add'.allMatches(out).length, 1);
    expect(out, isNot(contains('x86')));
    expect(patchAbiKts(out), out);
  });

  test('groovy: yalnız arm64-v8a eklenir, idempotent', () {
    final out = patchAbiGroovy('android {\n}\n');
    expect(out, contains("abiFilters.add('arm64-v8a')"));
    expect(patchAbiGroovy(out), out);
  });
}
