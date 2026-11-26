/// Deneme (debug ve profile) sürümü yan yana kurulsun diye: uygulama kimliğine ".gece"
/// eklenir, adı "Koçum (deneme)" olur. Release paketi ve adı değişmez.
/// Ad, manifestte `${appLabel}` yer tutucusuyla verilir: release için
/// defaultConfig'te "Koçum", debug için buildType'ta "Koçum (deneme)".
/// Tüm işlevler saf ve idempotenttir.
library;

const geceMarker = 'kocum-gece';
const geceProfileMarker = 'kocum-gece-profile';
/// build.gradle içinde `defaultConfig {` bulunamadı.
class GeceYamaHatasi implements Exception {
  const GeceYamaHatasi();
  @override
  String toString() => 'build.gradle içinde "defaultConfig {" bulunamadı';
}

const _label = r'android:label="${appLabel}"';

/// Manifestteki uygulama adını yer tutucuya çevirir.
/// Yalnızca `<application>` etiketine dokunur (activity etiketleri kalır).
String patchGeceManifest(String manifest) => manifest.replaceFirstMapped(
    RegExp(r'<application\b[^>]*>'),
    (m) => m[0]!.replaceFirst(RegExp(r'android:label="[^"]*"'), _label));

/// Eski elle düzenlemeden kalan ".gece" son eki defaultConfig'ten atılır
/// (yoksa release paketi de ".gece" kimliğini taşırdı).
String _stripSuffix(String s) =>
    s.replaceAllMapped(RegExp(r'(applicationId\s*=?\s*)(["\x27])([^"\x27]*?)\.gece\2'), (m) => '${m[1]}${m[2]}${m[3]}${m[2]}');

/// Flutter `profile` türünü debug'ın kopyası (initWith) olarak, eklenti
/// modülleri için de kurar; buildType'a `applicationIdSuffix` yazmak kütüphane
/// modüllerinde derlemeyi bozar. Bu yüzden yalnız uygulama varyantına
/// `androidComponents.onVariants` ile verilir.
const _profileKts = '\n'
    '// $geceProfileMarker: profile (hızlı AOT deneme) da yan yana kurulur.\n'
    'androidComponents {\n'
    '    onVariants(selector().withBuildType("profile")) { variant ->\n'
    '        variant.applicationId.set(variant.applicationId.get() + ".gece")\n'
    '        variant.manifestPlaceholders.put("appLabel", "Koçum (deneme)")\n'
    '    }\n'
    '}\n';

const _profileGroovy = '\n'
    '// $geceProfileMarker: profile (hızlı AOT deneme) da yan yana kurulur.\n'
    'androidComponents {\n'
    "    onVariants(selector().withBuildType('profile')) { variant ->\n"
    "        variant.applicationId.set(variant.applicationId.get() + '.gece')\n"
    "        variant.manifestPlaceholders.put('appLabel', 'Koçum (deneme)')\n"
    '    }\n'
    '}\n';

String _withProfile(String s, String block) =>
    s.contains(geceProfileMarker) ? s : '$s$block';

String patchGeceKts(String gradle) {
  if (gradle.contains(geceMarker)) return _withProfile(gradle, _profileKts);
  var s = _stripSuffix(gradle);
  if (!s.contains('defaultConfig {')) throw const GeceYamaHatasi();
  s = s.replaceFirst('defaultConfig {', 'defaultConfig {\n        manifestPlaceholders["appLabel"] = "Koçum"');
  return '$s\n'
      '// $geceMarker: debug derleme yan yana kurulur, adı "Koçum (deneme)".\n'
      'android {\n'
      '    buildTypes {\n'
      '        getByName("debug") {\n'
      '            applicationIdSuffix = ".gece"\n'
      '            manifestPlaceholders["appLabel"] = "Koçum (deneme)"\n'
      '        }\n'
      '    }\n'
      '}\n'
      '$_profileKts';
}

String patchGeceGroovy(String gradle) {
  if (gradle.contains(geceMarker)) return _withProfile(gradle, _profileGroovy);
  var s = _stripSuffix(gradle);
  if (!s.contains('defaultConfig {')) throw const GeceYamaHatasi();
  s = s.replaceFirst('defaultConfig {', "defaultConfig {\n        manifestPlaceholders += [appLabel: 'Koçum']");
  return '$s\n'
      '// $geceMarker: debug derleme yan yana kurulur, adı "Koçum (deneme)".\n'
      'android {\n'
      '    buildTypes {\n'
      '        debug {\n'
      "            applicationIdSuffix '.gece'\n"
      "            manifestPlaceholders += [appLabel: 'Koçum (deneme)']\n"
      '        }\n'
      '    }\n'
      '}\n'
      '$_profileGroovy';
}
