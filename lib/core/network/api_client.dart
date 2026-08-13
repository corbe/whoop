/// Central HTTP client for the Wellness API (spec §62).
///
/// Automatically attaches `Authorization: Bearer <Cognito Access Token>`,
/// handles 401 → token refresh → safe retry, timeouts and network errors.
/// Widgets must never perform HTTP directly — they go through services that
/// use this client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';

/// Typed API error carrying HTTP status when available.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  bool get isUnauthorized => statusCode == 401;
  bool get isNetworkError => statusCode == null;

  @override
  String toString() =>
      'ApiException($statusCode): $message${body == null ? '' : ' — $body'}';
}

/// Result of a successful JSON response.
class ApiResponse<T> {
  const ApiResponse({required this.statusCode, required this.data});

  final int statusCode;
  final T data;
}

/// JSON-capable API client with auth + refresh-retry.
class ApiClient {
  ApiClient({
    required AppConfig config,
    required AuthService auth,
    http.Client? httpClient,
    Duration? timeout,
  })  : _config = config,
        _auth = auth,
        _http = httpClient ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 20);

  final AppConfig _config;
  final AuthService _auth;
  final http.Client _http;
  final Duration _timeout;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _config.wellnessApiBaseUrl;
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalized').replace(queryParameters: query);
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool authenticated = true,
  }) async {
    final uri = _uri(path, query);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (authenticated) {
      headers['Authorization'] = 'Bearer ${await _auth.getAccessToken()}';
    }
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    }
    final streamed = await _http.send(request).timeout(_timeout);
    return http.Response.fromStream(streamed).timeout(_timeout);
  }

  /// Executes a request; on 401 refreshes the token once and retries once.
  Future<ApiResponse<dynamic>> _execute(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool authenticated = true,
  }) async {
    try {
      var response = await _send(method, path, query: query, body: body, authenticated: authenticated);
      if (response.statusCode == 401 && authenticated) {
        // Token may have expired — refresh and retry exactly once.
        try {
          await _auth.refreshToken();
        } on ApiException {
          rethrow;
        } catch (e) {
          // Refresh failed (expired/revoked token): surface as 401 so callers
          // can route to re-authentication without leaking SDK types.
          throw ApiException(
            'Token refresh failed: $e',
            statusCode: 401,
          );
        }
        response = await _send(method, path, query: query, body: body, authenticated: true);
      }
      return _decode(response);
    } on ApiException {
      rethrow;
    } on TimeoutException catch (e) {
      throw ApiException('Request timed out after ${_timeout.inSeconds}s', body: e.toString());
    } on SocketException catch (e) {
      throw ApiException('Network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    } on FormatException catch (e) {
      throw ApiException('Invalid response format: ${e.message}');
    }
  }

  ApiResponse<dynamic> _decode(http.Response response) {
    dynamic data;
    if (response.body.isNotEmpty) {
      try {
        data = jsonDecode(response.body);
      } on FormatException {
        data = response.body;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ApiResponse(statusCode: response.statusCode, data: data);
    }
    throw ApiException(
      'HTTP ${response.statusCode}',
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  Future<ApiResponse<dynamic>> get(String path, {Map<String, String>? query, bool authenticated = true}) =>
      _execute('GET', path, query: query, authenticated: authenticated);

  Future<ApiResponse<dynamic>> post(String path, {Object? body, bool authenticated = true}) =>
      _execute('POST', path, body: body, authenticated: authenticated);

  Future<ApiResponse<dynamic>> put(String path, {Object? body, bool authenticated = true}) =>
      _execute('PUT', path, body: body, authenticated: authenticated);

  Future<ApiResponse<dynamic>> patch(String path, {Object? body, bool authenticated = true}) =>
      _execute('PATCH', path, body: body, authenticated: authenticated);

  Future<ApiResponse<dynamic>> delete(String path, {bool authenticated = true}) =>
      _execute('DELETE', path, authenticated: authenticated);
}
