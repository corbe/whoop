/// Tests for ApiClient (spec §62): Bearer injection, 401 refresh+retry,
/// timeouts, network errors.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';

import 'helpers/fakes.dart';

void main() {
  group('ApiClient', () {
    const config = AppConfig(
      environment: AppEnvironment.hml,
      cognitoPoolId: 'us-east-1_BFGyiLUlb',
      cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
      wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
      juggleApiUrl: 'https://juggleim-api.hml.noana.link',
      juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
      juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
    );

    late FakeCognitoGateway gateway;
    late FakeSecureStorage storage;
    late AuthService auth;

    setUp(() {
      gateway = FakeCognitoGateway(initialSession: true);
      storage = FakeSecureStorage();
      auth = AuthService(gateway: gateway, storage: storage);
      // Model the post-login state: tokens persisted in secure storage.
      storage.saveCognitoTokens(
        accessToken: 'access-token-1',
        idToken: 'id-token-1',
        refreshToken: 'refresh-token-1',
      );
    });

    test('sends Authorization Bearer header with id token', () async {
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer id-token-1');
        expect(request.url.toString(),
            'https://api.hml.noana.link/v1/wellness/ping');
        return http.Response('{"ok":true}', 200);
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      final res = await api.get('/wellness/ping');
      expect(res.statusCode, 200);
      expect(res.data['ok'], isTrue);
    });

    test('POST sends JSON body and content-type', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.headers['Content-Type'], 'application/json');
        expect(jsonDecode(request.body), {'score': 88});
        return http.Response('{"id":"x"}', 201);
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      final res = await api.post('/wellness/scores/daily/2026-08-13',
          body: {'score': 88});
      expect(res.statusCode, 201);
    });

    test('401 triggers token refresh and retries exactly once', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response('{"msg":"expired"}', 401);
        expect(request.headers['Authorization'],
            'Bearer id-token-refreshed');
        return http.Response('{"ok":true}', 200);
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      final res = await api.get('/wellness/ping');
      expect(calls, 2);
      expect(gateway.refreshCount, 1);
      expect(res.statusCode, 200);
    });

    test('401 with failed refresh surfaces ApiException 401', () async {
      gateway.failFetchTokens = true;
      final client = MockClient((request) async {
        return http.Response('{"msg":"expired"}', 401);
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      expect(
        () => api.get('/wellness/ping'),
        throwsA(isA<ApiException>()
            .having((e) => e.isUnauthorized, 'isUnauthorized', true)),
      );
    });

    test('non-2xx response throws ApiException with status', () async {
      final client = MockClient((request) async {
        return http.Response('{"msg":"nope"}', 403);
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      expect(
        () => api.get('/wellness/ping'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('timeout throws ApiException flagged as network error', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response('{}', 200);
      });
      final api = ApiClient(
        config: config,
        auth: auth,
        httpClient: client,
        timeout: const Duration(milliseconds: 50),
      );
      expect(
        () => api.get('/wellness/ping'),
        throwsA(isA<ApiException>()
            .having((e) => e.isNetworkError, 'isNetworkError', true)),
      );
    });

    test('client exceptions surface as network ApiException', () async {
      final client = MockClient((request) async {
        throw http.ClientException('connection refused');
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      expect(
        () => api.get('/wellness/ping'),
        throwsA(isA<ApiException>()
            .having((e) => e.isNetworkError, 'isNetworkError', true)),
      );
    });

    test('unauthenticated request omits Authorization header', () async {
      final client = MockClient((request) async {
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response('{}', 200);
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      await api.get('/public/health', authenticated: false);
    });
  });
}
