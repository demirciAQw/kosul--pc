/// Kablosuz aktarımın ağ kuralları: yalnızca yerel ağ.
///
/// Kabul: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 (IPv4);
/// fc00::/7, fe80::/10 (IPv6). Ret: İnternet adresleri ve 100.64.0.0/10
/// (operatör NAT'ı ve Tailscale gibi VPN'ler: ev ağının dışından gelebilir).
/// Aynı bilgisayardan gelen istek (127.0.0.1) de reddedilir; bilgisayardaki
/// bir tarayıcı sayfası ya da program telefon gibi davranamasın. Testler
/// bunu açıkça açar.
library;

bool isPrivateNetworkAddress(List<int> raw) {
  if (raw.length == 4) {
    final a = raw[0], b = raw[1];
    return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
  }
  if (raw.length == 16) {
    if (_isV4Mapped(raw)) return isPrivateNetworkAddress(raw.sublist(12));
    return (raw[0] & 0xfe) == 0xfc || (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80);
  }
  return false;
}

bool isLoopbackAddress(List<int> raw) {
  if (raw.length == 4) return raw[0] == 127;
  if (raw.length == 16) {
    if (_isV4Mapped(raw)) return raw[12] == 127;
    for (var i = 0; i < 15; i++) {
      if (raw[i] != 0) return false;
    }
    return raw[15] == 1;
  }
  return false;
}

/// Bağlantı kabul edilebilir mi? [allowLoopback] yalnızca testler içindir.
bool isAcceptedPeer(List<int> raw, {bool allowLoopback = false}) =>
    isPrivateNetworkAddress(raw) || (allowLoopback && isLoopbackAddress(raw));

bool _isV4Mapped(List<int> raw) {
  for (var i = 0; i < 10; i++) {
    if (raw[i] != 0) return false;
  }
  return raw[10] == 0xff && raw[11] == 0xff;
}

/// "192.168.1.20" → [192, 168, 1, 20]; geçersizse null.
List<int>? parseIpv4(String text) {
  final parts = text.trim().split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3 || !RegExp(r'^\d+$').hasMatch(p)) return null;
    final v = int.parse(p);
    if (v > 255) return null;
    out.add(v);
  }
  return out;
}

/// "Host" başlığı bir IP adresi olmalı, alan adı değil. Kötü niyetli bir web
/// sayfası kendi alan adını bu bilgisayara yönlendirip tarayıcı üzerinden
/// istek atamasın (DNS rebinding).
bool isIpLiteralHost(String? host) {
  if (host == null || host.isEmpty) return false;
  var h = host.trim();
  if (h.startsWith('[')) {
    final end = h.indexOf(']');
    if (end < 0) return false;
    h = h.substring(1, end);
    return h.contains(':') && RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(h);
  }
  final colon = h.indexOf(':');
  if (colon >= 0 && h.indexOf(':', colon + 1) < 0) h = h.substring(0, colon); // "ip:port"
  if (h.contains(':')) return RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(h); // köşeli parantezsiz IPv6
  return parseIpv4(h) != null;
}

/// Elle yazılan bilgisayar adresi: "192.168.1.20" ya da "192.168.1.20:47321".
/// Yalnızca yerel ağ IPv4 adresi kabul edilir.
({String host, int port})? parseComputerAddress(String text, {required int defaultPort, bool allowLoopback = false}) {
  final t = text.trim();
  final colon = t.lastIndexOf(':');
  final hostPart = colon < 0 ? t : t.substring(0, colon);
  var port = defaultPort;
  if (colon >= 0) {
    final p = int.tryParse(t.substring(colon + 1));
    if (p == null || p <= 0 || p > 65535) return null;
    port = p;
  }
  final raw = parseIpv4(hostPart);
  if (raw == null || !isAcceptedPeer(raw, allowLoopback: allowLoopback)) return null;
  return (host: raw.join('.'), port: port);
}

/// Tarayıcıdan gelen istek mi? Tarayıcılar bu başlıkları her zaman ekler;
/// Koçum hiçbirini göndermez. (Bir web sayfasının arka planda istek atması
/// böyle kesilir.)
bool looksLikeBrowserRequest(String? Function(String name) header) =>
    header('origin') != null ||
    header('sec-fetch-site') != null ||
    header('sec-fetch-mode') != null ||
    header('referer') != null;
