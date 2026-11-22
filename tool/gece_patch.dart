/// Deneme (debug) sürümü yan yana kurulsun diye: uygulama kimliğine ".gece"
/// eklenir, adı "Koçum (deneme)" olur. Release paketi ve adı değişmez.
/// Ad, manifestte `${appLabel}` yer tutucusuyla verilir: release için
/// defaultConfig'te "Koçum", debug için buildType'ta "Koçum (deneme)".
/// Tüm işlevler saf ve idempotenttir.
library;

const geceMarker = 'kocum-gece';
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

String patchGeceKts(String gradle) {
  if (gradle.contains(geceMarker)) return gradle;
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
      '}\n';
}

String patchGeceGroovy(String gradle) {
  if (gradle.contains(geceMarker)) return gradle;
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
      '}\n';
}
