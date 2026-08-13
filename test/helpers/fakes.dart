/// Test doubles for the auth layer.
library;

import 'package:amplify_auth_cognito_dart/amplify_auth_cognito_dart.dart'
    show CognitoSignInDetails;
import 'package:amplify_flutter/amplify_flutter.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/storage/secure_storage.dart';

/// In-memory Cognito gateway for tests (no AWS calls).
class FakeCognitoGateway implements CognitoGateway {
  FakeCognitoGateway({
    this.validUsername = 'user@noana.com',
    this.validPassword = 'secret123',
    bool initialSession = false,
    this.refreshTokenUsable = false,
  }) : _hasSession = initialSession;

  final String validUsername;
  final String validPassword;

  /// Whether a stored refresh token can produce a new session (models the
  /// restore-session fallback path: no live session, but refresh works).
  final bool refreshTokenUsable;

  bool _hasSession;

  bool configured = false;
  int refreshCount = 0;
  int signOutCount = 0;
  bool failFetchTokens = false;

  @override
  Future<void> configure() async {
    configured = true;
  }

  @override
  Future<AuthResult> signIn({
    required String username,
    required String password,
  }) async {
    if (username == validUsername && password == validPassword) {
      _hasSession = true;
      return AuthResult.success;
    }
    return const AuthResult(ok: false, errorMessage: 'Incorrect username or password.');
  }

  @override
  Future<void> signOut() async {
    signOutCount++;
    _hasSession = false;
  }

  @override
  Future<bool> hasSession() async => _hasSession;

  @override
  Future<AuthTokens> fetchTokens() async {
    if (failFetchTokens) {
      throw const SignedOutException('expired');
    }
    return const AuthTokens(
      accessToken: 'access-token-1',
      idToken: 'id-token-1',
      refreshToken: 'refresh-token-1',
    );
  }

  @override
  Future<AuthUser?> currentUser() async {
    if (!_hasSession) return null;
    return const AuthUser(
      userId: '11111111-2222-3333-4444-555555555555',
      username: 'user@noana.com',
      signInDetails: CognitoSignInDetails.apiBased(username: 'user@noana.com'),
    );
  }

  @override
  Future<AuthTokens> refreshSession() async {
    refreshCount++;
    if (!_hasSession && !refreshTokenUsable) {
      throw const SignedOutException('No session');
    }
    if (failFetchTokens) {
      throw const SignedOutException('expired');
    }
    _hasSession = true;
    return const AuthTokens(
      accessToken: 'access-token-refreshed',
      idToken: 'id-token-refreshed',
      refreshToken: 'refresh-token-1',
    );
  }
}

class FakeAuthUser extends AuthUser {
  FakeAuthUser()
      : super(
          userId: '11111111-2222-3333-4444-555555555555',
          username: 'user@noana.com',
          signInDetails: CognitoSignInDetails.apiBased(username: 'user@noana.com'),
        );
}

/// In-memory secure storage for tests.
class FakeSecureStorage implements SecureStorage {
  FakeSecureStorage();

  final Map<String, String> _store = {};

  @override
  Future<void> write(String key, String value) async => _store[key] = value;

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<void> clearAll() async => _store.clear();

  @override
  Future<void> saveCognitoTokens({
    required String accessToken,
    required String idToken,
    required String refreshToken,
  }) async {
    _store['wellness.cognito.access'] = accessToken;
    _store['wellness.cognito.id'] = idToken;
    _store['wellness.cognito.refresh'] = refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => _store['wellness.cognito.access'];

  @override
  Future<String?> getIdToken() async => _store['wellness.cognito.id'];

  @override
  Future<String?> getRefreshToken() async => _store['wellness.cognito.refresh'];

  @override
  Future<void> clearCognitoTokens() async {
    _store.remove('wellness.cognito.access');
    _store.remove('wellness.cognito.id');
    _store.remove('wellness.cognito.refresh');
  }

  @override
  Future<void> saveWellnessPersonUuid(String uuid) async =>
      _store['wellness.person.uuid'] = uuid;

  @override
  Future<String?> getWellnessPersonUuid() async => _store['wellness.person.uuid'];
}
