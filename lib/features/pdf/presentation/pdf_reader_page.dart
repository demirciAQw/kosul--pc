import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart' as r; // pdfrx YALNIZ data/ ve bu dosyada

import '../../ink/domain/ink_models.dart';
import '../../../core/di/core_providers.dart';
import '../pdf_providers.dart';
import 'pdf_ink_input.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';

/// PDF okuyucu: dikey kaydırma, parmakla yakınlaştırma, küçük resim şeridi,
/// sayfa göstergesi ve her sayfanın üstünde kalem katmanı.
class PdfReaderPage extends ConsumerWidget {
  const PdfReaderPage({super.key, required this.documentId});
  final String documentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(pdfOpenInfoProvider(documentId));
    return info.when(
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('PDF açılamadı: $e')),
      ),
      data: (i) {
        if (i == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Bu PDF bulunamadı.')),
          );
        }
        if (i.path == null) {
          return Scaffold(
            appBar: AppBar(title: Text(i.record.title)),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Bu PDF\'in dosyası bu cihazda yok. Aynı PDF\'i "PDF ekle" ile içe aktar; çizgilerin yerinde durur.',
                ),
              ),
            ),
          );
        }
        return PdfReaderView(info: i);
      },
    );
  }
}

const _colors = <int>[
  0xFF1B1B1F,
  0xFF1565C0,
  0xFFC62828,
  0xFF2E7D32,
  0xFFF9A825,
];
const _widths = <double>[2, 4, 8];

class PdfReaderView extends ConsumerStatefulWidget {
  const PdfReaderView({super.key, required this.info});
  final PdfOpenInfo info;

  @override
  ConsumerState<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends ConsumerState<PdfReaderView> {
  late final PdfInkSession _session;
  final _viewer = r.PdfViewerController();
  final _page = ValueNotifier<int>(1);
  bool _thumbs = false;
  InkTool _tool = InkTool.pen;
  int _color = _colors.first;
  double _width = _widths[1];

  @override
  void initState() {
    super.initState();
    _session = PdfInkSession(
      documentId: widget.info.record.id,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
    );
    _applyBrush();
  }

  @override
  void dispose() {
    _session.dispose();
    _page.dispose();
    super.dispose();
  }

  void _applyBrush() {
    final w = _tool == InkTool.highlighter ? _width * 4 : _width;
    _session.setBrush(InkBrush(tool: _tool, color: _color, width: w));
  }

  List<Widget> _overlays(BuildContext context, Rect rect, r.PdfPage page) => [
    PdfPageInkLayer(
      key: ValueKey('ink-${page.pageNumber}'),
      session: _session,
      page: page.pageNumber - 1,
      pageWidth: page.width,
      pageHeight: page.height,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final rec = widget.info.record;
    final path = widget.info.path!;
    return Scaffold(
      appBar: AppBar(
        title: Text(rec.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('pdf-thumbs-toggle'),
            tooltip: 'Küçük resimler',
            icon: Icon(
              _thumbs ? Icons.view_sidebar : Icons.view_sidebar_outlined,
            ),
            onPressed: () => setState(() => _thumbs = !_thumbs),
          ),
        ],
      ),
      body: Column(
        children: [
          _Toolbar(
            session: _session,
            tool: _tool,
            color: _color,
            width: _width,
            onTool: (t) => setState(() {
              _tool = t;
              _applyBrush();
            }),
            onColor: (c) => setState(() {
              _color = c;
              _applyBrush();
            }),
            onWidth: (w) => setState(() {
              _width = w;
              _applyBrush();
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                if (_thumbs)
                  _ThumbStrip(
                    path: path,
                    current: _page,
                    onTap: (n) => _viewer.goToPage(pageNumber: n),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      PdfInkInput(
                        session: _session,
                        child: r.PdfViewer.file(
                          path,
                          controller: _viewer,
                          // Sayfa boyutu kalem koordinatının tabanı: tahmin değil, kesin olmalı.
                          useProgressiveLoading: false,
                          params: r.PdfViewerParams(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            pageOverlaysBuilder: _overlays,
                            onPageChanged: (n) {
                              if (n != null) _page.value = n;
                            },
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 12,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: Center(
                            child: ValueListenableBuilder<int>(
                              valueListenable: _page,
                              builder: (_, n, _) => Container(
                                key: const Key('pdf-page-indicator'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  '$n / ${rec.pageCount}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.session,
    required this.tool,
    required this.color,
    required this.width,
    required this.onTool,
    required this.onColor,
    required this.onWidth,
  });

  final PdfInkSession session;
  final InkTool tool;
  final int color;
  final double width;
  final ValueChanged<InkTool> onTool;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget toolBtn(InkTool t, IconData icon, String tip) => IconButton(
      key: Key('pdf-tool-${t.name}'),
      tooltip: tip,
      isSelected: tool == t,
      icon: Icon(icon),
      onPressed: () => onTool(t),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          const SizedBox(width: 8),
          toolBtn(InkTool.pen, Icons.edit_outlined, 'Kalem'),
          toolBtn(InkTool.highlighter, Icons.border_color_outlined, 'Fosforlu'),
          toolBtn(InkTool.eraser, Icons.auto_fix_normal_outlined, 'Silgi'),
          const SizedBox(width: 8),
          for (final c in _colors)
            InkWell(
              key: Key('pdf-color-${c.toRadixString(16)}'),
              customBorder: const CircleBorder(),
              onTap: () => onColor(c),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: Color(c),
                  child: color == c
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
                ),
              ),
            ),
          const SizedBox(width: 8),
          for (final w in _widths)
            InkWell(
              key: Key('pdf-width-${w.toInt()}'),
              customBorder: const CircleBorder(),
              onTap: () => onWidth(w),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Container(
                  width: 8 + w * 2,
                  height: 8 + w * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: width == w ? cs.primary : cs.outline,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 8),
          ListenableBuilder(
            listenable: session,
            builder: (_, _) => Row(
              children: [
                IconButton(
                  key: const Key('pdf-undo'),
                  tooltip: 'Geri al',
                  icon: const Icon(Icons.undo_rounded),
                  onPressed: session.canUndo ? session.undo : null,
                ),
                IconButton(
                  key: const Key('pdf-redo'),
                  tooltip: 'Yinele',
                  icon: const Icon(Icons.redo_rounded),
                  onPressed: session.canRedo ? session.redo : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbStrip extends StatelessWidget {
  const _ThumbStrip({
    required this.path,
    required this.current,
    required this.onTap,
  });
  final String path;
  final ValueNotifier<int> current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: const Key('pdf-thumb-strip'),
      width: 108,
      child: r.PdfDocumentViewBuilder.file(
        path,
        builder: (context, doc) {
          if (doc == null) return const SizedBox.shrink();
          return ValueListenableBuilder<int>(
            valueListenable: current,
            builder: (_, cur, _) => ListView.builder(
              itemCount: doc.pages.length,
              itemBuilder: (_, i) => InkWell(
                onTap: () => onTap(i + 1),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: cur == i + 1
                                ? cs.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: AspectRatio(
                          aspectRatio: doc.pages[i].width / doc.pages[i].height,
                          child: r.PdfPageView(
                            document: doc,
                            pageNumber: i + 1,
                            maximumDpi: 60,
                          ),
                        ),
                      ),
                      Text(
                        '${i + 1}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
