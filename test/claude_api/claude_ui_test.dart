import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/claude_api/claude_providers.dart';
import 'package:kocum/features/claude_api/data/api_key_store.dart';
import 'package:kocum/features/claude_api/data/claude_client.dart';
import 'package:kocum/features/claude_api/domain/claude_request.dart';
import 'package:kocum/features/claude_api/presentation/claude_api_card.dart';
import 'package:kocum/features/claude_api/presentation/claude_reply_sheet.dart';

const secret = 'sk-ant-api03-SIRRIN-TAMAMI-1234567890abcd';

class _T implements ClaudeTransport {
  _T(this.respond);
  final ClaudeHttpResponse Function(ClaudeRequest) respond;
  int calls = 0;
  @override
  Future<ClaudeHttpResponse> send(ClaudeRequest request, {required Duration connectTimeout}) async {
    calls++;
    return respond(request);
  }
}

ClaudeHttpResponse _res(String body, {int status = 200}) =>
    ClaudeHttpResponse(status: status, headers: const {'request-id': 'req_ui'}, body: Stream.value(utf8.encode(body)));

String _delta(String t) =>
    'event: content_block_delta\ndata: ${jsonEncode({'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': t}})}\n\n';
String _stop(String r) =>
    'event: message_delta\ndata: ${jsonEncode({'type': 'message_delta', 'delta': {'stop_reason': r}})}\n\n';

Widget _app(Widget child, FakeApiKeyStore store, ClaudeTransport t) => ProviderScope(
      overrides: [
        apiKeyStoreProvider.overrideWithValue(store),
        claudeClientProvider.overrideWithValue(ClaudeClient(transport: t)),
      ],
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );

/// Akış gerçek zaman ister (sahte zamanlı pump'ta akış bitmez): runAsync + pump.
Future<void> settleReal(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('kart: kaydet → maske (tam anahtar asla görünmez) → dene → sil', (tester) async {
    final store = FakeApiKeyStore();
    final t = _T((_) => _res('{}'));
    await tester.pumpWidget(_app(const ClaudeApiCard(), store, t));
    await tester.pumpAndSettle();
    expect(find.textContaining('reddederse'), findsOneWidget); // yedek notu

    await tester.enterText(find.byKey(const Key('claude-key-field')), 'bozuk');
    await tester.tap(find.byKey(const Key('claude-save')));
    await tester.pumpAndSettle();
    expect(await store.exists(), isFalse);
    expect(find.textContaining('benzemiyor'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('claude-key-field')), secret);
    await tester.tap(find.byKey(const Key('claude-save')));
    await tester.pumpAndSettle();
    expect((await store.read())!.reveal(), secret);
    expect(find.text('Kayıtlı anahtar: sk-ant-…abcd'), findsOneWidget);
    expect(find.textContaining('SIRRIN'), findsNothing);
    expect(find.byKey(const Key('claude-key-field')), findsNothing);

    await tester.tap(find.byKey(const Key('claude-test')));
    await tester.pumpAndSettle();
    expect(t.calls, 1);
    expect(find.textContaining('Bağlantı tamam'), findsOneWidget);

    await tester.tap(find.byKey(const Key('claude-delete')));
    await tester.pumpAndSettle();
    expect(await store.exists(), isTrue); // onay bekler
    await tester.tap(find.text('Sil'));
    await tester.pumpAndSettle();
    expect(await store.exists(), isFalse);
    expect(find.byKey(const Key('claude-key-field')), findsOneWidget);
  });

  testWidgets('kart: 401 gelirse anahtar geçersiz iletisi, anahtar ekranda yok', (tester) async {
    final store = FakeApiKeyStore(const ApiKey(secret));
    await tester.pumpWidget(_app(const ClaudeApiCard(), store, _T((_) => _res('{}', status: 401))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('claude-test')));
    await tester.pumpAndSettle();
    expect(find.textContaining('401'), findsOneWidget);
    expect(find.textContaining('SIRRIN'), findsNothing);
  });

  testWidgets('onay penceresi gönderilecek metnin aynısını gösterir', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () async => result = await confirmClaudeSend(c, '# Rapor\nBu metin gidecek'),
          child: const Text('ac'),
        ),
      ),
    ));
    await tester.tap(find.text('ac'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Anthropic\'e gönderilecek'), findsOneWidget);
    expect(find.textContaining('sağlık verisi yalnız rapor ayarı açıksa'), findsOneWidget);
    final shown = tester.widget<SelectableText>(find.byKey(const Key('claude-confirm-text'))).data;
    expect(shown, '# Rapor\nBu metin gidecek');
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('yanıt akışı: metin, kesildi uyarısı, kopyala', (tester) async {
    final store = FakeApiKeyStore(const ApiKey(secret));
    final t = _T((r) {
      expect(jsonDecode(r.body)['messages'][0]['content'], 'RAPOR');
      return _res('${_delta('Merhaba ')}${_delta('dünya')}${_stop('max_tokens')}');
    });
    await tester.pumpWidget(_app(const ClaudeReplySheet(prompt: 'RAPOR'), store, t));
    await settleReal(tester);
    expect(find.text('Merhaba dünya'), findsOneWidget);
    expect(find.textContaining('Yanıt kesildi'), findsOneWidget);
    expect(find.byKey(const Key('claude-retry')), findsNothing);
  });

  testWidgets('reddetme iletisi gösterilir', (tester) async {
    final store = FakeApiKeyStore(const ApiKey(secret));
    final t = _T((_) => _res(_stop('refusal')));
    await tester.pumpWidget(_app(const ClaudeReplySheet(prompt: 'x'), store, t));
    await settleReal(tester);
    expect(find.textContaining('Claude bu isteği yanıtlamadı'), findsOneWidget);
  });

  testWidgets('529: hata + yeniden dene düğmesi; yeniden denemede yanıt gelir', (tester) async {
    final store = FakeApiKeyStore(const ApiKey(secret));
    var n = 0;
    final t = _T((_) => ++n == 1 ? _res('', status: 529) : _res('${_delta('Tamam')}${_stop('end_turn')}'));
    await tester.pumpWidget(_app(const ClaudeReplySheet(prompt: 'x'), store, t));
    await settleReal(tester);
    expect(find.textContaining('yoğun'), findsOneWidget);
    expect(find.textContaining('req_ui'), findsOneWidget);
    await tester.tap(find.byKey(const Key('claude-retry')));
    await settleReal(tester);
    expect(find.text('Tamam'), findsOneWidget);
    expect(find.byKey(const Key('claude-reply-error')), findsNothing);
  });

  testWidgets('429: bekleme iletisi; yeniden dene yok', (tester) async {
    final store = FakeApiKeyStore(const ApiKey(secret));
    final t = _T((_) => ClaudeHttpResponse(
        status: 429, headers: const {'retry-after': '30'}, body: const Stream.empty()));
    await tester.pumpWidget(_app(const ClaudeReplySheet(prompt: 'x'), store, t));
    await settleReal(tester);
    expect(find.textContaining('30 saniye'), findsOneWidget);
    expect(find.byKey(const Key('claude-retry')), findsNothing);
  });

  test('not gövdesi: başlık, tarih ve etiket/kişi ayrıştırması etkisiz', () {
    final b = claudeNoteBody('  Yanıt ((etiket)) @ali  ', DateTime(2026, 10, 5));
    expect(b, startsWith('Claude yanıtı – 2026-10-05\n\n'));
    expect(RegExp(r'\(\(([^()\n]+?)\)\)').hasMatch(b), isFalse);
    expect(RegExp(r'(?<![\p{L}\p{N}_.])@(?:\(([^()\n]+?)\)|([\p{L}\p{N}_]+))', unicode: true).hasMatch(b), isFalse);
  });
}
