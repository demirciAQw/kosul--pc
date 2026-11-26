/// Hata türleri. İletiler SABİTTİR: anahtar, istek gövdesi ya da yanıt metni
/// hiçbir hata nesnesine/iletisine girmez; yalnız durum kodu ve `request-id`.
enum ClaudeErrorKind { invalidKey, forbidden, notFound, rateLimited, server, overloaded, network, timeout, badRequest, stream, unknown }

class ClaudeApiException implements Exception {
  const ClaudeApiException(this.kind, {this.status, this.requestId, this.retryAfter});

  final ClaudeErrorKind kind;
  final int? status;
  final String? requestId;
  final Duration? retryAfter;

  /// Yeniden dene düğmesi gösterilsin mi.
  bool get retryable =>
      kind == ClaudeErrorKind.server ||
      kind == ClaudeErrorKind.overloaded ||
      kind == ClaudeErrorKind.network ||
      kind == ClaudeErrorKind.timeout ||
      kind == ClaudeErrorKind.stream;

  factory ClaudeApiException.fromStatus(int status, {String? requestId, String? retryAfterHeader}) {
    final secs = int.tryParse((retryAfterHeader ?? '').trim());
    final retry = secs == null || secs < 0 ? null : Duration(seconds: secs > 3600 ? 3600 : secs);
    final kind = switch (status) {
      400 || 413 || 422 => ClaudeErrorKind.badRequest,
      401 => ClaudeErrorKind.invalidKey,
      403 => ClaudeErrorKind.forbidden,
      404 => ClaudeErrorKind.notFound,
      429 => ClaudeErrorKind.rateLimited,
      529 => ClaudeErrorKind.overloaded,
      >= 500 => ClaudeErrorKind.server,
      _ => ClaudeErrorKind.unknown,
    };
    return ClaudeApiException(kind, status: status, requestId: requestId, retryAfter: retry);
  }

  /// SSE `error` olayı: yalnız `error.type` okunur (ileti metni alınmaz).
  factory ClaudeApiException.fromStreamError(String? type, {String? requestId}) {
    final kind = switch (type) {
      'authentication_error' => ClaudeErrorKind.invalidKey,
      'permission_error' => ClaudeErrorKind.forbidden,
      'not_found_error' => ClaudeErrorKind.notFound,
      'rate_limit_error' => ClaudeErrorKind.rateLimited,
      'overloaded_error' => ClaudeErrorKind.overloaded,
      'api_error' => ClaudeErrorKind.server,
      'invalid_request_error' => ClaudeErrorKind.badRequest,
      _ => ClaudeErrorKind.stream,
    };
    return ClaudeApiException(kind, requestId: requestId);
  }

  /// Kullanıcıya gösterilen Türkçe ileti.
  String get message {
    final base = switch (kind) {
      ClaudeErrorKind.invalidKey => 'API anahtarı geçersiz (401). Ayarlar > Claude API\'den yeniden gir.',
      ClaudeErrorKind.forbidden => 'Bu anahtarın izni yok (403).',
      ClaudeErrorKind.notFound => 'İstenen model ya da adres bulunamadı (404).',
      ClaudeErrorKind.rateLimited =>
        'Çok fazla istek (429). ${retryAfter == null ? 'Biraz bekleyip' : '${retryAfter!.inSeconds} saniye bekleyip'} yeniden dene.',
      ClaudeErrorKind.overloaded => 'Claude şu an yoğun (529). Yeniden dene.',
      ClaudeErrorKind.server => 'Claude sunucusunda sorun var (${status ?? 5}xx). Yeniden dene.',
      ClaudeErrorKind.network => 'Ağ hatası: internete bağlanılamadı.',
      ClaudeErrorKind.timeout => 'Zaman aşımı: Claude zamanında yanıt vermedi.',
      ClaudeErrorKind.badRequest => 'İstek kabul edilmedi (${status ?? 400}).',
      ClaudeErrorKind.stream => 'Yanıt akışı yarıda kesildi.',
      ClaudeErrorKind.unknown => 'Beklenmeyen yanıt${status == null ? '' : ' ($status)'}.',
    };
    return requestId == null ? base : '$base (istek: $requestId)';
  }

  @override
  String toString() => 'ClaudeApiException(${kind.name}${status == null ? '' : ', $status'}${requestId == null ? '' : ', $requestId'})';
}
