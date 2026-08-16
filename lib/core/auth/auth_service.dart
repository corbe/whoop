/// Cognito authentication service (spec §7).
///
/// Responsibilities: login, logout, restoreSession, refreshToken,
/// getAccessToken, getIdToken, getCurrentIdentity.
///
/// Backed by AWS Amplify + the shared Noana Cognito user pool
/// (`us-east-1_lgjiHS5hH`). The app never talks to JuggleIM auth — Cognito is
/// the single source of authentication (spec §11).
library;

import 'dart:async';

import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_flutter/amplify_flutter.dart' hide AuthException;

import '../storage/secure_storage.dart';

/// Current auth state exposed to the UI layer.
enum AuthStatus {
  /// No session and no restore in flight.
  unauthenticated,

  /// Restoring a persisted session on app start.
  restoring,

  /// Session established (access/id tokens available).
  authenticated,

  /// Session expired and refresh failed.
  expired,
}

/// Result of a login attempt.
class AuthResult {
  const AuthResult({required this.ok, this.errorMessage, this.isNewUser = false});

  final bool ok;
  final String? errorMessage;
  final bool isNewUser;

  static const AuthResult success = AuthResult(ok: true);
}

/// The Cognito identity of the current user (spec §6: resolve/create
/// WellnessPerson happens against the Wellness API, not here).
class CurrentIdentity {
  const CurrentIdentity({
    required this.sub,
    required this.username,
  });

  final String sub;
  final String username;
}

/// Token triple exposed by the gateway (kept minimal so the auth layer does
/// not leak Amplify types into the rest of the app).
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.idToken,
    required this.refreshToken,
  });

  final String accessToken;
  final String idToken;
  final String refreshToken;
}

/// Abstraction over Amplify so tests can inject a fake without touching AWS.
abstract interface class CognitoGateway {
  Future<void> configure();

  Future<AuthResult> signIn({required String username, required String password});

  Future<void> signOut();

  Future<bool> hasSession();

  Future<AuthTokens> fetchTokens();

  Future<AuthUser?> currentUser();

  Future<AuthTokens> refreshSession();

  /// Cognito user attributes (name, nickname, email, …). Empty map on
  /// failure — the caller must treat it as "no attributes available".
  Future<Map<String, String>> fetchUserAttributes();
}

/// Default gateway backed by the Amplify Cognito plugin.
class AmplifyCognitoGateway implements CognitoGateway {
  AmplifyCognitoGateway();

  bool _configured = false;

  @override
  Future<void> configure() async {
    if (_configured) return;
    if (!Amplify.isConfigured) {
      await Amplify.addPlugin(AmplifyAuthCognito());
      await Amplify.configure(amplifyConfigJson);
    }
    _configured = true;
  }

  @override
  Future<AuthResult> signIn({
    required String username,
    required String password,
  }) async {
    try {
      final res = await Amplify.Auth.signIn(
        username: username,
        password: password,
      );
      if (res.isSignedIn) {
        return AuthResult.success;
      }
      return AuthResult(
        ok: false,
        errorMessage: 'Sign-in requires additional steps: ${res.nextStep.signInStep}',
      );
    } on AuthException catch (e) {
      return AuthResult(ok: false, errorMessage: e.message);
    } catch (e) {
      return AuthResult(ok: false, errorMessage: e.toString());
    }
  }

  @override
  Future<void> signOut() async {
    if (!Amplify.isConfigured) return;
    try {
      await Amplify.Auth.signOut();
    } on AuthException {
      // Best-effort: local session state is cleared regardless.
    }
  }

  @override
  Future<bool> hasSession() async {
    if (!Amplify.isConfigured) return false;
    try {
      final session = await Amplify.Auth.fetchAuthSession();
      return session.isSignedIn;
    } on AuthException {
      return false;
    }
  }

  @override
  Future<AuthTokens> fetchTokens() async {
    final session = await Amplify.Auth.fetchAuthSession() as CognitoAuthSession;
    final tokens = session.userPoolTokensResult.valueOrNull;
    if (tokens == null) {
      throw session.userPoolTokensResult.exception ??
          const SignedOutException(
            'No Cognito user pool tokens available',
            recoverySuggestion: 'Sign in again to obtain tokens',
          );
    }
    return AuthTokens(
      accessToken: tokens.accessToken.raw,
      idToken: tokens.idToken.raw,
      refreshToken: tokens.refreshToken,
    );
  }

  @override
  Future<AuthUser?> currentUser() async {
    if (!Amplify.isConfigured) return null;
    try {
      return await Amplify.Auth.getCurrentUser();
    } on AuthException {
      return null;
    }
  }

  @override
  Future<AuthTokens> refreshSession() => fetchTokens();

  @override
  Future<Map<String, String>> fetchUserAttributes() async {
    if (!Amplify.isConfigured) return const {};
    try {
      final attrs = await Amplify.Auth.fetchUserAttributes();
      return {for (final a in attrs) a.userAttributeKey.key: a.value};
    } on AuthException {
      return const {};
    } catch (_) {
      return const {};
    }
  }

  /// The shared Noana Cognito pool (same identity for Clinical and Wellness).
  static const String amplifyConfigJson = '''
{
  "UserAgent": "aws-amplify-cli/2.0",
  "Version": "1.0",
  "auth": {
    "plugins": {
      "awsCognitoAuthPlugin": {
        "UserAgent": "aws-amplify-cli/0.1.0",
        "Version": "0.1.0",
        "IdentityManager": {
          "Default": {}
        },
        "CredentialsProvider": {
          "CognitoIdentity": {
            "Default": {
              "PoolId": "us-east-1_lgjiHS5hH",
              "Region": "us-east-1"
            }
          }
        },
        "CognitoUserPool": {
          "Default": {
            "PoolId": "us-east-1_lgjiHS5hH",
            "AppClientId": "156qt3qr79mu4jsnr5t82hot15",
            "Region": "us-east-1"
          }
        },
        "Auth": {
          "Default": {
            "authenticationFlowType": "USER_SRP_AUTH",
            "socialProviders": ["GOOGLE"],
            "usernameAttributes": ["EMAIL"],
            "signupAttributes": ["EMAIL", "NAME"],
            "passwordProtectionSettings": {
              "passwordPolicyMinLength": 8,
              "passwordPolicyCharacters": []
            },
            "mfaConfiguration": "OFF",
            "mfaTypes": [],
            "verificationMechanisms": ["EMAIL"]
          }
        }
      }
    }
  }
}
''';
}

class AuthService {
  AuthService({required CognitoGateway gateway, required SecureStorage storage})
      : _gateway = gateway,
        _storage = storage {
    _statusController = StreamController<AuthStatus>.broadcast();
  }

  final CognitoGateway _gateway;
  final SecureStorage _storage;
  late final StreamController<AuthStatus> _statusController;

  AuthStatus _status = AuthStatus.unauthenticated;
  CurrentIdentity? _identity;

  AuthStatus get status => _status;
  CurrentIdentity? get currentIdentity => _identity;

  Stream<AuthStatus> get statusStream => _statusController.stream;

  void _setStatus(AuthStatus s) {
    _status = s;
    if (!_statusController.isClosed) {
      _statusController.add(s);
    }
  }

  /// Idempotent one-time initialization (Amplify configure + session restore).
  Future<void> initialize() async {
    await _gateway.configure();
    await restoreSession();
  }

  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    final result = await _gateway.signIn(username: username, password: password);
    if (!result.ok) return result;
    await _persistTokens();
    await _loadIdentity();
    _setStatus(AuthStatus.authenticated);
    return AuthResult.success;
  }

  Future<void> logout() async {
    await _gateway.signOut();
    await _storage.clearCognitoTokens();
    _identity = null;
    _setStatus(AuthStatus.unauthenticated);
  }

  /// Restores the persisted session after app restart (spec §7).
  Future<void> restoreSession() async {
    _setStatus(AuthStatus.restoring);
    try {
      final hasSession = await _gateway.hasSession();
      if (hasSession) {
        await _persistTokens();
        await _loadIdentity();
        _setStatus(AuthStatus.authenticated);
        return;
      }
      // Amplify persists its own session; if it reports none, try tokens.
      final stored = await _storage.getRefreshToken();
      if (stored != null) {
        final refreshed = await _gateway.refreshSession();
        if (refreshed.accessToken.isNotEmpty) {
          await _persistTokens();
          await _loadIdentity();
          _setStatus(AuthStatus.authenticated);
          return;
        }
      }
      _setStatus(AuthStatus.unauthenticated);
    } on AuthException {
      _setStatus(AuthStatus.expired);
    } catch (_) {
      _setStatus(AuthStatus.unauthenticated);
    }
  }

  /// Refreshes tokens; throws [AuthException] if the refresh token is invalid.
  Future<void> refreshToken() async {
    final refreshed = await _gateway.refreshSession();
    await _storage.saveCognitoTokens(
      accessToken: refreshed.accessToken,
      idToken: refreshed.idToken,
      refreshToken: refreshed.refreshToken,
    );
  }

  Future<String> getAccessToken() async {
    final t = await _storage.getAccessToken();
    if (t == null || t.isEmpty) {
      await refreshToken();
      return (await _storage.getAccessToken())!;
    }
    return t;
  }

  Future<String> getIdToken() async {
    final t = await _storage.getIdToken();
    if (t == null || t.isEmpty) {
      await refreshToken();
      return (await _storage.getIdToken())!;
    }
    return t;
  }

  Future<CurrentIdentity> getCurrentIdentity() async {
    final existing = _identity;
    if (existing != null) return existing;
    await _loadIdentity();
    return _identity!;
  }

  /// Cognito username of the signed-in user (e.g. 'daniel') — used as a
  /// last-resort display name only when no name/nickname attribute exists.
  Future<String?> currentUsername() async {
    if (_identity == null) await _loadIdentity();
    return _identity?.username;
  }

  /// Cognito user attributes (empty map when unavailable).
  Future<Map<String, String>> fetchUserAttributes() =>
      _gateway.fetchUserAttributes();

  /// Best display name from Cognito attributes.
  ///
  /// Only explicitly user-editable name attributes are used — NEVER email
  /// (the local part would leak into communities). Returns null when the
  /// user has not set a name, so callers keep the safe "Membro" fallback.
  static String? preferredDisplayName(Map<String, String> attrs,
      {String? username}) {
    for (final key in const ['name', 'nickname']) {
      final value = attrs[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    final user = username?.trim();
    if (user != null && user.isNotEmpty && !user.contains('@')) {
      return user;
    }
    return null;
  }

  Future<void> _persistTokens() async {
    final tokens = await _gateway.fetchTokens();
    await _storage.saveCognitoTokens(
      accessToken: tokens.accessToken,
      idToken: tokens.idToken,
      refreshToken: tokens.refreshToken,
    );
  }

  Future<void> _loadIdentity() async {
    final user = await _gateway.currentUser();
    _identity = user == null
        ? null
        : CurrentIdentity(
            sub: user.userId,
            username: user.username,
          );
  }

  void dispose() {
    _statusController.close();
  }
}