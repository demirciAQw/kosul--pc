import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Platform kontrolünün TEK yeri: telefon (Android) akışı ile masaüstü (Linux)
/// akışı yalnızca burada ayrılır. Başka hiçbir dosya `Platform.isX` sormaz.
bool get isDesktop => !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);
