import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/notes/domain/page_board.dart';
import 'package:kocum/features/notes/domain/page_item_geometry.dart';
import 'package:kocum/features/notes/domain/page_item_ops.dart';
import 'package:kocum/features/notes/presentation/dock_placement.dart';
import 'package:kocum/features/notes/presentation/note_page_editor.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';

PageItemRecord _item(String id, BoardRect r, {double rot = 0, PageItemKind kind = PageItemKind.text, bool deleted = false}) => PageItemRecord(
  id: id,
  pageId: 'p',
  kind: kind,
  x: r.x,
  y: r.y,
  w: r.w,
  h: r.h,
  rotation: rot,
  z: 0,
  payloadJson: '{}',
  mediaPath: null,
  deleted: deleted,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  test('zum sınırı %6000', () {
    expect(NotePageEditor.maxZoom, 60);
    expect((NotePageEditor.maxZoom * 100).round(), 6000);
  });

  group('isabet', () {
    test('dönmüş kutuda yalnız gerçek alan isabet eder', () {
      const r = BoardRect(100, 100, 200, 40);
      expect(hitRotatedRect(r, 0, 150, 120), isTrue);
      expect(hitRotatedRect(r, math.pi / 2, 200, 40), isTrue, reason: '90 derece: dikey uzar');
      expect(hitRotatedRect(r, math.pi / 2, 280, 120), isFalse);
    });

    test('en üstteki öğe kazanır, silinen ve bilinmeyen görmezden gelinir', () {
      final a = _item('a', const BoardRect(0, 0, 100, 100));
      final b = _item('b', const BoardRect(50, 50, 100, 100));
      final d = _item('d', const BoardRect(0, 0, 300, 300), deleted: true);
      expect(hitTestItems([a, b, d], 60, 60)!.id, 'b');
      expect(hitTestItems([a, b], 10, 10)!.id, 'a');
      expect(hitTestItems([a, b], 500, 500), isNull);
    });
  });

  group('dönmüş yeniden boyutlama', () {
    test('dönmemişte resizeItemRect ile aynı', () {
      const r = BoardRect(100, 100, 200, 100);
      expect(resizeRotatedRect(r, 0, ResizeHandle.right, 40, 0), resizeItemRect(r, ResizeHandle.right, 40, 0));
    });

    test('karşı köşe sayfada yerinde kalır (45 derece)', () {
      const r = BoardRect(300, 300, 200, 100);
      const rot = math.pi / 4;
      final before = fromItemLocal(r, rot, r.x, r.y); // sol-üst sabit kalmalı
      // Sağ-alt köşeyi dünya koordinatında kutunun +x yönünde 60 sürükle.
      final dx = 60 * math.cos(rot), dy = 60 * math.sin(rot);
      final n = resizeRotatedRect(r, rot, ResizeHandle.bottomRight, dx, dy);
      final after = fromItemLocal(n, rot, n.x, n.y);
      expect(after.x, closeTo(before.x, 1e-6));
      expect(after.y, closeTo(before.y, 1e-6));
      expect(n.w, greaterThan(r.w));
    });

    test('görselde oran korunur, sayfa dışına taşmaz', () {
      const r = BoardRect(100, 100, 200, 100);
      final n = resizeRotatedRect(r, 0.3, ResizeHandle.bottomRight, 5000, 5000, keepAspect: true, pageW: 1000, pageH: 1000);
      expect(n.w / n.h, closeTo(2, 1e-6));
      expect(n.w, lessThanOrEqualTo(1000));
      expect(n.h, lessThanOrEqualTo(1000));
    });
  });

  test('açı yakalama 15 derece katlarına çeker, uzakta bırakır', () {
    expect(snapAngle(44 * math.pi / 180), closeTo(45 * math.pi / 180, 1e-9));
    expect(snapAngle(38 * math.pi / 180), closeTo(38 * math.pi / 180, 1e-9));
    expect(snapAngle(math.pi * 2 + 0.01), closeTo(0, 0.05));
    const r = BoardRect(0, 0, 100, 100);
    // Kutunun tam üstünde: açı 0.
    expect(rotationFromPoint(r, 50, -200), closeTo(0, 1e-9));
    // Sağında: 90 derece.
    expect(rotationFromPoint(r, 300, 50), closeTo(math.pi / 2, 1e-9));
  });

  test('görünür alanın ortasına yerleştirir, büyükse küçültür', () {
    final r = placeInVisible(400, 300, 1000, 1000, 500, 500, 1404, 1984);
    expect(r.cx, closeTo(1250, 1));
    expect(r.w, lessThanOrEqualTo(300.5));
    final small = placeInVisible(100, 50, 0, 0, 1404, 1984, 1404, 1984);
    expect(small.w, 100);
    expect(small.cx, closeTo(702, 1));
  });

  group('serbest yuva geometrisi', () {
    const area = Size(1000, 800);
    const dock = Size(300, 60);
    const inset = EdgeInsets.all(10);

    test('oran -> konum -> oran gidiş dönüş; hep ekranda', () {
      for (final f in [0.0, 0.3, 1.0]) {
        final tl = freeDockTopLeft(f, 1 - f, area, dock, inset);
        expect(tl.dx, inInclusiveRange(10, 1000 - 10 - 300));
        expect(tl.dy, inInclusiveRange(10, 800 - 10 - 60));
        final back = freeDockFraction(tl, area, dock, inset);
        expect(back.fx, closeTo(f, 1e-9));
        expect(back.fy, closeTo(1 - f, 1e-9));
      }
    });

    test('ekran küçülünce aynı oran yine ekranın içinde', () {
      final tl = freeDockTopLeft(1, 1, const Size(400, 300), dock, inset);
      expect(tl.dx + dock.width, lessThanOrEqualTo(400 - 10));
      expect(tl.dy + dock.height, lessThanOrEqualTo(300 - 10));
    });

    test('dock ekrandan büyükse çökmez', () {
      final tl = freeDockTopLeft(0.5, 0.5, const Size(200, 100), const Size(500, 400), inset);
      expect(tl, const Offset(10, 10));
    });

    test('kenara yaklaşınca yapışma kenarı, uzaktaysa yok', () {
      expect(snapEdgeFor(const Rect.fromLTWH(300, 10, 300, 60), area), DockPosition.top);
      expect(snapEdgeFor(const Rect.fromLTWH(300, 700, 300, 60), area), DockPosition.bottom);
      expect(snapEdgeFor(const Rect.fromLTWH(20, 300, 60, 300), area), DockPosition.left);
      expect(snapEdgeFor(const Rect.fromLTWH(900, 300, 60, 300), area), DockPosition.right);
      expect(snapEdgeFor(const Rect.fromLTWH(300, 300, 300, 60), area), isNull);
    });
  });

  group('serbest yuva ayarı', () {
    test('kalıcı: dock.pos=free, oranlar ve yön geri yüklenir; kenar yedek kalır', () {
      final t = NoteToolSettings()..setDockPosition(DockPosition.left);
      t.setDockFree(0.25, 0.75);
      final prefs = t.toPrefs();
      expect(prefs['dock.pos'], 'free');
      expect(prefs['dock.edge'], 'left');
      expect(prefs['dock.x'], 0.25);
      expect(prefs['dock.y'], 0.75);
      // Soldan serbeste geçince yön (dikey) korunur.
      expect(t.dockAxis.name, 'vertical');
      final u = NoteToolSettings()..restoreSizes(Map<String, Object?>.of(prefs));
      expect(u.dockFree, isTrue);
      expect(u.dockFx, 0.25);
      expect(u.dockFy, 0.75);
      expect(u.dockPosition, DockPosition.left);
      expect(u.dockAxis.name, 'vertical');
      // Kenara yapıştır: serbestten çıkar.
      u.setDockPosition(DockPosition.top);
      expect(u.dockFree, isFalse);
      expect(u.toPrefs()['dock.pos'], 'top');
    });

    test('bozuk değerler yok sayılır, eski kayıt (yalnız dock.top) açılır', () {
      final t = NoteToolSettings()..restoreSizes({'dock.pos': 'free', 'dock.x': double.nan, 'dock.y': 9});
      expect(t.dockFree, isTrue);
      expect(t.dockFy, 1);
      final old = NoteToolSettings()..restoreSizes({'dock.top': true});
      expect(old.dockFree, isFalse);
      expect(old.dockPosition, DockPosition.top);
    });

    test('öğe aracı diğer araçlarla birbirini dışlar', () {
      final t = NoteToolSettings();
      t.setItemTool(ItemTool.text);
      expect(t.itemTool, ItemTool.text);
      t.setEraser(true);
      expect(t.itemTool, ItemTool.none);
      t.setItemTool(ItemTool.child);
      t.setItemTool(ItemTool.child); // aynı araca yeniden dokun: kapanır
      expect(t.itemTool, ItemTool.none);
      t.setItemTool(ItemTool.text);
      t.setKind(t.lastPenKind);
      expect(t.itemTool, ItemTool.none);
    });
  });
}
