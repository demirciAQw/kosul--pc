import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/database/health_tables.dart';
import 'package:kocum/mcp/kocum_tools.dart';
import 'package:kocum/mcp/mcp_server.dart';

Map<String, Object?> _rpc(String method, {Object? id = 1, Object? params}) =>
    {'jsonrpc': '2.0', 'method': method, if (id != null) 'id': id, if (params != null) 'params': params};

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), 'pc');
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>?> send(McpServer s, Object? msg) async {
    final r = await s.handleLine(msg is String ? msg : jsonEncode(msg));
    return r == null ? null : jsonDecode(r) as Map<String, dynamic>;
  }

  Future<void> seed() async {
    final t = DateTime(2026, 10, 20, 10).millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      "INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, is_starred, search_text, created_at, topic_text, reason) "
      "VALUES ('q1','wrong','independent','Kitap','TYT Matematik',5,0,'turev sorusu',?, 'Türev','islem'), "
      "('q2','correct','independent','Kitap','TYT Fizik',3,0,'hiz',?, 'Hız','x'), "
      "('q3','wrong','independent','Kitap','TYT Matematik',5,0,'limit',?, 'Limit','x')",
      [t, t, t + 86400 * 5],
    );
    await db.customStatement(
      "INSERT INTO mock_exams (id, title, kind, taken_on, created_at) VALUES ('m1','Deneme 1','tyt',?,?)", [t, t]);
    await db.customStatement(
      "INSERT INTO mock_exam_sections (id, exam_id, subject, question_count, correct, wrong, blank, sort_order) "
      "VALUES ('s1','m1','TYT Matematik',40,28,8,4,0)",
    );
  }

  group('JSON-RPC', () {
    late McpServer s;
    setUp(() => s = McpServer(tools: buildKocumTools(db)));

    test('initialize: istenen sürüm destekliyse aynısı, değilse en yenisi', () async {
      for (final v in mcpSupportedVersions) {
        final r = await send(s, _rpc('initialize', params: {'protocolVersion': v, 'capabilities': {}, 'clientInfo': {}}));
        expect(r!['result']['protocolVersion'], v);
        expect(r['result']['capabilities']['tools'], isNotNull);
        expect(r['result']['serverInfo']['name'], 'kocum');
      }
      final r = await send(s, _rpc('initialize', params: {'protocolVersion': '1999-01-01'}));
      expect(r!['result']['protocolVersion'], mcpSupportedVersions.first);
      final bad = await send(s, _rpc('initialize', params: {}));
      expect(bad!['error']['code'], rpcInvalidParams);
    });

    test('bildirim yanıtsız, ping boş sonuç', () async {
      expect(await send(s, _rpc('notifications/initialized', id: null)), isNull);
      expect((await send(s, _rpc('ping')))!['result'], isEmpty);
    });

    test('bilinmeyen yöntem -32601, server/discover de (geri uyum)', () async {
      expect((await send(s, _rpc('foo/bar')))!['error']['code'], rpcMethodNotFound);
      expect((await send(s, _rpc('server/discover')))!['error']['code'], rpcMethodNotFound);
    });

    test('geçersiz JSON -32700 (id null); geçersiz istek -32600', () async {
      final r = await send(s, '{bozuk');
      expect(r!['error']['code'], rpcParseError);
      expect(r['id'], isNull);
      expect(jsonDecode((await s.handleLine('[1]'))!)[0]['error']['code'], rpcInvalidRequest);
      expect((await send(s, '{"id":3,"method":"ping"}'))!['error']['code'], rpcInvalidRequest);
      expect((await send(s, '[]'))!['error']['code'], rpcInvalidRequest);
    });

    test('tools/call: bilinmeyen araç -32602, araç hatası isError', () async {
      expect((await send(s, _rpc('tools/call', params: {'name': 'yok'})))!['error']['code'], rpcInvalidParams);
      final r = await send(s, _rpc('tools/call', params: {'name': 'yanlis_sorular', 'arguments': {'baslangic': 'dün'}}));
      expect(r!['result']['isError'], true);
    });

    test('toplu istek', () async {
      final r = await s.handleLine(jsonEncode([_rpc('ping', id: 1), _rpc('ping', id: 2), _rpc('x', id: null)]));
      expect((jsonDecode(r!) as List), hasLength(2));
    });

    test('serve: satır satır akış, çıktı yalnız JSON', () async {
      final out = <String>[];
      await s.serve(
        Stream.value(utf8.encode('${jsonEncode(_rpc('ping'))}\n\n${jsonEncode(_rpc('tools/list', id: 2))}\n')),
        out.add,
      );
      expect(out, hasLength(2));
      for (final l in out) {
        expect(jsonDecode(l)['jsonrpc'], '2.0');
      }
    });
  });

  group('salt okuma', () {
    test('--yaz yokken yazma araçları listelenmez, ham SQL aracı yok', () async {
      final s = McpServer(tools: buildKocumTools(db));
      final r = await send(s, _rpc('tools/list'));
      final names = [for (final t in r!['result']['tools']) t['name']];
      expect(names, containsAll(['ozet', 'yanlis_sorular', 'konu_analizi', 'deneme_sonuclari', 'kitap_ilerlemesi', 'ara']));
      expect(names, isNot(contains('not_ekle')));
      expect(names, isNot(contains('soru_konu_duzelt')));
      expect(names.where((n) => n.toString().contains('sql') || n.toString().contains('sorgu')), isEmpty);
      for (final t in r['result']['tools']) {
        expect(t['annotations']['readOnlyHint'], true);
      }
      expect((await send(s, _rpc('tools/call', params: {'name': 'not_ekle', 'arguments': {'metin': 'x'}})))!['error'], isNotNull);
    });

    test('yazma bayrağıyla yazma araçları listelenir, readOnlyHint false', () async {
      final r = await send(McpServer(tools: buildKocumTools(db, write: true)), _rpc('tools/list'));
      final byName = {for (final t in r!['result']['tools']) t['name']: t};
      expect(byName['not_ekle']['annotations']['readOnlyHint'], false);
      expect(byName['soru_konu_duzelt'], isNotNull);
    });

    test('lockReadOnly: veritabanı yazılamaz', () async {
      await seed();
      await lockReadOnly(db);
      await expectLater(
        db.customStatement("UPDATE question_cards SET topic_text = 'x' WHERE id = 'q1'"),
        throwsA(anything),
      );
      await expectLater(db.customStatement("DELETE FROM question_cards"), throwsA(anything));
      final n = await db.customSelect('SELECT COUNT(*) AS n FROM question_cards').getSingle();
      expect(n.read<int>('n'), 3);
    });
  });

  group('araç sonuçları', () {
    late McpServer s;
    setUp(() async {
      await seed();
      s = McpServer(tools: buildKocumTools(db));
    });

    Future<Map<String, dynamic>> call(String name, [Map<String, Object?> args = const {}]) async {
      final r = await send(s, _rpc('tools/call', params: {'name': name, 'arguments': args}));
      expect(r!['result']['isError'], false, reason: r.toString());
      return jsonDecode(r['result']['content'][0]['text']) as Map<String, dynamic>;
    }

    test('ozet', () async {
      final r = await call('ozet');
      expect(r['sorular']['toplam'], 3);
      expect(r['sorular']['duruma_gore'], {'wrong': 2, 'correct': 1});
      expect(r['denemeler'], 1);
    });

    test('yanlis_sorular: varsayılan yanlış, süzgeçler ve sayfalama', () async {
      var r = await call('yanlis_sorular');
      expect([for (final q in r['sorular']) q['id']], ['q3', 'q1']);
      r = await call('yanlis_sorular', {'en_cok': 1});
      expect(r['sayi'], 1);
      r = await call('yanlis_sorular', {'en_cok': 1, 'sayfa': 1});
      expect(r['sorular'][0]['id'], 'q1');
      r = await call('yanlis_sorular', {'konu': 'TÜREV'});
      expect([for (final q in r['sorular']) q['id']], ['q1']);
      r = await call('yanlis_sorular', {'durum': 'hepsi', 'ders': 'TYT Fizik'});
      expect([for (final q in r['sorular']) q['id']], ['q2']);
      r = await call('yanlis_sorular', {'baslangic': '2026-10-22'});
      expect([for (final q in r['sorular']) q['id']], ['q3']);
      r = await call('yanlis_sorular', {'bitis': '2026-10-20'});
      expect([for (final q in r['sorular']) q['id']], ['q1']);
      r = await call('yanlis_sorular', {'en_cok': 100000});
      expect(r['sayi'], 2); // üst sınır 100'e çekilir
    });

    test('LIKE joker karakterleri etkisiz', () async {
      final r = await send(s, _rpc('tools/call', params: {'name': 'ara', 'arguments': {'sorgu': '%_'}}));
      expect(r!['result']['isError'], true);
      final q = await call('ara', {'sorgu': 'zzz%'});
      expect(q['sorular'], isEmpty);
    });

    test('konu_analizi, deneme_sonuclari, kitap_ilerlemesi, ara', () async {
      final k = await call('konu_analizi', {'ders': 'TYT Matematik'});
      expect(k['konular'], hasLength(2));
      expect(k['konular'][0]['yanlis'], 1);
      final d = await call('deneme_sonuclari');
      expect(d['denemeler'][0]['net'], 26.0);
      expect(d['denemeler'][0]['dersler'], hasLength(1));
      expect((await call('kitap_ilerlemesi'))['kitaplar'], isEmpty);
      final a = await call('ara', {'sorgu': 'Türev'});
      expect(a['sorular'], hasLength(1));
    });

    test('sağlık verisi hiçbir araçta çıkmaz', () async {
      await db.customStatement(
        "INSERT INTO saglik_gunluk (id, gun, uyku_toplam_dk, kaynak, created_at, updated_at) VALUES ('h1','2026-10-20',4242,'manuel',1,1)",
      );
      await db.customStatement("UPDATE question_cards SET note = 'GIZLI-4242' WHERE id = 'zzz'");
      final all = <String>[];
      for (final t in buildKocumTools(db)) {
        for (final args in <Map<String, Object?>>[
          {},
          {'sorgu': 'saglik'},
          {'sorgu': '4242'},
          {'ders': 'saglik_gunluk'},
          {'konu': '4242', 'durum': 'hepsi'},
        ]) {
          try {
            all.add(jsonEncode(await t.run(args)));
          } on McpToolError catch (e) {
            all.add(e.message);
          }
        }
      }
      final text = all.join('\n');
      expect(text, isNot(contains('4242')));
      expect(text, isNot(contains('saglik')));
      expect(healthTables.every((h) => !mcpReadTables.contains(h)), isTrue);
    });
  });

  group('yazma (--yaz)', () {
    late McpServer s;
    setUp(() async {
      await seed();
      s = McpServer(tools: buildKocumTools(db, write: true, session: 'claude-mcp-test'));
    });

    test('konu düzeltme deftere claude kaynağıyla, oturumla girer ve geri alınır', () async {
      final r = await send(s, _rpc('tools/call', params: {
        'name': 'soru_konu_duzelt',
        'arguments': {'id': 'q1', 'konu': 'İntegral'},
      }));
      expect(r!['result']['isError'], false, reason: r.toString());
      var row = await db.customSelect("SELECT topic_text FROM question_cards WHERE id='q1'").getSingle();
      expect(row.read<String>('topic_text'), 'İntegral');
      final log = await db
          .customSelect("SELECT kaynak, oturum_id FROM degisiklikler WHERE tablo='question_cards' ORDER BY yerel_sira DESC LIMIT 1")
          .getSingle();
      expect(log.read<String>('kaynak'), 'claude');
      expect(log.read<String>('oturum_id'), 'claude-mcp-test');
    });

    test('değer "--" ile başlayamaz; olmayan etiket oluşturulmaz', () async {
      var r = await send(s, _rpc('tools/call', params: {
        'name': 'not_ekle',
        'arguments': {'metin': '--olustur'},
      }));
      expect(r!['result']['isError'], true);
      r = await send(s, _rpc('tools/call', params: {
        'name': 'soru_etiket_ekle',
        'arguments': {'id': 'q1', 'etiket': 'yok-boyle-etiket'},
      }));
      expect(r!['result']['isError'], true);
      final n = await db.customSelect('SELECT COUNT(*) AS n FROM tags').getSingle();
      expect(n.read<int>('n'), 0);
    });

    test('not_ekle çalışır', () async {
      final r = await send(s, _rpc('tools/call', params: {
        'name': 'not_ekle',
        'arguments': {'metin': 'Türev tekrarı yap', 'ders': 'TYT Matematik'},
      }));
      expect(r!['result']['isError'], false, reason: r.toString());
      final n = await db.customSelect('SELECT COUNT(*) AS n FROM anlik_notes').getSingle();
      expect(n.read<int>('n'), 1);
    });
  });

  test('sunucu betiği: bin/kocum_mcp.dart yoksa DB hatası (çıktı kirlenmez)', () async {
    final r = await Process.run('dart', ['run', 'bin/kocum_mcp.dart', '--db', '/yok/yok.sqlite']);
    expect(r.exitCode, 2);
    expect(r.stdout.toString().trim(), isEmpty);
    expect(r.stderr.toString(), contains('Veritabanı yok'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
