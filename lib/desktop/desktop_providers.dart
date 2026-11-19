import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/core_providers.dart';
import 'data/external_change_watcher.dart';

/// Bilgisayar uygulamasının veri klasörü (~/.local/share/…): veritabanı,
/// fotoğraflar ve içe aktarma sırasındaki geçici dosyalar.
final desktopDataDirProvider = Provider<Directory>(
    (ref) => throw UnimplementedError('desktopDataDirProvider runDesktop() içinde override edilmeli'));

/// Veri klasörü içinde fotoğrafların durduğu alt klasör.
const desktopMediaFolder = 'media';

/// Uygulama genelinde bildirim (SnackBar) göstermek için; ör. izlenen klasörden
/// yedek gelince hangi sayfa açık olursa olsun.
final desktopMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Soldaki kalıcı gezinmenin bölümleri.
enum DesktopSection {
  notebook('Defter', Icons.menu_book_outlined, Icons.menu_book),
  books('Kitaplar', Icons.library_books_outlined, Icons.library_books),
  exams('Denemeler', Icons.assignment_outlined, Icons.assignment),
  sessions('Oturumlar', Icons.timer_outlined, Icons.timer),
  analysis('Analiz', Icons.insights_outlined, Icons.insights),
  plans('Planlar', Icons.event_note_outlined, Icons.event_note),
  notes('Notlar', Icons.sticky_note_2_outlined, Icons.sticky_note_2),
  people('Kişiler', Icons.people_outline, Icons.people),
  tags('Etiketler', Icons.sell_outlined, Icons.sell),
  changes('Claude\'un değişiklikleri', Icons.auto_fix_high_outlined, Icons.auto_fix_high),
  conflicts('Çakışmalar', Icons.merge_type_outlined, Icons.merge_type),
  settings('Ayarlar', Icons.settings_outlined, Icons.settings);

  const DesktopSection(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class DesktopSectionNotifier extends Notifier<DesktopSection> {
  @override
  DesktopSection build() => DesktopSection.notebook;

  void select(DesktopSection section) => state = section;
}

final desktopSectionProvider =
    NotifierProvider<DesktopSectionNotifier, DesktopSection>(DesktopSectionNotifier.new);

/// Dış değişiklik izleyici (kocum aracı vb.): kabuk açıkken çalışır.
final externalChangeWatcherProvider = Provider<ExternalChangeWatcher>((ref) {
  final watcher = ExternalChangeWatcher(ref.watch(appDatabaseProvider))..start();
  ref.onDispose(watcher.stop);
  return watcher;
});
