/// Güvenli anahtar deposu (Claude API anahtarı) için Android yaması.
///
/// Kanal `kocum/secure` (kaydet/oku/sil/varMi). Anahtar, Android Keystore'da
/// üretilen AES-256/GCM anahtarıyla şifrelenir (anahtar cihazdan çıkmaz);
/// şifreli blob `noBackupFilesDir` altında dosyadır: Android otomatik yedeğine ve
/// cihazdan cihaza aktarıma GİRMEZ (bu klasör platform tarafından hariçtir; ayrıca
/// manifest dışlaması gerekmez). Veritabanında, `app_meta`'da, yedek ZIP'te ve
/// kablosuz eşitlemede YOKTUR. Yeni bağımlılık yok (platform API).
///
/// Fonksiyonlar saf ve idempotenttir; test/secure_store_patch_test.dart ile denenir.
/// MainActivity zinciri: ink/health ile aynı kalıp (`super.configureFlutterEngine`
/// sonrasına tek satır); _patchGenAi'den SONRA çalışmalıdır.
library;

const secureMarker = 'KocumSecurePlugin';
const secureRegisterCall = 'flutterEngine.plugins.add(KocumSecurePlugin())';

/// MainActivity'ye kayıt satırı.
String patchSecureMainActivity(String source) {
  if (source.contains(secureRegisterCall)) return source;
  return source.replaceFirstMapped(
    RegExp(r'^([ \t]*)super\.configureFlutterEngine\(flutterEngine\)[ \t]*$', multiLine: true),
    (m) => '${m[0]}\n${m[1]}$secureRegisterCall',
  );
}

/// Kotlin dosyası. Dart `'''` dizgesi: Kotlin dizge şablonu (dolar işareti) KULLANILMAZ.
String secureKotlin(String package) => '''
package $package

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// Koçum: Keystore korumalı küçük sır deposu (kanal "kocum/secure").
class KocumSecurePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var dir: File? = null
    private val alias = "kocum_secure_aes"

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        dir = b.applicationContext.noBackupFilesDir
        channel = MethodChannel(b.binaryMessenger, "kocum/secure").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun validName(n: String?): Boolean =
        n != null && n.length in 1..32 && n.all { it in 'a'..'z' || it == '_' }

    private fun fileFor(n: String): File = File(dir, "kocum_" + n + ".bin")

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        val existing = ks.getKey(alias, null)
        if (existing is SecretKey) return existing
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("ad")
        if (!validName(name)) {
            result.error("secure", "gecersiz ad", null)
            return
        }
        try {
            val f = fileFor(name!!)
            when (call.method) {
                "varMi" -> result.success(f.isFile)
                "sil" -> {
                    if (f.exists()) f.delete()
                    result.success(null)
                }
                "kaydet" -> {
                    val value = call.argument<String>("deger")
                    if (value == null || value.isEmpty() || value.length > 4096) {
                        result.error("secure", "gecersiz deger", null)
                        return
                    }
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.ENCRYPT_MODE, key())
                    val blob = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                    val tmp = File(f.path + ".tmp")
                    tmp.writeBytes(blob)
                    if (!tmp.renameTo(f)) {
                        tmp.delete()
                        result.error("secure", "yazilamadi", null)
                        return
                    }
                    result.success(null)
                }
                "oku" -> {
                    if (!f.isFile) {
                        result.success(null)
                        return
                    }
                    val blob = f.readBytes()
                    if (blob.size < 13) {
                        result.error("secure", "bozuk", null)
                        return
                    }
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0, 12)))
                    result.success(String(cipher.doFinal(blob.copyOfRange(12, blob.size)), Charsets.UTF_8))
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Ayrıntı (sır, yol) iletilmez.
            result.error("secure", "islem basarisiz", null)
        }
    }
}
''';
