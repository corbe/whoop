/// Secure token storage.
///
/// Wraps `flutter_secure_storage` (Keychain on iOS, EncryptedSharedPreferences
/// on Android). Tokens must NEVER be stored in plaintext (spec §63).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage keys — kept in one place so typos can't silently split tokens.
abstract final class StorageKeys {
  static const String cognitoAccessToken = 'wellness.cognito.access';
  static const String cognitoIdToken = 'wellness.cognito.id';
  static const String cognitoRefreshToken = 'wellness.cognito.refresh';
  static const String wellnessPersonUuid = 'wellness.person.uuid';
  static const String chatSession = 'wellness.chat.session';
}

/// Thin wrapper over [FlutterSecureStorage] with typed accessors for the
/// tokens the app manages. Injectable so tests can use an in-memory fake.
class SecureStorage {
  SecureStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _storage;

  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> delete(String key) => _storage.delete(key: key);

  Future<void> clearAll() => _storage.deleteAll();

  // ── Token helpers ────────────────────────────────────────────────

  Future<void> saveCognitoTokens({
    required String accessToken,
    required String idToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: StorageKeys.cognitoAccessToken, value: accessToken);
    await _storage.write(key: StorageKeys.cognitoIdToken, value: idToken);
    await _storage.write(key: StorageKeys.cognitoRefreshToken, value: refreshToken);
  }

  Future<String?> getAccessToken() => _storage.read(key: StorageKeys.cognitoAccessToken);

  Future<String?> getIdToken() => _storage.read(key: StorageKeys.cognitoIdToken);

  Future<String?> getRefreshToken() => _storage.read(key: StorageKeys.cognitoRefreshToken);

  Future<void> clearCognitoTokens() async {
    await _storage.delete(key: StorageKeys.cognitoAccessToken);
    await _storage.delete(key: StorageKeys.cognitoIdToken);
    await _storage.delete(key: StorageKeys.cognitoRefreshToken);
  }

  Future<void> saveWellnessPersonUuid(String uuid) =>
      _storage.write(key: StorageKeys.wellnessPersonUuid, value: uuid);

  Future<String?> getWellnessPersonUuid() =>
      _storage.read(key: StorageKeys.wellnessPersonUuid);
}
