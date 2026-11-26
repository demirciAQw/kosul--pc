import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import 'data/api_key_store.dart';
import 'data/claude_client.dart';
import 'domain/claude_request.dart';

/// Anahtar deposu: Android Keystore ya da Linux 0600 dosyası. Testte override edilir.
final apiKeyStoreProvider = Provider<ApiKeyStore>((ref) {
  if (isAndroid) return AndroidApiKeyStore();
  if (isLinuxDesktop) return LinuxFileApiKeyStore.standard();
  return const UnsupportedApiKeyStore();
});

final claudeClientProvider = Provider<ClaudeClient>((ref) => ClaudeClient());

/// Kayıtlı anahtarın MASKELİ gösterimi (`sk-ant-…abcd`); yoksa null. Anahtarın
/// kendisi arayüz durumuna hiç girmez.
final claudeKeyMaskProvider = FutureProvider.autoDispose<String?>((ref) async {
  final store = ref.watch(apiKeyStoreProvider);
  try {
    final ApiKey? k = await store.read();
    return k?.masked;
  } on ApiKeyStoreException catch (e) {
    throw e.message;
  }
});
