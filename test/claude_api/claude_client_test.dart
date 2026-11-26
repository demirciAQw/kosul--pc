import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/claude_api/data/api_key_store.dart';
import 'package:kocum/features/claude_api/data/claude_client.dart';
import 'package:kocum/features/claude_api/domain/claude_error.dart';
import 'package:kocum/features/claude_api/domain/claude_request.dart';

const secret = 'sk-ant-api03-SIRRIN-TAMAMI-1234567890abcd';
const key = ApiKey(secret);

class FakeTransport implements ClaudeTransport {
  FakeTransport(this.respond);
  final FutureOr<ClaudeHttpResponse> Function(ClaudeRequest r) respond;
  final requests = <ClaudeRequest>[];
  @override
  Future<ClaudeHttpResponse> send(ClaudeRequest request, {required Duration connectTimeout}) async {
    requests.add(request);
    return respond(request);
  }
}

String sse(List<(String, Object)> events) =>
    [for (final e in events) 'event: ${e.$1}\ndata: ${jsonEncode(e.$2)}\n\n'].join();

ClaudeHttpResponse ok(String body, {int status = 200, Map<String, String> headers = const {'request-id': 'req_abc'}, int chunk = 7}) {
  final bytes = utf8.encode(body);
  return ClaudeHttpResponse(
    status: status,
    headers: headers,
    body: Stream.fromIterable([for (var i = 0; i < bytes.length; i += chunk) bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk)]),
  );
}

void main() {
  test('akış: metin birikir (UTF-8 bölünmüş parçalarda bile), thinking gizli, durum okunur', () async {
    final body = sse([
      ('message_start', {'type': 'message_start'}),
      ('ping', {'type': 'ping'}),
      ('content_block_start', {'type': 'content_block_start', 'content_block': {'type': 'thinking'}}),
      ('content_block_delta', {'type': 'content_block_delta', 'delta': {'type': 'thinking_delta', 'thinking': 'DUSUNCE'}}),
      ('content_block_delta', {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'Şu çok güzel '}}),
      ('content_block_delta', {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'ığüş'}}),
      ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'max_tokens'}}),
      ('message_stop', {'type': 'message_stop'}),
    ]);
    final t = FakeTransport((_) => ok(body, chunk: 5));
    final parts = <String>[];
    final r = await ClaudeClient(transport: t).ask(key, 'soru', onText: parts.add);
    expect(r.text, 'Şu çok güzel ığüş');
    expect(parts.join(), r.text);
    expect(r.truncated, isTrue);
    expect(r.refused, isFalse);
    expect(t.requests.single.headers['x-api-key'], secret);
  });

  test('refusal', () async {
    final t = FakeTransport((_) => ok(sse([
          ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'refusal', 'stop_details': {'category': 'x'}}}),
        ])));
    final r = await ClaudeClient(transport: t).ask(key, 'q');
    expect(r.refused, isTrue);
    expect(r.stopCategory, 'x');
  });

  test('akış içi error olayı istisna olur; request-id taşınır, ileti sızmaz', () async {
    final t = FakeTransport((_) => ok(sse([
          ('error', {'type': 'error', 'error': {'type': 'rate_limit_error', 'message': 'ICERIK ' 'Merhaba'}}),
        ])));
    try {
      await ClaudeClient(transport: t).ask(key, 'q');
      fail('hata bekleniyordu');
    } on ClaudeApiException catch (e) {
      expect(e.kind, ClaudeErrorKind.rateLimited);
      expect(e.requestId, 'req_abc');
      expect('${e.message} $e', isNot(contains('ICERIK')));
    }
  });

  for (final c in [
    (401, ClaudeErrorKind.invalidKey),
    (403, ClaudeErrorKind.forbidden),
    (404, ClaudeErrorKind.notFound),
    (429, ClaudeErrorKind.rateLimited),
    (500, ClaudeErrorKind.server),
    (529, ClaudeErrorKind.overloaded),
  ]) {
    test('HTTP ${c.$1}: gövde okunmaz, hata sızdırmaz', () async {
      final t = FakeTransport((_) => ok(
            '{"error":{"message":"YANIT-METNI $secret"}}',
            status: c.$1,
            headers: {'request-id': 'req_9', 'retry-after': '12'},
          ));
      try {
        await ClaudeClient(transport: t).ask(key, 'GIZLI-ISTEK');
        fail('hata bekleniyordu');
      } on ClaudeApiException catch (e) {
        expect(e.kind, c.$2);
        expect(e.status, c.$1);
        expect(e.requestId, 'req_9');
        final all = '${e.message}|$e|${e.toString()}';
        for (final bad in [secret, 'SIRRIN', 'YANIT-METNI', 'GIZLI-ISTEK']) {
          expect(all, isNot(contains(bad)));
        }
        if (c.$1 == 429) expect(e.retryAfter, const Duration(seconds: 12));
      }
    });
  }

  test('request-id güvensiz karakter içeriyorsa atılır', () async {
    final t = FakeTransport((_) => ok('', status: 500, headers: {'request-id': 'x y\nz'}));
    try {
      await ClaudeClient(transport: t).ask(key, 'q');
      fail('x');
    } on ClaudeApiException catch (e) {
      expect(e.requestId, isNull);
    }
  });

  test('ağ hatası ve zaman aşımı eşlenir; hata nesnesinde anahtar yok', () async {
    final net = FakeTransport((_) => throw SocketException('bağlanamadı $secret'));
    try {
      await ClaudeClient(transport: net).ask(key, 'q');
      fail('x');
    } on ClaudeApiException catch (e) {
      expect(e.kind, ClaudeErrorKind.network);
      expect('${e.message}$e', isNot(contains('SIRRIN')));
    }
    final idle = FakeTransport((_) => ClaudeHttpResponse(status: 200, headers: const {}, body: StreamController<List<int>>().stream));
    try {
      await ClaudeClient(transport: idle, idleTimeout: const Duration(milliseconds: 20)).ask(key, 'q');
      fail('x');
    } on ClaudeApiException catch (e) {
      expect(e.kind, ClaudeErrorKind.timeout);
    }
  });

  test('bağlantı denemesi: max_tokens 16, akışsız, yanıt metni okunmaz', () async {
    final t = FakeTransport((_) => ok('{"content":[{"text":"YANIT"}]}'));
    await ClaudeClient(transport: t).testConnection(key);
    final b = jsonDecode(t.requests.single.body) as Map;
    expect(b['max_tokens'], 16);
    expect(b['stream'], false);
    final bad = FakeTransport((_) => ok('', status: 401));
    await expectLater(ClaudeClient(transport: bad).testConnection(key), throwsA(isA<ClaudeApiException>()));
  });

  test('ApiKeyStore sahte: kaydet/oku/sil, hata iletisi anahtar içermez', () async {
    final s = FakeApiKeyStore();
    expect(await s.exists(), isFalse);
    await s.save(key);
    expect(await s.read(), key);
    await s.delete();
    expect(await s.read(), isNull);
    const e = ApiKeyStoreException('Güvenli depo kullanılamadı.');
    expect(e.toString(), isNot(contains('SIRRIN')));
  });

  group('Linux dosya deposu', () {
    late Directory tmp;
    late LinuxFileApiKeyStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('kocum_anahtar');
      store = LinuxFileApiKeyStore(Directory('${tmp.path}/kocum'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    int mode(String p) => FileStat.statSync(p).mode & 0x1ff;

    test('0600 dosya, 0700 klasör; oku/üzerine yaz/sil', () async {
      await store.save(key);
      expect(mode('${tmp.path}/kocum/claude_anahtar'), 384); // 0600
      expect(mode('${tmp.path}/kocum'), 448); // 0700
      expect(await store.exists(), isTrue);
      expect(await store.read(), key);
      await store.save(const ApiKey('sk-ant-api03-YENI-YENI-YENI-YENI-0000'));
      expect((await store.read())!.reveal(), endsWith('0000'));
      expect(Directory('${tmp.path}/kocum').listSync().length, 1, reason: 'geçici dosya kalmaz');
      await store.delete();
      expect(await store.exists(), isFalse);
      expect(await store.read(), isNull);
    });

    test('izin geniş ise okuma reddedilir ve ileti anahtar içermez', () async {
      await store.save(key);
      await Process.run('chmod', ['644', '${tmp.path}/kocum/claude_anahtar']);
      try {
        await store.read();
        fail('reddedilmeliydi');
      } on ApiKeyStoreException catch (e) {
        expect(e.message, contains('izni'));
        expect('$e', isNot(contains('SIRRIN')));
      }
      await Process.run('chmod', ['640', '${tmp.path}/kocum/claude_anahtar']);
      await expectLater(store.read(), throwsA(isA<ApiKeyStoreException>()));
      await Process.run('chmod', ['600', '${tmp.path}/kocum/claude_anahtar']);
      expect(await store.read(), key);
    });

    test('sembolik bağ reddedilir', () async {
      await Directory('${tmp.path}/kocum').create();
      File('${tmp.path}/baska').writeAsStringSync('sk-ant-api03-baska-baska-baska-baska');
      Link('${tmp.path}/kocum/claude_anahtar').createSync('${tmp.path}/baska');
      expect(await store.exists(), isFalse);
      await expectLater(store.read(), throwsA(isA<ApiKeyStoreException>()));
    });

    test('dosya yok → null; standart yol XDG_CONFIG_HOME ve HOME kullanır', () async {
      expect(await store.read(), isNull);
      expect(LinuxFileApiKeyStore.standard(env: {'HOME': '/h'}).dir.path, '/h/.config/kocum');
      expect(LinuxFileApiKeyStore.standard(env: {'HOME': '/h', 'XDG_CONFIG_HOME': '/x'}).dir.path, '/x/kocum');
    });
  });
}
