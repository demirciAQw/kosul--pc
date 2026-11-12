import 'dart:collection';
import 'dart:math';

import 'sync_crypto.dart';
import 'sync_protocol.dart';

/// Bilgisayardaki açık oturum. Her istek bir sonraki sıra numarasıyla gelir;
/// aynı numara ikinci kez kabul edilmez. Ağı dinleyen biri bir isteği
/// kaydedip yeniden gönderse de (tekrar oynatma) reddedilir.
class SyncSession {
  SyncSession({required this.id, required this.phoneId, required DateTime now}) : _lastSeen = now;

  final String id;
  final String phoneId;
  int _sequence = 0;
  DateTime _lastSeen;

  int get sequence => _sequence;

  bool isExpired(DateTime now) => now.difference(_lastSeen) > SyncLimits.sessionIdle;

  /// Sıra numarası beklenen değilse false. Doğruysa hemen ayrılır (gövde
  /// okunmadan): aynı numarayla ikinci istek aynı anda gelse de geçemez.
  bool claim(int sequence, DateTime now) {
    if (sequence != _sequence + 1) return false;
    _sequence = sequence;
    _lastSeen = now;
    return true;
  }
}

/// Tek kullanımlık meydan okumalar. Her eşleştirme ve oturum isteği,
/// bilgisayarın az önce verdiği bir değeri imzalamak zorunda; eski bir
/// isteğin kopyası işe yaramaz.
class ChallengeBook {
  ChallengeBook({required Random random, required DateTime Function() now})
      : _random = random,
        _now = now;

  final Random _random;
  final DateTime Function() _now;
  final _open = LinkedHashMap<String, DateTime>();

  String issue() {
    final now = _now();
    _open.removeWhere((_, expires) => !now.isBefore(expires));
    while (_open.length >= SyncLimits.openChallenges) {
      _open.remove(_open.keys.first);
    }
    final c = randomToken(_random);
    _open[c] = now.add(SyncLimits.challengeTtl);
    return c;
  }

  /// Geçerliyse true ve değer silinir (ikinci kullanım reddedilir).
  bool consume(String challenge) {
    final expires = _open.remove(challenge);
    return expires != null && _now().isBefore(expires);
  }
}

/// Adres başına hatalı istek sayacı. Sınır aşılınca adres bir süre hiç
/// dinlenmez (kod ya da imza tahmini yavaşlar).
class FailureGuard {
  FailureGuard({required DateTime Function() now}) : _now = now;

  final DateTime Function() _now;
  final _failures = <String, List<DateTime>>{};
  final _bans = <String, DateTime>{};

  bool isBanned(String address) {
    final until = _bans[address];
    if (until == null) return false;
    if (_now().isBefore(until)) return true;
    _bans.remove(address);
    return false;
  }

  void record(String address) {
    final now = _now();
    final since = now.subtract(SyncLimits.failureWindow);
    final list = (_failures[address] ?? <DateTime>[])..removeWhere((t) => t.isBefore(since));
    list.add(now);
    _failures[address] = list;
    if (list.length >= SyncLimits.failuresPerAddress) {
      _bans[address] = now.add(SyncLimits.banDuration);
      _failures.remove(address);
    }
    // Çok sayıda farklı adres belleği şişirmesin.
    if (_failures.length > 1000) _failures.clear();
  }
}
