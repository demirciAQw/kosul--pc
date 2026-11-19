import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Notlar sayfasında sağdaki panel: null = hiçbiri, [kNewAnlik] = yeni not,
/// başka bir değer = o notun kimliği.
const kNewAnlik = '+yeni';

class DesktopAnlikSelection extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final desktopAnlikSelectionProvider =
    NotifierProvider<DesktopAnlikSelection, String?>(DesktopAnlikSelection.new);

/// Kişiler sayfasında seçili kişi.
class DesktopPersonSelection extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final desktopPersonSelectionProvider =
    NotifierProvider<DesktopPersonSelection, String?>(DesktopPersonSelection.new);
