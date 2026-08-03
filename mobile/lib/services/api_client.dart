import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Thrown when the API answers with an error status.
///
/// [fieldErrors] carries DRF's per-field validation messages so forms can show
/// the problem against the right input rather than dumping a blob of JSON.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final Map<String, List<String>> fieldErrors;

  const ApiException(this.statusCode, this.message, {this.fieldErrors = const {}});

  bool get isUnauthorised => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => message;
}

/// Thrown when the device can't reach the server at all.
class NoConnectionException implements Exception {
  const NoConnectionException();

  @override
  String toString() => "Can't reach Mojo and Co. Check your connection and try again.";
}

/// Thin HTTP wrapper: base URL, token header, JSON decoding, error mapping.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.uploadTimeout = const Duration(seconds: 90),
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// How long to wait before giving up on a request.
  ///
  /// There was no timeout at all, which meant a half-open connection — a phone
  /// on salon wifi that has drifted out of range, the commonest failure here —
  /// left the request hanging forever. Every screen in the app is
  /// `_loading = true` until its fetch returns, so "forever" meant a spinner
  /// that never resolves and no way back except force-quitting.
  ///
  /// A timeout surfaces as [NoConnectionException], the same as an outright
  /// refusal, because from the user's side they are the same thing and the
  /// wifi-off wording in [ErrorRetry] is right for both.
  final Duration timeout;

  /// Longer, because this one is pushing a photo up a domestic connection.
  /// 20 seconds would fail a perfectly good upload on a slow line.
  final Duration uploadTimeout;

  String? _token;

  void setToken(String? token) => _token = token;
  String? get token => _token;

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (_token != null) 'Authorization': 'Token $_token',
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final cleaned = query?.map((key, value) => MapEntry(key, value?.toString()))
      ?..removeWhere((_, value) => value == null);
    return Uri.parse('$baseUrl$path').replace(
      queryParameters: (cleaned == null || cleaned.isEmpty)
          ? null
          : cleaned.cast<String, String>(),
    );
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _http.get(_uri(path, query), headers: _headers()));

  /// Fetch raw bytes with the auth header attached.
  ///
  /// Needed for document downloads: the file sits behind a token-checked view
  /// (it is deliberately not under the publicly served media directory), so
  /// handing the URL to the system browser would just 401. Putting the token
  /// in the URL instead would defeat the point of gating it at all.
  Future<List<int>> getBytes(String path) async {
    try {
      final response = await _http
          .get(_uri(path), headers: _headers(json: false))
          .timeout(uploadTimeout);
      if (response.statusCode >= 400) {
        throw ApiException(response.statusCode, 'Could not fetch that file.');
      }
      return response.bodyBytes;
    } on SocketException {
      throw const NoConnectionException();
    } on TimeoutException {
      throw const NoConnectionException();
    }
  }

  Future<dynamic> post(String path, [Object? body]) => _send(
        () => _http.post(_uri(path), headers: _headers(), body: jsonEncode(body ?? {})),
      );

  Future<dynamic> patch(String path, Object body) => _send(
        () => _http.patch(_uri(path), headers: _headers(), body: jsonEncode(body)),
      );

  Future<dynamic> put(String path, Object body) => _send(
        () => _http.put(_uri(path), headers: _headers(), body: jsonEncode(body)),
      );

  Future<void> delete(String path) => _send(() => _http.delete(_uri(path), headers: _headers()));

  /// Multipart upload for dog photos and profile images.
  Future<dynamic> upload(
    String path, {
    required String field,
    required String filePath,
    Map<String, String> fields = const {},
  }) async {
    final request = http.MultipartRequest('POST', _uri(path))
      ..headers.addAll(_headers(json: false))
      ..fields.addAll(fields)
      ..files.add(await http.MultipartFile.fromPath(field, filePath));
    try {
      final streamed = await request.send().timeout(uploadTimeout);
      return _decode(
        await http.Response.fromStream(streamed).timeout(uploadTimeout),
      );
    } on SocketException {
      throw const NoConnectionException();
    } on TimeoutException {
      throw const NoConnectionException();
    }
  }

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    try {
      return _decode(await request().timeout(timeout));
    } on SocketException {
      throw const NoConnectionException();
    } on http.ClientException {
      throw const NoConnectionException();
    } on TimeoutException {
      // A connection that hangs open is indistinguishable from no connection
      // as far as anyone using the app is concerned.
      throw const NoConnectionException();
    }
  }

  dynamic _decode(http.Response response) {
    final status = response.statusCode;
    if (status == 204 || response.body.isEmpty) {
      if (status >= 400) throw ApiException(status, _statusMessage(status));
      return null;
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      if (status >= 400) throw ApiException(status, _statusMessage(status));
      return null;
    }

    if (status < 400) return decoded;

    // DRF returns either {"detail": "..."} or {"field": ["msg", ...]}.
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail != null) throw ApiException(status, detail.toString());

      final fieldErrors = <String, List<String>>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        fieldErrors[entry.key] =
            value is List ? value.map((v) => v.toString()).toList() : [value.toString()];
      }
      final first = fieldErrors.values.isEmpty || fieldErrors.values.first.isEmpty
          ? _statusMessage(status)
          : fieldErrors.values.first.first;
      throw ApiException(status, first, fieldErrors: fieldErrors);
    }
    throw ApiException(status, _statusMessage(status));
  }

  String _statusMessage(int status) => switch (status) {
        401 => 'Please sign in again.',
        403 => "You don't have permission to do that.",
        404 => "That couldn't be found.",
        409 => 'That conflicts with something already saved.',
        410 => 'That link has expired.',
        >= 500 => 'Mojo and Co had a problem. Please try again shortly.',
        _ => 'Something went wrong (error $status).',
      };

  /// Unwrap a DRF paginated list, tolerating a bare list too.
  static List<Map<String, dynamic>> resultsOf(dynamic payload) {
    if (payload is List) return payload.cast<Map<String, dynamic>>();
    if (payload is Map<String, dynamic> && payload['results'] is List) {
      return (payload['results'] as List).cast<Map<String, dynamic>>();
    }
    return const [];
  }
}
