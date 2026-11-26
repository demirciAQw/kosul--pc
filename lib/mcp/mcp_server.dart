import 'dart:async';
import 'dart:convert';

/// Yerel MCP sunucusu: JSON-RPC 2.0, STDIO üzerinden satır sınırlı JSON.
/// Saf Dart (Flutter'a bağlı değil). Bağlantı şeması: modelcontextprotocol.io
/// "initialize" el sıkışmalı sürümler (2024-11-05 … 2025-11-25).
///
/// Not: en yeni sürüm (2026-07-28) el sıkışmasızdır; `server/discover` çağıran
/// yeni istemci "yöntem yok" hatasını görüp `initialize`a döner (stdio geri
/// uyumluluk kuralı), bu yüzden burada yalnız eski sürümler sunulur.
const mcpSupportedVersions = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

const rpcParseError = -32700;
const rpcInvalidRequest = -32600;
const rpcMethodNotFound = -32601;
const rpcInvalidParams = -32602;
const rpcInternalError = -32603;

/// Araç içinde kullanıcıya gösterilecek (güvenli) hata: `isError: true` döner.
class McpToolError implements Exception {
  const McpToolError(this.message);
  final String message;
  @override
  String toString() => message;
}

class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
    this.readOnly = true,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final bool readOnly;
  final Future<Object?> Function(Map<String, Object?> args) run;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        'annotations': {'readOnlyHint': readOnly, 'openWorldHint': false},
      };
}

class McpServer {
  McpServer({required this.tools, this.serverName = 'kocum', this.serverVersion = '1.0.0'});

  final List<McpTool> tools;
  final String serverName;
  final String serverVersion;

  /// Bir satır girdi → tek satır yanıt (bildirimde null).
  Future<String?> handleLine(String line) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return jsonEncode(_error(null, rpcParseError, 'Geçersiz JSON'));
    }
    if (decoded is List) {
      if (decoded.isEmpty) return jsonEncode(_error(null, rpcInvalidRequest, 'Boş toplu istek'));
      final out = <Object?>[];
      for (final m in decoded) {
        final r = await _handle(m);
        if (r != null) out.add(r);
      }
      return out.isEmpty ? null : jsonEncode(out);
    }
    final r = await _handle(decoded);
    return r == null ? null : jsonEncode(r);
  }

  Future<Map<String, Object?>?> _handle(Object? msg) async {
    if (msg is! Map || msg['jsonrpc'] != '2.0' || msg['method'] is! String) {
      // Yanıt/yanlış biçim. Yanıtlara (id var, method yok, result/error var) cevap verilmez.
      if (msg is Map && msg['method'] == null && (msg.containsKey('result') || msg.containsKey('error'))) return null;
      final id = msg is Map ? _validId(msg['id']) : null;
      return _error(id, rpcInvalidRequest, 'Geçersiz JSON-RPC isteği');
    }
    final method = msg['method'] as String;
    final hasId = msg.containsKey('id');
    final id = hasId ? _validId(msg['id']) : null;
    if (hasId && id == null) return _error(null, rpcInvalidRequest, 'Geçersiz id');
    final rawParams = msg['params'];
    if (rawParams != null && rawParams is! Map) {
      return hasId ? _error(id, rpcInvalidParams, 'params nesne olmalı') : null;
    }
    final params = <String, Object?>{
      if (rawParams is Map) for (final e in rawParams.entries) e.key.toString(): e.value,
    };

    if (!hasId) return null; // bildirim (notifications/initialized vb.): yanıt yok
    try {
      final result = await _dispatch(method, params);
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on _RpcError catch (e) {
      return _error(id, e.code, e.message);
    } catch (_) {
      // Ayrıntı (veri, yol) sızmasın.
      return _error(id, rpcInternalError, 'İç hata');
    }
  }

  Future<Object?> _dispatch(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'initialize':
        final asked = params['protocolVersion'];
        if (asked is! String) throw const _RpcError(rpcInvalidParams, 'protocolVersion gerekli');
        return {
          'protocolVersion': mcpSupportedVersions.contains(asked) ? asked : mcpSupportedVersions.first,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': serverName, 'version': serverVersion},
          'instructions': 'Koçum öğrencisinin yerel verisi. Araçlar varsayılan salt okunur; sağlık verisi yoktur.',
        };
      case 'ping':
        return <String, Object?>{};
      case 'tools/list':
        return {'tools': [for (final t in tools) t.toJson()]};
      case 'tools/call':
        final name = params['name'];
        if (name is! String) throw const _RpcError(rpcInvalidParams, 'name gerekli');
        final tool = tools.where((t) => t.name == name).firstOrNull;
        if (tool == null) throw _RpcError(rpcInvalidParams, 'Bilinmeyen araç: ${_clip(name)}');
        final a = params['arguments'];
        if (a != null && a is! Map) throw const _RpcError(rpcInvalidParams, 'arguments nesne olmalı');
        final args = <String, Object?>{if (a is Map) for (final e in a.entries) e.key.toString(): e.value};
        try {
          final r = await tool.run(args);
          return {
            'content': [
              {'type': 'text', 'text': r is String ? r : jsonEncode(r)},
            ],
            'isError': false,
          };
        } on McpToolError catch (e) {
          return {
            'content': [
              {'type': 'text', 'text': e.message},
            ],
            'isError': true,
          };
        } catch (_) {
          return {
            'content': [
              {'type': 'text', 'text': 'Araç çalışırken hata oluştu.'},
            ],
            'isError': true,
          };
        }
      default:
        throw _RpcError(rpcMethodNotFound, 'Yöntem yok: ${_clip(method)}');
    }
  }

  /// STDIO döngüsü: her satır bir ileti; çıktı yalnızca JSON-RPC (günlük stderr'e).
  Future<void> serve(Stream<List<int>> input, void Function(String) write) async {
    await for (final line in input.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final r = await handleLine(line);
      if (r != null) write(r);
    }
  }
}

class _RpcError implements Exception {
  const _RpcError(this.code, this.message);
  final int code;
  final String message;
}

Object? _validId(Object? id) => (id is String || id is int) ? id : null;

String _clip(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;

Map<String, Object?> _error(Object? id, int code, String message) => {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    };
