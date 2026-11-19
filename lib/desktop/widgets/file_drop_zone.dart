import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

/// Pencereye sürüklenen dosyaları alır (bilgisayar uygulaması). Paket yalnızca
/// burada kullanılır: kaldırmak için bu dosyayı `child`'ı döndüren bir
/// sarmalayıcıya çevirmek yeter.
class FileDropZone extends StatefulWidget {
  const FileDropZone({super.key, required this.onFiles, required this.child, this.extensions});

  /// Bırakılan dosyaların yolları ([extensions] varsa yalnızca o uzantılılar).
  final void Function(List<String> paths) onFiles;
  final Widget child;
  final Set<String>? extensions;

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (d) {
        setState(() => _over = false);
        final ext = widget.extensions;
        final paths = [
          for (final f in d.files)
            if (ext == null || ext.contains(f.path.split('.').last.toLowerCase())) f.path,
        ];
        if (paths.isNotEmpty) widget.onFiles(paths);
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _over ? Border.all(color: theme.colorScheme.primary, width: 2) : null,
          color: _over ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: widget.child,
      ),
    );
  }
}
