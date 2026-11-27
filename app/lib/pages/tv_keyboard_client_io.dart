import 'dart:convert';
import 'dart:io';

class KeyboardUnauthorized implements Exception {}

class KeyboardClient {
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  String? pin;
  String? host;

  void close() {
    host = null;
  }

  Future<Map<String, dynamic>> state() => _request('GET', '/kb/state');

  static Future<bool> probeHost(String ip) async {
    final client = KeyboardClient()..host = ip;
    try {
      final result = await client.state();
      return result['ok'] == true;
    } on KeyboardUnauthorized {
      // The endpoint exists; the TV has a PIN configured. The normal connect
      // flow will either use the discovered trust window or ask for the PIN.
      return true;
    } catch (_) {
      return false;
    } finally {
      client.dispose();
    }
  }

  Future<Map<String, dynamic>> snapshot() => _request('GET', '/kb/snapshot');

  Future<Map<String, dynamic>> text(Map<String, dynamic> body) => _request('POST', '/kb/text', body: body);

  Future<Map<String, dynamic>> action(String action) => _request('POST', '/kb/action', body: {'action': action});

  Future<Map<String, dynamic>> clipboard() => _request('GET', '/kb/clipboard');

  Future<Map<String, dynamic>> _request(String method, String path, {Map<String, dynamic>? body}) async {
    final ip = host;
    if (ip == null) throw StateError('TV address is not selected');
    final formattedHost = ip.contains(':') ? '[$ip]' : ip;
    final query = pin == null ? '' : '?pin=${Uri.encodeQueryComponent(pin!)}';
    final uri = Uri.parse('http://$formattedHost:53318$path$query');
    final request = await _http.openUrl(method, uri).timeout(const Duration(seconds: 3));
    if (body != null) {
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 4));
    final raw = await utf8.decoder.bind(response).join();
    if (response.statusCode == HttpStatus.unauthorized) throw KeyboardUnauthorized();
    if (response.statusCode < 200 || response.statusCode >= 300) throw HttpException('HTTP ${response.statusCode}');
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Invalid keyboard response');
    return decoded.cast<String, dynamic>();
  }

  void dispose() => _http.close(force: true);
}
