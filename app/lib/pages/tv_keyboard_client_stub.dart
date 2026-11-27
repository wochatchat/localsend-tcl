class KeyboardClient {
  String? pin;
  String? host;

  void close() {
    host = null;
  }

  Future<Map<String, dynamic>> state() => _unsupported();

  static Future<bool> probeHost(String ip) async => false;

  Future<Map<String, dynamic>> snapshot() => _unsupported();

  Future<Map<String, dynamic>> text(Map<String, dynamic> body) => _unsupported();

  Future<Map<String, dynamic>> action(String action) => _unsupported();

  Future<Map<String, dynamic>> clipboard() => _unsupported();

  Future<Map<String, dynamic>> _unsupported() async {
    throw UnsupportedError('TV keyboard networking is unavailable on this platform');
  }

  void dispose() {}
}

class KeyboardUnauthorized implements Exception {}
