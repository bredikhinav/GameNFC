import 'dart:async';

import 'package:dio/dio.dart';

import 'config.dart';
import 'errors.dart';
import 'storage.dart';

/// HTTP client. Adults authenticate with a short JWT refreshed transparently; a child's phone
/// uses its own long-lived token.
class Api {
  Api(this.store, {Dio? dio, String? baseUrl})
      : dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl ?? Config.apiBase,
              connectTimeout: const Duration(seconds: 4),
              sendTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
            ));

  final KeyValueStore store;
  final Dio dio;
  Future<bool>? _refreshing;

  /// Called when the session cannot be refreshed (the user must log in again).
  void Function()? onLoggedOut;

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body);
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body: body);
  Future<dynamic> patch(String path, [Object? body]) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<String, dynamic>? query, bool retried = false}) async {
    final token = await store.read(Keys.childToken) ?? await store.read(Keys.accessToken);
    try {
      final r = await dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(
          method: method,
          headers: {if (token != null) 'Authorization': 'Bearer $token'},
        ),
      );
      return r.data;
    } on DioException catch (e) {
      final response = e.response;
      if (response == null) throw const OfflineError();
      final error = _parse(response);
      final isAuthCall = path.startsWith('/auth/login') || path.startsWith('/auth/refresh');
      if (response.statusCode == 401 && !retried && !isAuthCall && await _refresh()) {
        return _send(method, path, body: body, query: query, retried: true);
      }
      if (response.statusCode == 401 && !isAuthCall) onLoggedOut?.call();
      if ((response.statusCode ?? 0) >= 500) throw const OfflineError();
      throw error;
    }
  }

  ApiError _parse(Response<dynamic> r) {
    final data = r.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      return ApiError(
        err['code'] as String? ?? 'error',
        status: r.statusCode ?? 0,
        details: Map<String, dynamic>.from(err['details'] as Map? ?? const {}),
      );
    }
    return ApiError('http_${r.statusCode}', status: r.statusCode ?? 0);
  }

  /// One refresh at a time, shared by concurrent requests.
  Future<bool> _refresh() {
    return _refreshing ??= () async {
      try {
        final refresh = await store.read(Keys.refreshToken);
        if (refresh == null) return false;
        final r = await dio.post<dynamic>('/auth/refresh', data: {'refresh_token': refresh});
        await saveTokens(r.data as Map<String, dynamic>);
        return true;
      } on DioException {
        return false;
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<void> saveTokens(Map<String, dynamic> tokens) async {
    await store.write(Keys.accessToken, tokens['access_token'] as String);
    await store.write(Keys.refreshToken, tokens['refresh_token'] as String);
  }
}
