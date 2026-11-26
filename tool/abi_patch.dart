/// APK boyutu: telefon ve tablet arm64-v8a. ML Kit eklentileri x86_64 ve
/// armeabi-v7a yerel kitaplıklarını da getirir (Flutter `--target-platform`
/// bunları süzmez); burada yalnız arm64-v8a bırakılır. Saf ve idempotent.
library;

const abiMarker = 'kocum-abi';

const _kts = '\n'
    '// $abiMarker: yalnız arm64-v8a (APK boyutu).\n'
    'android {\n'
    '    defaultConfig {\n'
    '        ndk {\n'
    '            abiFilters.clear()\n'
    '            abiFilters.add("arm64-v8a")\n'
    '        }\n'
    '    }\n'
    '}\n';

const _groovy = '\n'
    '// $abiMarker: yalnız arm64-v8a (APK boyutu).\n'
    'android {\n'
    '    defaultConfig {\n'
    '        ndk {\n'
    '            abiFilters.clear()\n'
    "            abiFilters.add('arm64-v8a')\n"
    '        }\n'
    '    }\n'
    '}\n';

String patchAbiKts(String gradle) =>
    gradle.contains(abiMarker) ? gradle : '$gradle$_kts';

String patchAbiGroovy(String gradle) =>
    gradle.contains(abiMarker) ? gradle : '$gradle$_groovy';
