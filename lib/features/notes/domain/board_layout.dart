import 'dart:math' as math;

import 'page_board.dart';

/// Pano yerleşimi ve bağlantı geometrisi (saf Dart, v23).
/// Birim: pano birimi. Kart varsayılanı [boardCardW] x [boardCardH].

/// Konu ağacındaki düğüm. [parentId] listede yoksa ya da null ise kök sayılır.
class TreeNode {
  const TreeNode(this.id, this.parentId, {this.sortOrder = 0, this.w, this.h});
  final String id;
  final String? parentId;
  final int sortOrder;

  /// null = varsayılan kart boyutu.
  final double? w;
  final double? h;
}

/// Ağacı hiyerarşik yerleştirir: kök(ler) üstte, çocuklar bir alt sırada; yaprak
/// kartlar soldan sağa dizilir, ebeveyn çocuklarının üstünde ORTALANIR. Aynı satırda
/// kartlar arası yatay boşluk [gapX], satırlar arası dikey boşluk [gapY]. Hiçbir
/// iki kart çakışmaz (her yaprak kendi sütununu alır; satır yüksekliği o satırdaki en
/// yüksek karta uyar). Ata-torun döngüsü olan ya da yinelenen kimlikli düğümler yok
/// sayılmaz: döngü bir kökten kesilir, her düğüm yerleşir.
/// Dönüş: düğüm kimliği -> dikdörtgen; sol-üst (0, 0)'dan başlar.
Map<String, BoardRect> layoutTree(
  List<TreeNode> nodes, {
  double cardW = boardCardW,
  double cardH = boardCardH,
  double gapX = 80,
  double gapY = 160,
}) {
  final byId = <String, TreeNode>{};
  for (final n in nodes) {
    byId.putIfAbsent(n.id, () => n);
  }
  final children = <String, List<TreeNode>>{};
  final roots = <TreeNode>[];
  final order = {for (var i = 0; i < nodes.length; i++) nodes[i].id: i};
  int cmp(TreeNode a, TreeNode b) {
    final c = a.sortOrder.compareTo(b.sortOrder);
    return c != 0 ? c : order[a.id]!.compareTo(order[b.id]!);
  }

  for (final n in byId.values) {
    final p = n.parentId;
    if (p != null && p != n.id && byId.containsKey(p)) {
      (children[p] ??= []).add(n);
    } else {
      roots.add(n);
    }
  }
  // Döngüdeki (köke ulaşamayan) düğümleri kurtar: ziyaret edilmemiş her düğüm kök olur.
  final reach = <String>{};
  void mark(TreeNode n) {
    if (!reach.add(n.id)) return;
    for (final c in children[n.id] ?? const <TreeNode>[]) {
      mark(c);
    }
  }

  roots.sort(cmp);
  for (final r in roots) {
    mark(r);
  }
  for (final n in byId.values.toList()..sort(cmp)) {
    if (!reach.contains(n.id)) {
      // Döngü: ebeveyn bağını kes, kök yap.
      children[n.parentId]?.removeWhere((c) => c.id == n.id);
      roots.add(n);
      mark(n);
    }
  }
  for (final l in children.values) {
    l.sort(cmp);
  }

  double wOf(TreeNode n) => n.w ?? cardW;
  double hOf(TreeNode n) => n.h ?? cardH;

  // Derinlik -> satır yüksekliği.
  final depthOf = <String, int>{};
  final rowH = <int, double>{};
  void depth(TreeNode n, int d) {
    depthOf[n.id] = d;
    rowH[d] = math.max(rowH[d] ?? 0, hOf(n));
    for (final c in children[n.id] ?? const <TreeNode>[]) {
      depth(c, d + 1);
    }
  }

  for (final r in roots) {
    depth(r, 0);
  }
  final rowTop = <int, double>{};
  var y = 0.0;
  for (var d = 0; d <= (rowH.keys.isEmpty ? -1 : rowH.keys.reduce(math.max)); d++) {
    rowTop[d] = y;
    y += (rowH[d] ?? 0) + gapY;
  }

  // x: yapraklar soldan sağa; ebeveyn çocukların orta noktasında. Ebeveyn, çocuk
  // aralığından geniş olabilir: o zaman alt ağaç bir sonraki sütundan başlar.
  final centerX = <String, double>{};
  var cursor = 0.0;
  void place(TreeNode n) {
    final kids = children[n.id] ?? const <TreeNode>[];
    if (kids.isEmpty) {
      centerX[n.id] = cursor + wOf(n) / 2;
      cursor += wOf(n) + gapX;
      return;
    }
    final start = cursor;
    for (final c in kids) {
      place(c);
    }
    final mid = (centerX[kids.first.id]! + centerX[kids.last.id]!) / 2;
    // Ebeveyn kartı çocuk kartlarının kapladığı genişlikten dar kalırsa ortalanır;
    // taşarsa soldan [start]'a yaslanır ve imleç ileri itilir (çakışma olmasın).
    final left = mid - wOf(n) / 2;
    if (left < start) {
      final shift = start - left;
      _shiftSubtree(n, children, centerX, shift, skipSelf: true);
      centerX[n.id] = start + wOf(n) / 2;
      cursor += shift;
    } else {
      centerX[n.id] = mid;
    }
    // Ebeveyn kartı çocuk aralığından geniş kalmış olabilir: sonraki kardeş onun ötesinden başlasın.
    cursor = math.max(cursor, centerX[n.id]! + wOf(n) / 2 + gapX);
  }

  for (final r in roots) {
    place(r);
  }

  return {
    for (final n in byId.values)
      n.id: BoardRect(centerX[n.id]! - wOf(n) / 2, rowTop[depthOf[n.id]!]!, wOf(n), hOf(n)),
  };
}

void _shiftSubtree(TreeNode n, Map<String, List<TreeNode>> children, Map<String, double> cx, double dx, {bool skipSelf = false}) {
  if (!skipSelf) cx[n.id] = cx[n.id]! + dx;
  for (final c in children[n.id] ?? const <TreeNode>[]) {
    _shiftSubtree(c, children, cx, dx);
  }
}

/// Otomatik düzen: bağlantılı sayfalar (child/konu ve elle bağlantılar; ilk gelen
/// bağlantı üst-alt ilişkisini kurar, döngü kapatan bağlantı yok sayılır) ağaç olarak
/// [layoutTree] ile, bağlantısızlar ağacın altında ızgara olarak dizilir.
/// [pages] sırası korunur (kararlı). Dönüş: sayfa kimliği -> kart dikdörtgeni.
Map<String, BoardRect> autoArrange(
  List<BoardCard> pages,
  List<({String from, String to})> links, {
  double cardW = boardCardW,
  double cardH = boardCardH,
  double gapX = 80,
  double gapY = 160,
}) {
  final ids = [for (final p in pages) p.pageId];
  final idSet = ids.toSet();
  final parent = <String, String>{};
  bool reaches(String from, String target) {
    // target, from'un atası mı? (from'dan yukarı çık)
    final seen = <String>{};
    String? cur = from;
    while (cur != null && seen.add(cur)) {
      if (cur == target) return true;
      cur = parent[cur];
    }
    return false;
  }

  final linked = <String>{};
  for (final l in links) {
    if (!idSet.contains(l.from) || !idSet.contains(l.to) || l.from == l.to) continue;
    linked..add(l.from)..add(l.to);
    if (parent.containsKey(l.to)) continue; // her sayfanın tek üstü
    if (reaches(l.from, l.to)) continue; // döngü
    parent[l.to] = l.from;
  }
  BoardCard byId(String id) => pages.firstWhere((p) => p.pageId == id);
  final tree = <TreeNode>[
    for (var i = 0; i < ids.length; i++)
      if (linked.contains(ids[i]))
        TreeNode(ids[i], parent[ids[i]], sortOrder: i, w: byId(ids[i]).w, h: byId(ids[i]).h),
  ];
  final out = layoutTree(tree, cardW: cardW, cardH: cardH, gapX: gapX, gapY: gapY);

  final loose = [for (final p in pages) if (!linked.contains(p.pageId)) p];
  if (loose.isNotEmpty) {
    final top = out.isEmpty ? 0.0 : out.values.map((r) => r.bottom).reduce(math.max) + gapY;
    final cols = math.max(1, math.sqrt(loose.length).ceil());
    final rowHeights = <int, double>{};
    for (var i = 0; i < loose.length; i++) {
      final r = i ~/ cols;
      rowHeights[r] = math.max(rowHeights[r] ?? 0, loose[i].h ?? cardH);
    }
    final rowTops = <int, double>{};
    var y = top;
    for (var r = 0; r <= (loose.length - 1) ~/ cols; r++) {
      rowTops[r] = y;
      y += rowHeights[r]! + gapY;
    }
    final colLefts = <int, double>{};
    final colWidths = <int, double>{};
    for (var i = 0; i < loose.length; i++) {
      final c = i % cols;
      colWidths[c] = math.max(colWidths[c] ?? 0, loose[i].w ?? cardW);
    }
    var x = 0.0;
    for (var c = 0; c < cols; c++) {
      colLefts[c] = x;
      x += (colWidths[c] ?? cardW) + gapX;
    }
    for (var i = 0; i < loose.length; i++) {
      out[loose[i].pageId] = BoardRect(colLefts[i % cols]!, rowTops[i ~/ cols]!, loose[i].w ?? cardW, loose[i].h ?? cardH);
    }
  }
  return out;
}

/// İki kartı birleştiren çizginin uçları: her kartın dört kenar orta noktasından
/// birbirine EN YAKIN iki nokta. Eşitlikte sıra: üst, sağ, alt, sol (kararlı).
({BoardPoint from, BoardPoint to}) edgePoints(BoardRect a, BoardRect b) {
  List<BoardPoint> mids(BoardRect r) => [
        BoardPoint(r.cx, r.y),
        BoardPoint(r.right, r.cy),
        BoardPoint(r.cx, r.bottom),
        BoardPoint(r.x, r.cy),
      ];
  var best = (from: mids(a).first, to: mids(b).first);
  var bestD = double.infinity;
  for (final p in mids(a)) {
    for (final q in mids(b)) {
      final d = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y);
      if (d < bestD) {
        bestD = d;
        best = (from: p, to: q);
      }
    }
  }
  return best;
}

/// [near] kartının sağında, diğer kartlarla ([others]) çakışmayan ilk boş yer: önce hemen
/// sağı, doluysa aşağı doğru [gap] adımlarla, o da dolu olursa daha sağ sütun.
/// Alt sayfa kartını ebeveynin yanına koymak için. Hep sonuç döner (en fazla 64 deneme).
BoardRect freeSlotNear(
  BoardRect near,
  Iterable<BoardRect> others, {
  double w = boardCardW,
  double h = boardCardH,
  double gap = 80,
}) {
  final list = others.toList();
  for (var col = 0; col < 8; col++) {
    final x = near.right + gap + col * (w + gap);
    for (var row = 0; row < 8; row++) {
      final c = BoardRect(x, near.y + row * (h + gap), w, h);
      if (!list.any(c.overlaps)) return c;
    }
  }
  final bottom = list.fold<double>(near.bottom, (m, r) => math.max(m, r.bottom));
  return BoardRect(near.x, bottom + gap, w, h);
}
