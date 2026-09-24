import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small persistent key-value store for tokens and preferences.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class SecureStore implements KeyValueStore {
  const SecureStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _storage.delete(key: key) : _storage.write(key: key, value: value);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

abstract final class Keys {
  static const accessToken = 'access_token';
  static const refreshToken = 'refresh_token';
  static const childToken = 'child_token';
  static const spaceId = 'space_id';
  static const deviceId = 'device_id';
  static const pin = 'pin_hash';
  static const childCache = 'child_me_cache';
}
