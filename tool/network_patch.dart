/// Kablosuz aktarım (aynı Wi-Fi'daki bilgisayardaki Koçum'a) için ağ izni.
/// Android'de yalnızca yerel ağa izin veren ayrı bir izin yok; INTERNET her
/// türlü bağlantının iznidir. Uygulama kodu yalnızca yerel ağ adreslerine
/// bağlanır: lib/features/sync/domain/network_rules.dart.
library;

const _internet = '<uses-permission android:name="android.permission.INTERNET"/>';

String addInternetPermission(String manifest) {
  if (manifest.contains('android.permission.INTERNET"')) return manifest;
  return manifest.replaceFirst('<application', '$_internet\n    <application');
}
