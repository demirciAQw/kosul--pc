/// Hibrit mantıksal saat (HLC): cihaz saatleri tutmasa da sıra bozulmasın.
///
/// Metin biçimi `<ms 13 hane>-<sayaç 4 hane>-<cihaz>`: düz metin
/// karşılaştırması zaman sırasıdır (SQLite'ta da). Bir cihaz karşı tarafın
/// değişikliğini aldığında kendi saatini onun üstüne taşır; sonraki
/// değişikliği her zaman daha yeni görünür (nedensellik).
class Hlc implements Comparable<Hlc> {
  const Hlc(this.ms, this.counter, this.device);

  final int ms;
  final int counter;
  final String device;

  static final _re = RegExp(r'^(\d{13})-(\d{4})-(.+)$');

  static Hlc? tryParse(String s) {
    final m = _re.firstMatch(s);
    if (m == null) return null;
    return Hlc(int.parse(m.group(1)!), int.parse(m.group(2)!), m.group(3)!);
  }

  /// Yerel bir olay: saat ileri gitmezse sayaç artar.
  Hlc tick(int nowMs) => nowMs > ms ? Hlc(nowMs, 0, device) : Hlc(ms, counter + 1, device);

  /// Karşıdan gelen bir olay görüldü: yerel saat ikisinin büyüğünü geçer.
  Hlc receive(Hlc remote, int nowMs) {
    final top = [nowMs, ms, remote.ms].reduce((a, b) => a > b ? a : b);
    if (top == ms && top == remote.ms) return Hlc(top, (counter > remote.counter ? counter : remote.counter) + 1, device);
    if (top == ms) return Hlc(top, counter + 1, device);
    if (top == remote.ms) return Hlc(top, remote.counter + 1, device);
    return Hlc(top, 0, device);
  }

  @override
  int compareTo(Hlc other) => toString().compareTo(other.toString());

  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  String toString() => '${ms.toString().padLeft(13, '0')}-${counter.toString().padLeft(4, '0')}-$device';

  @override
  bool operator ==(Object other) => other is Hlc && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;
}

/// İki HLC metnini karşılaştırır (geçersizler en eski sayılır).
int compareHlcText(String a, String b) => a.compareTo(b);
