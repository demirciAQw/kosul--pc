/// Geriye dönük avuç reddi (Samsung Notes tarzı; saf Dart).
///
/// Avuç kalemden ÖNCE değince kalem henüz havada bile değildir; avuç sıradan
/// bir parmak gibi görünüme geçip sayfayı kaydırır. Çözüm: her aktif temasın
/// (başlangıç zamanı, konumu, ilk yarıçapı, o andaki GÖRÜNÜM DÖNÜŞÜMÜ anlık
/// görüntüsü) tutulması. Kalem hover/DOWN olunca yakın geçmişte başlamış ve
/// kaleme makul uzaklıktaki temaslar AVUÇ sayılır; çağıran görünümü o temasın
/// başladığı andaki dönüşüme geri alır, avuç kalkana dek onu yutar/kilitler.
///
/// Eşikler ÖLÇÜLMEDİ (tahmin): gerçek avuç `radiusMajor` değeri ve süreleri
/// kullanıcının tanı günlüğünden (`KocumPen ... rMaj=`) ayarlanacak.
library;

import 'dart:math' as math;

/// Kalem girince, bu süreden (ms) eski olmayan temaslar avuç adayıdır.
const double palmRecentMs = 1500;

/// Kalem konumuna bu uzaklıktan (mantıksal px) yakın temaslar avuç adayıdır.
const double palmMaxDistance = 600;

/// Aynı anda bu kadar ya da fazla (avuç sayılmamış) temas varsa hepsi avuç.
const int palmMultiTouchCount = 3;

/// Bu yarıçap (`PointerEvent.radiusMajor`) ve üstü temas hemen avuçtur. Casper
/// PAD H10: parmak ~75-143; gerçek avuç ÖLÇÜLMEDİ.
const double palmBigRadius = 260;

class PalmTouch<S> {
  PalmTouch({
    required this.pointer,
    required this.tMs,
    required this.x,
    required this.y,
    required this.radius,
    required this.snapshot,
    required this.passed,
  });

  final int pointer;
  final double tMs;
  final double x;
  final double y;
  final double radius;

  /// Temas başlarken görünüm dönüşümünün anlık görüntüsü.
  final S? snapshot;

  /// Temas görünüme geçti mi (false: baştan yutuldu, görünüm onu hiç görmedi).
  final bool passed;

  bool palm = false;
}

class PalmResult<S> {
  const PalmResult(this.selfPalm, this.flagged);

  /// Yeni temas hemen avuç sayıldı (çağıran yutmalı).
  final bool selfPalm;

  /// Bu çağrıyla yeni avuç sayılan, görünüme geçmiş temaslar (geri alma gerekir).
  final List<PalmTouch<S>> flagged;
}

class PalmRejector<S> {
  PalmRejector({this.bigRadius = palmBigRadius});

  /// Bu yarıçap (`radiusMajor`) ve üstü temas hemen avuçtur.
  final double bigRadius;

  final Map<int, PalmTouch<S>> _touches = {};

  bool isPalm(int pointer) => _touches[pointer]?.palm ?? false;

  /// Görünüme geçmiş ve hâlâ basılı bir avuç var mı (görünüm kilidi için).
  bool get anyPassedPalmDown => _touches.values.any((t) => t.palm && t.passed);

  int get activeCount => _touches.length;

  PalmResult<S> touchDown({
    required int pointer,
    required double tMs,
    required double x,
    required double y,
    required double radius,
    required S? snapshot,
    required bool passed,
  }) {
    final t = PalmTouch<S>(
      pointer: pointer,
      tMs: tMs,
      x: x,
      y: y,
      radius: radius,
      snapshot: snapshot,
      passed: passed,
    );
    _touches[pointer] = t;
    final flagged = <PalmTouch<S>>[];
    var selfPalm = false;
    if (radius >= bigRadius) {
      t.palm = true;
      selfPalm = true;
    }
    final live = _touches.values.where((e) => !e.palm).toList();
    if (live.length >= palmMultiTouchCount) {
      for (final e in live) {
        e.palm = true;
        if (e.pointer == pointer) {
          selfPalm = true;
        } else if (e.passed) {
          flagged.add(e);
        }
      }
    }
    return PalmResult<S>(selfPalm, flagged);
  }

  /// Kalem hover/DOWN oldu: yakın geçmişteki ve yakındaki temaslar avuç sayılır.
  List<PalmTouch<S>> penEntered({required double tMs, required double x, required double y}) {
    final out = <PalmTouch<S>>[];
    for (final t in _touches.values) {
      if (t.palm) continue;
      final dist = math.sqrt((t.x - x) * (t.x - x) + (t.y - y) * (t.y - y));
      if (tMs - t.tMs <= palmRecentMs && dist <= palmMaxDistance) {
        t.palm = true;
        if (t.passed) out.add(t);
      }
    }
    return out;
  }

  /// En eski temasın anlık görüntüsü (geri alınacak dönüşüm); yoksa null.
  static S? restoreTarget<S>(List<PalmTouch<S>> flagged) {
    PalmTouch<S>? oldest;
    for (final t in flagged) {
      if (t.snapshot == null) continue;
      if (oldest == null || t.tMs < oldest.tMs) oldest = t;
    }
    return oldest?.snapshot;
  }

  void touchUp(int pointer) => _touches.remove(pointer);

  void reset() => _touches.clear();
}
