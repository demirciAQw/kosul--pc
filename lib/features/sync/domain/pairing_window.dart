import 'dart:math';

import 'sync_protocol.dart';

/// Bilgisayar ekranında gösterilen tek seferlik eşleştirme kodu.
class PairingCode {
  PairingCode({required this.code, required this.expiresAt});

  /// 6 hane, baştaki sıfırlar dahil ("004172").
  final String code;
  final DateTime expiresAt;
  int failures = 0;

  int get attemptsLeft => SyncLimits.pairingAttempts - failures;
}

enum PairingFailure {
  /// Kod yanlış; hâlâ hak var.
  wrong,

  /// Hak bitti; kod geçersiz, bilgisayarda yeni kod alınmalı.
  exhausted,
}

/// Eşleştirme penceresi: kullanıcı "Telefon eşleştir"e basınca açılır;
/// süre dolunca, kod doğru girilince ya da hak bitince kapanır. Kod ağdan
/// hiç geçmez (anahtar türetmeye girer); burada yalnızca süre ve hak sayılır.
class PairingWindow {
  PairingWindow({required Random random, required DateTime Function() now})
      : _random = random,
        _now = now;

  final Random _random;
  final DateTime Function() _now;
  PairingCode? _code;

  PairingCode open() {
    final code = _random.nextInt(1000000).toString().padLeft(6, '0');
    return _code = PairingCode(code: code, expiresAt: _now().add(SyncLimits.pairingCodeTtl));
  }

  void close() => _code = null;

  /// Geçerli kod; süresi dolduysa pencere kapanır ve null döner.
  PairingCode? get current {
    final c = _code;
    if (c == null) return null;
    if (!_now().isBefore(c.expiresAt)) {
      _code = null;
      return null;
    }
    return c;
  }

  bool get isOpen => current != null;

  /// Yanlış kanıt geldi: hak düşer; bittiyse pencere kapanır.
  PairingFailure registerFailure() {
    final c = _code;
    if (c == null) return PairingFailure.exhausted;
    c.failures++;
    if (c.attemptsLeft <= 0) {
      _code = null;
      return PairingFailure.exhausted;
    }
    return PairingFailure.wrong;
  }
}
