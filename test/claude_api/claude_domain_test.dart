import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/claude_api/domain/claude_error.dart';
import 'package:kocum/features/claude_api/domain/claude_request.dart';
import 'package:kocum/features/claude_api/domain/sse.dart';

const secret = 'sk-ant-api03-SIRRIN-TAMAMI-1234567890abcd';

void main() {
  group('istek oluşturucu', () {
    final req = buildClaudeRequest(key: const ApiKey(secret), prompt: 'Merhaba dünya');
    final body = jsonDecode(req.body) as Map<String, dynamic>;

    test('başlıklar', () {
      expect(req.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(req.headers['content-type'], 'application/json');
      expect(req.headers['x-api-key'], secret);
      expect(req.headers['anthropic-version'], '2026-10-21');
      expect(req.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
    });

    test('gövde: model, akış, çaba, yedek; thinking ve örnekleme YOK', () {
      expect(body['model'], 'claude-opus-5-5');
      expect(body['max_tokens'], 64000);
      expect(body['stream'], true);
      expect(body['output_config'], {'effort': 'high'});
      expect(body['fallbacks'], 'default');
      expect(body['messages'], [
        {'role': 'user', 'content': 'Merhaba dünya'},
      ]);
      for (final k in ['thinking', 'temperature', 'top_p', 'top_k', 'budget_tokens']) {
        expect(body.containsKey(k), isFalse, reason: k);
      }
      expect(req.body, isNot(contains(secret)));
    });

    test('yedek kapatılırsa başlık ve alan da gider; küçük deneme isteği', () {
      final r = buildClaudeRequest(key: const ApiKey(secret), prompt: 'x', fallback: false, maxTokens: 16, stream: false);
      expect(r.headers.containsKey('anthropic-beta'), isFalse);
      final b = jsonDecode(r.body) as Map;
      expect(b.containsKey('fallbacks'), isFalse);
      expect(b['max_tokens'], 16);
      expect(b['stream'], false);
    });
  });

  group('anahtar', () {
    test('parseApiKey', () {
      expect(parseApiKey('  $secret \n'), const ApiKey(secret));
      expect(parseApiKey('sk-ant-kisa'), isNull);
      expect(parseApiKey('baska-onek-0000000000000000000'), isNull);
      expect(parseApiKey('sk-ant-api03-aaaa bbbb cccc dddd'), isNull);
      expect(parseApiKey('sk-ant-api03-aaaaaaaaaaaaaaaaaçaaa'), isNull);
    });

    test('maske yalnız önek + son 4 hane', () {
      expect(const ApiKey(secret).masked, 'sk-ant-…abcd');
      expect(const ApiKey(secret).masked, isNot(contains('SIRRIN')));
    });

    test('toString/interpolasyon/istek nesnesi anahtarı sızdırmaz', () {
      const k = ApiKey(secret);
      final req = buildClaudeRequest(key: k, prompt: 'gizli soru metni');
      for (final s in [k.toString(), '$k', 'x ${[k]}', '${{'k': k}}', req.toString(), '$req']) {
        expect(s, isNot(contains('SIRRIN')));
        expect(s, isNot(contains(secret)));
      }
      expect(req.toString(), isNot(contains('gizli soru')));
    });
  });

  group('SSE ayrıştırıcı', () {
    List<SseEvent> run(List<String> chunks) {
      final p = SseParser();
      return [for (final c in chunks) ...p.add(c), ...p.close()];
    }

    test('bölünmüş satırlar ve CRLF', () {
      final ev = run(['event: content_bl', 'ock_delta\r\nda', 'ta: {"a":1}\r', '\n\r\n', 'event: ping\ndata: {}\n\n']);
      expect(ev.map((e) => e.event), ['content_block_delta', 'ping']);
      expect(ev[0].data, '{"a":1}');
    });

    test('çok satırlı data, yorum satırı, boşluksuz alan', () {
      final ev = run([': yorum\nevent:x\ndata: a\ndata: b\ndata:\ndata: c\n\n']);
      expect(ev, hasLength(1));
      expect(ev[0].event, 'x');
      expect(ev[0].data, 'a\nb\n\nc');
    });

    test('tamamlanmamış son olay close ile gelir', () {
      expect(run(['event: e\ndata: son']).single.data, 'son');
    });

    test('tek baytlık parçalar aynı sonucu verir', () {
      const raw = 'event: a\ndata: 1\n\nevent: b\ndata: 2\n\n';
      final ev = run([for (final c in raw.split('')) c]);
      expect(ev.map((e) => e.data), ['1', '2']);
    });
  });

  group('akış toplayıcı', () {
    SseEvent d(Object j) => SseEvent('', jsonEncode(j));

    test('yalnız text_delta birikir; thinking yok sayılır; ping yok sayılır', () {
      final r = ClaudeStreamReducer();
      r.handle(const SseEvent('ping', '{"type":"ping"}'));
      r.handle(d({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}}));
      r.handle(d({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'thinking_delta', 'thinking': 'GIZLI DUSUNCE'}}));
      r.handle(d({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'abc'}}));
      expect(r.handle(d({'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'Mer'}})), 'Mer');
      r.handle(d({'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'haba'}}));
      r.handle(d({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}}));
      expect(r.result.text, 'Merhaba');
      expect(r.result.text, isNot(contains('GIZLI')));
      expect(r.result.stopReason, 'end_turn');
      expect(r.result.refused, isFalse);
    });

    test('refusal ve max_tokens', () {
      final a = ClaudeStreamReducer()
        ..handle(d({'type': 'message_delta', 'delta': {'stop_reason': 'refusal', 'stop_details': {'category': 'cyber'}}}));
      expect(a.result.refused, isTrue);
      expect(a.result.stopCategory, 'cyber');
      final b = ClaudeStreamReducer()..handle(d({'type': 'message_delta', 'delta': {'stop_reason': 'max_tokens'}}));
      expect(b.result.truncated, isTrue);
    });

    test('error olayı: yalnız tür okunur, ileti metni alınmaz', () {
      final r = ClaudeStreamReducer()
        ..handle(d({'type': 'error', 'error': {'type': 'overloaded_error', 'message': 'ICERIK-SIZMASIN'}}));
      expect(r.result.error!.kind, ClaudeErrorKind.overloaded);
      expect(r.result.error!.message, isNot(contains('SIZMASIN')));
      expect(r.result.error!.toString(), isNot(contains('SIZMASIN')));
    });

    test('bozuk JSON sessizce atlanır', () {
      final r = ClaudeStreamReducer();
      expect(r.handle(const SseEvent('x', '{bozuk')), isNull);
      expect(r.result.text, '');
    });
  });

  group('hata eşleme', () {
    test('durum kodları', () {
      ClaudeErrorKind k(int s) => ClaudeApiException.fromStatus(s).kind;
      expect(k(401), ClaudeErrorKind.invalidKey);
      expect(k(403), ClaudeErrorKind.forbidden);
      expect(k(404), ClaudeErrorKind.notFound);
      expect(k(429), ClaudeErrorKind.rateLimited);
      expect(k(500), ClaudeErrorKind.server);
      expect(k(503), ClaudeErrorKind.server);
      expect(k(529), ClaudeErrorKind.overloaded);
      expect(k(400), ClaudeErrorKind.badRequest);
      expect(ClaudeApiException.fromStatus(529).retryable, isTrue);
      expect(ClaudeApiException.fromStatus(401).retryable, isFalse);
    });

    test('429: retry-after saygı görür ve mesajda saniye geçer', () {
      final e = ClaudeApiException.fromStatus(429, retryAfterHeader: '17', requestId: 'req_1');
      expect(e.retryAfter, const Duration(seconds: 17));
      expect(e.message, contains('17 saniye'));
      expect(e.message, contains('req_1'));
      expect(ClaudeApiException.fromStatus(429, retryAfterHeader: '99999').retryAfter, const Duration(hours: 1));
      expect(ClaudeApiException.fromStatus(429, retryAfterHeader: 'yarin').retryAfter, isNull);
    });
  });
}
