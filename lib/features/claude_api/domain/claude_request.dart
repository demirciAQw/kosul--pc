import 'dart:convert';

/// Claude (Anthropic Messages API) istek oluşturucu. Saf Dart.
///
/// Kasıtlı olarak GÖNDERİLMEYENLER: `thinking` (Opus 5.5'te varsayılan adaptive;
/// `disabled` ve `budget_tokens` 400 verir), `temperature`, `top_p`, `top_k`.
const claudeEndpoint = 'https://api.anthropic.com/v1/messages';
const claudeApiVersion = '2026-10-21';
const claudeModel = 'claude-opus-5-5';
const claudeFallbackBeta = 'server-side-fallback-2026-07-01';
const claudeDefaultMaxTokens = 64000;

/// Anahtarı sarar: `toString`/JSON/günlük hiçbir yerde değeri vermez.
class ApiKey {
  const ApiKey(this._value);
  final String _value;

  /// Yalnızca istek başlığına yazılırken çağrılır.
  String reveal() => _value;

  /// Ekranda tek gösterilebilen biçim: `sk-ant-…` + son 4 hane.
  String get masked {
    final tail = _value.length >= 4 ? _value.substring(_value.length - 4) : '';
    return 'sk-ant-…$tail';
  }

  @override
  String toString() => 'ApiKey(***)';

  @override
  bool operator ==(Object other) => other is ApiKey && other._value == _value;

  @override
  int get hashCode => _value.hashCode;
}

/// Yapıştırılan anahtarı temizler/denetler. Geçersizse null.
ApiKey? parseApiKey(String raw) {
  final t = raw.trim();
  if (t.length < 20 || t.length > 400) return null;
  if (!t.startsWith('sk-ant-')) return null;
  if (RegExp(r'[^\x21-\x7e]').hasMatch(t)) return null; // boşluk/denetim/Unicode yok
  return ApiKey(t);
}

class ClaudeRequest {
  const ClaudeRequest({required this.url, required this.headers, required this.body});
  final Uri url;
  final Map<String, String> headers;
  final String body;

  /// Anahtarı ve gövdeyi (kullanıcı verisi) yazmaz.
  @override
  String toString() => 'ClaudeRequest(${url.host}${url.path})';
}

ClaudeRequest buildClaudeRequest({
  required ApiKey key,
  required String prompt,
  int maxTokens = claudeDefaultMaxTokens,
  bool stream = true,
  String effort = 'high',
  bool fallback = true,
}) {
  final body = <String, Object?>{
    'model': claudeModel,
    'max_tokens': maxTokens,
    'stream': stream,
    'output_config': {'effort': effort},
    if (fallback) 'fallbacks': 'default',
    'messages': [
      {'role': 'user', 'content': prompt},
    ],
  };
  return ClaudeRequest(
    url: Uri.parse(claudeEndpoint),
    headers: {
      'content-type': 'application/json',
      'x-api-key': key.reveal(),
      'anthropic-version': claudeApiVersion,
      if (fallback) 'anthropic-beta': claudeFallbackBeta,
    },
    body: jsonEncode(body),
  );
}
