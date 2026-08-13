/// Tests for AuthService (spec §7) against a fake Cognito gateway.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';

import 'helpers/fakes.dart';

void main() {
  group('AuthService', () {
    late FakeCognitoGateway gateway;
    late FakeSecureStorage storage;
    late AuthService service;

    setUp(() {
      gateway = FakeCognitoGateway();
      storage = FakeSecureStorage();
      service = AuthService(gateway: gateway, storage: storage);
    });

    test('initialize configures the gateway and restores session', () async {
      expect(gateway.configured, isFalse);
      await service.initialize();
      expect(gateway.configured, isTrue);
      expect(service.status, AuthStatus.unauthenticated);
    });

    test('login with valid credentials -> authenticated + tokens persisted', () async {
      final result = await service.login(
        username: 'user@noana.com',
        password: 'secret123',
      );
      expect(result.ok, isTrue);
      expect(service.status, AuthStatus.authenticated);
      expect(await storage.getAccessToken(), 'access-token-1');
      expect(await storage.getIdToken(), 'id-token-1');
      expect(await storage.getRefreshToken(), 'refresh-token-1');
    });

    test('login with invalid credentials -> failure, status unchanged', () async {
      final result = await service.login(
        username: 'user@noana.com',
        password: 'wrong',
      );
      expect(result.ok, isFalse);
      expect(result.errorMessage, isNotNull);
      expect(service.status, AuthStatus.unauthenticated);
      expect(await storage.getAccessToken(), isNull);
    });

    test('logout clears tokens and identity, status unauthenticated', () async {
      await service.login(username: 'user@noana.com', password: 'secret123');
      await service.logout();
      expect(service.status, AuthStatus.unauthenticated);
      expect(service.currentIdentity, isNull);
      expect(await storage.getAccessToken(), isNull);
      expect(gateway.signOutCount, 1);
    });

    test('restoreSession restores from Amplify session after restart', () async {
      gateway = FakeCognitoGateway(initialSession: true);
      service = AuthService(gateway: gateway, storage: storage);
      await service.restoreSession();
      expect(service.status, AuthStatus.authenticated);
      expect(service.currentIdentity?.sub, '11111111-2222-3333-4444-555555555555');
    });

    test('restoreSession falls back to stored refresh token', () async {
      // No Amplify session, but a refresh token exists in secure storage.
      gateway = FakeCognitoGateway(refreshTokenUsable: true);
      service = AuthService(gateway: gateway, storage: storage);
      await storage.saveCognitoTokens(
        accessToken: 'stale',
        idToken: 'stale',
        refreshToken: 'refresh-token-1',
      );
      await service.restoreSession();
      expect(service.status, AuthStatus.authenticated);
      expect(gateway.refreshCount, 1);
    });

    test('restoreSession -> unauthenticated when nothing persisted', () async {
      await service.restoreSession();
      expect(service.status, AuthStatus.unauthenticated);
    });

    test('refreshToken refreshes and persists new tokens', () async {
      await service.login(username: 'user@noana.com', password: 'secret123');
      await service.refreshToken();
      expect(await storage.getAccessToken(), 'access-token-refreshed');
      expect(gateway.refreshCount, 1);
    });

    test('getAccessToken refreshes when stored token missing', () async {
      // Logged-in gateway, but storage was cleared -> refresh path.
      gateway = FakeCognitoGateway(initialSession: true);
      service = AuthService(gateway: gateway, storage: storage);
      final token = await service.getAccessToken();
      expect(token, 'access-token-refreshed');
      expect(gateway.refreshCount, 1);
    });

    test('getCurrentIdentity returns identity after login', () async {
      await service.login(username: 'user@noana.com', password: 'secret123');
      final identity = await service.getCurrentIdentity();
      expect(identity.sub, '11111111-2222-3333-4444-555555555555');
      expect(identity.username, 'user@noana.com');
    });

    test('login → logout → login keeps a single identity (no duplication)', () async {
      await service.login(username: 'user@noana.com', password: 'secret123');
      final first = await service.getCurrentIdentity();
      await service.logout();
      await service.login(username: 'user@noana.com', password: 'secret123');
      final second = await service.getCurrentIdentity();
      expect(first.sub, second.sub);
      expect(gateway.refreshCount, 0, reason: 'no refresh needed across logins');
    });
  });
}
