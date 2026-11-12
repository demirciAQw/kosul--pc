import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bilgisayar uygulamasının veri klasörü (~/.local/share/…): veritabanı,
/// fotoğraflar ve içe aktarma sırasındaki geçici dosyalar.
final desktopDataDirProvider = Provider<Directory>(
    (ref) => throw UnimplementedError('desktopDataDirProvider runDesktop() içinde override edilmeli'));

/// Soldaki kalıcı gezinmenin bölümleri.
enum DesktopSection {
  notebook('Defter', Icons.menu_book_outlined, Icons.menu_book),
  books('Kitaplar', Icons.library_books_outlined, Icons.library_books),
  exams('Denemeler', Icons.assignment_outlined, Icons.assignment),
  sessions('Oturumlar', Icons.timer_outlined, Icons.timer),
  analysis('Analiz', Icons.insights_outlined, Icons.insights),
  plans('Planlar', Icons.event_note_outlined, Icons.event_note),
  notes('Notlar', Icons.sticky_note_2_outlined, Icons.sticky_note_2),
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
