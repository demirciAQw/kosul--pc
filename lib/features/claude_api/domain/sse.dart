import 'dart:convert';

import 'claude_error.dart';

/// Sunucu-gönderimli olay (SSE) satırları.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;
}

/// Artımlı SSE ayrıştırıcı: parçalar satır ortasında bölünebilir; CRLF/LF/CR;
/// çok satırlı `data:` "\n" ile birleşir; `:` ile başlayan satır yorumdur.
class SseParser {
  String _buf = '';
  var _event = '';
  final _data = <String>[];
  var _sawCr = false;

  List<SseEvent> add(String chunk) {
    final out = <SseEvent>[];
    var text = _buf + chunk;
    _buf = '';
    if (_sawCr && text.startsWith('\n')) text = text.substring(1);
    _sawCr = false;
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (c != '\n' && c != '\r') continue;
      _line(text.substring(start, i), out);
      if (c == '\r') {
        if (i + 1 < text.length) {
          if (text[i + 1] == '\n') i++;
        } else {
          _sawCr = true;
        }
      }
      start = i + 1;
    }
    _buf = text.substring(start);
    return out;
  }

  /// Akış bitti: tamamlanmamış son olay (boş satırsız) da verilir.
  List<SseEvent> close() {
    final out = <SseEvent>[];
    if (_buf.isNotEmpty) {
      _line(_buf, out);
      _buf = '';
    }
    _line('', out);
    return out;
  }

  void _line(String line, List<SseEvent> out) {
    if (line.isEmpty) {
      if (_data.isNotEmpty || _event.isNotEmpty) out.add(SseEvent(_event, _data.join('\n')));
      _event = '';
      _data.clear();
      return;
    }
    if (line.startsWith(':')) return;
    final i = line.indexOf(':');
    final field = i < 0 ? line : line.substring(0, i);
    var value = i < 0 ? '' : line.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      _event = value;
    } else if (field == 'data') {
      _data.add(value);
    }
  }
}

/// Akıştan yanıtı toplar. `thinking` blokları/deltaları YOK SAYILIR; yalnız
/// `text_delta` metni birikir.
class ClaudeStreamResult {
  String text = '';
  String? stopReason;
  String? stopCategory;
  ClaudeApiException? error;

  bool get refused => stopReason == 'refusal';
  bool get truncated => stopReason == 'max_tokens';
}

class ClaudeStreamReducer {
  final result = ClaudeStreamResult();

  /// Yeni eklenen metin (varsa) döner.
  String? handle(SseEvent e) {
    if (e.data.isEmpty) return null;
    final Object? j;
    try {
      j = jsonDecode(e.data);
    } on FormatException {
      return null;
    }
    if (j is! Map) return null;
    final type = j['type'] ?? e.event;
    switch (type) {
      case 'content_block_delta':
        final d = j['delta'];
        if (d is Map && d['type'] == 'text_delta' && d['text'] is String) {
          final t = d['text'] as String;
          result.text += t;
          return t;
        }
      case 'message_delta':
        final d = j['delta'];
        if (d is Map) {
          final r = d['stop_reason'];
          if (r is String) result.stopReason = r;
          final sd = d['stop_details'];
          if (sd is Map && sd['category'] is String) result.stopCategory = sd['category'] as String;
        }
      case 'error':
        final err = j['error'];
        final et = err is Map && err['type'] is String ? err['type'] as String : null;
        result.error = ClaudeApiException.fromStreamError(et);
    }
    return null;
  }
}
