import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/claude_error.dart';
import '../domain/claude_request.dart';
import '../domain/sse.dart';

/// HTTP yanıtı (başlıklar küçük harfli). Testte sahte verilir.
class ClaudeHttpResponse {
  ClaudeHttpResponse({required this.status, required this.headers, required this.body});
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> body;
}

abstract class ClaudeTransport {
  Future<ClaudeHttpResponse> send(ClaudeRequest request, {required Duration connectTimeout});
}

/// `dart:io` HttpClient: yeni paket yok. Yönlendirme izlenmez (anahtar başka
/// adrese gitmesin); yalnızca https.
class IoClaudeTransport implements ClaudeTransport {
  @override
  Future<ClaudeHttpResponse> send(ClaudeRequest request, {required Duration connectTimeout}) async {
    if (request.url.scheme != 'https' || request.url.host != 'api.anthropic.com') {
      throw StateError('Yalnızca api.anthropic.com');
    }
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final req = await client.postUrl(request.url);
      req.followRedirects = false;
      request.headers.forEach(req.headers.set);
      req.add(utf8.encode(request.body));
      final res = await req.close();
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      final controller = StreamController<List<int>>();
      res.listen(controller.add, onError: controller.addError, onDone: () {
        controller.close();
        client.close();
      }, cancelOnError: true);
      return ClaudeHttpResponse(status: res.statusCode, headers: headers, body: controller.stream);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

/// Parçalar arası sessizlik [idle]'ı aşarsa TimeoutException ile biter.
/// (`Stream.timeout` yerine elle: sahte zamanlı testlerde de güvenilir.)
Stream<List<int>> _idleGuard(Stream<List<int>> source, Duration idle) {
  final out = StreamController<List<int>>();
  StreamSubscription<List<int>>? sub;
  Timer? timer;
  void arm() {
    timer?.cancel();
    timer = Timer(idle, () {
      sub?.cancel();
      out.addError(TimeoutException('sessizlik'));
      out.close();
    });
  }

  out.onListen = () {
    arm();
    sub = source.listen(
      (c) {
        arm();
        out.add(c);
      },
      onError: out.addError,
      onDone: () {
        timer?.cancel();
        out.close();
      },
    );
  };
  out.onCancel = () {
    timer?.cancel();
    return sub?.cancel();
  };
  return out.stream;
}

final _safeId = RegExp(r'^[A-Za-z0-9_\-]{1,100}$');
String? _requestId(Map<String, String> h) {
  final v = h['request-id'];
  return v != null && _safeId.hasMatch(v) ? v : null;
}

/// Akışın son durumu.
class ClaudeReply {
  const ClaudeReply({required this.text, this.stopReason, this.stopCategory});
  final String text;
  final String? stopReason;
  final String? stopCategory;
  bool get refused => stopReason == 'refusal';
  bool get truncated => stopReason == 'max_tokens';
}

class ClaudeClient {
  ClaudeClient({ClaudeTransport? transport, this.idleTimeout = const Duration(seconds: 90)})
      : _transport = transport ?? IoClaudeTransport();

  final ClaudeTransport _transport;

  /// Akışta iki parça arası en çok bu kadar sessizlik.
  final Duration idleTimeout;

  Future<ClaudeHttpResponse> _post(ClaudeRequest r) async {
    try {
      final res = await _transport.send(r, connectTimeout: const Duration(seconds: 15)).timeout(const Duration(seconds: 60));
      if (res.status < 200 || res.status >= 300) {
        // Gövde OKUNMAZ ve saklanmaz (anahtar/istek/yanıt metni hiçbir yere gitmesin).
        unawaited(res.body.listen((_) {}, onError: (_) {}).cancel());
        throw ClaudeApiException.fromStatus(res.status,
            requestId: _requestId(res.headers), retryAfterHeader: res.headers['retry-after']);
      }
      return res;
    } on ClaudeApiException {
      rethrow;
    } on TimeoutException {
      throw const ClaudeApiException(ClaudeErrorKind.timeout);
    } on SocketException {
      throw const ClaudeApiException(ClaudeErrorKind.network);
    } on HandshakeException {
      throw const ClaudeApiException(ClaudeErrorKind.network);
    } on HttpException {
      throw const ClaudeApiException(ClaudeErrorKind.network);
    } on StateError {
      throw const ClaudeApiException(ClaudeErrorKind.unknown);
    }
  }

  /// "Bağlantıyı dene": küçük istek (max_tokens 16). Yanıt metni OKUNMAZ.
  Future<void> testConnection(ApiKey key) async {
    final req = buildClaudeRequest(key: key, prompt: 'Merhaba', maxTokens: 16, stream: false, effort: 'low');
    final res = await _post(req);
    unawaited(res.body.listen((_) {}, onError: (_) {}).cancel());
  }

  /// Yanıtı akıtır; [onText] her yeni metin parçasında çağrılır.
  Future<ClaudeReply> ask(ApiKey key, String prompt, {void Function(String delta)? onText}) async {
    final res = await _post(buildClaudeRequest(key: key, prompt: prompt));
    final rid = _requestId(res.headers);
    final parser = SseParser();
    final reducer = ClaudeStreamReducer();
    Future<void> feed(Iterable<SseEvent> events) async {
      for (final e in events) {
        final t = reducer.handle(e);
        if (t != null) onText?.call(t);
        final err = reducer.result.error;
        if (err != null) {
          throw ClaudeApiException(err.kind, requestId: rid, retryAfter: err.retryAfter);
        }
      }
    }

    try {
      await for (final chunk in _idleGuard(res.body, idleTimeout).transform(utf8.decoder)) {
        await feed(parser.add(chunk));
      }
      await feed(parser.close());
    } on ClaudeApiException {
      rethrow;
    } on TimeoutException {
      throw ClaudeApiException(ClaudeErrorKind.timeout, requestId: rid);
    } on SocketException {
      throw ClaudeApiException(ClaudeErrorKind.network, requestId: rid);
    } on HttpException {
      throw ClaudeApiException(ClaudeErrorKind.network, requestId: rid);
    } on FormatException {
      throw ClaudeApiException(ClaudeErrorKind.stream, requestId: rid);
    }
    final r = reducer.result;
    return ClaudeReply(text: r.text, stopReason: r.stopReason, stopCategory: r.stopCategory);
  }
}
