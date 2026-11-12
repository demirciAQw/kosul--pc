import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Platform kontrolünün TEK yeri: telefon (Android) akışı ile masaüstü (Linux)
/// akışı yalnızca burada ayrılır. Başka hiçbir dosya `Platform.isX` sormaz.
bool get isDesktop => !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

/// Kablosuz aktarımda karşı tarafa bildirilen platform adı ("android",
/// "linux", "windows"…). Eşleşme kuralları: lib/features/sync/domain.
String get platformName => kIsWeb ? 'web' : Platform.operatingSystem;

/// Kablosuz alma (yerel ağ sunucusu) yalnızca Linux bilgisayarda açılır;
/// Windows ve macOS'ta kapalıdır.
bool get canReceiveWirelessly => !kIsWeb && Platform.isLinux;
