import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/app/tablet.dart';
import 'package:kocum/features/question_bank/question_bank_providers.dart';

/// Kenardan kenara çizimde tablet çerçevesinin içeriği sistem alt çubuğunun
/// (görev çubuğu / gezinme) üstünde bitirdiğini sınar: yüzen araç yuvası
/// çubuğun altında kalmıştı.
void main() {
  testWidgets('tablet çerçevesi içeriği alt çubuğun üstünde bitirir', (t) async {
    const bottomInset = 96.0;
    debugAndroidOverride = true;
    addTearDown(() => debugAndroidOverride = null);
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);

    await t.pumpWidget(
      ProviderScope(
        overrides: [dueCountProvider.overrideWith((ref) => Stream.value(0))],
        child: MaterialApp(
          builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c).copyWith(
              padding: const EdgeInsets.only(bottom: bottomInset),
              viewPadding: const EdgeInsets.only(bottom: bottomInset),
            ),
            child: w!,
          ),
          home: const TabletFrame(
            selected: RailItem.defterler,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(key: Key('dip'), width: 10, height: 10),
            ),
          ),
        ),
      ),
    );
    await t.pump();

    final dip = t.getRect(find.byKey(const Key('dip')));
    expect(dip.bottom, lessThanOrEqualTo(800 - bottomInset + 0.5));

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 20));
  });
}
