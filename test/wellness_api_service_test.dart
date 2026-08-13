/// Tests for WellnessApiService + identity models (Phase 2).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/wellness_api_service.dart';
import 'package:noana_wellness_app/shared/models/wellness_identity.dart';

import 'helpers/fakes.dart';

const _bootstrapJson = {
  'person': {
    'uuid': '4ea1a18b-ff02-411e-a163-77bc2a233a20',
    'cognito_sub': 'sub-real-123',
    'user_uuid': '99999999-8888-7777-6666-555555555555',
    'display_name': 'Daniel',
    'avatar_url': 'https://cdn.noana.link/a.png',
    'height_cm': '178.5',
    'birth_date': '1990-05-20',
    'gender': 'male',
    'created_at': '2026-08-13T12:00:00Z',
    'updated_at': '2026-08-13T12:00:00Z',
  },
  'profile': {
    'bed_time_min': '22:30',
    'sleep_target_min': 480,
    'goal_steps': 10000,
    'timezone': 'America/Sao_Paulo',
    'formula_client_version': '1.0.0',
    'created_at': '2026-08-13T12:00:00Z',
    'updated_at': '2026-08-13T12:00:00Z',
  },
  'created': true,
};

void main() {
  const config = AppConfig(
    environment: AppEnvironment.hml,
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
    storage.saveCognitoTokens(
      accessToken: 'access-token-1',
      idToken: 'id-token-1',
      refreshToken: 'refresh-token-1',
    );
  });

  group('WellnessIdentity models', () {
    test('WellnessPerson.fromJson parses backend payload', () {
      final p = WellnessPerson.fromJson(_bootstrapJson['person'] as Map<String, dynamic>);
      expect(p.uuid, '4ea1a18b-ff02-411e-a163-77bc2a233a20');
      expect(p.cognitoSub, 'sub-real-123');
      expect(p.displayName, 'Daniel');
      expect(p.heightCm, 178.5);
      expect(p.birthDate, '1990-05-20');
    });

    test('WellnessProfile.fromJson parses backend payload', () {
      final pr = WellnessProfile.fromJson(_bootstrapJson['profile'] as Map<String, dynamic>);
      expect(pr.bedTimeMin, '22:30');
      expect(pr.sleepTargetMin, 480);
      expect(pr.goalSteps, 10000);
      expect(pr.formulaClientVersion, '1.0.0');
    });

    test('WellnessBootstrapResponse.fromJson parses full payload', () {
      final r = WellnessBootstrapResponse.fromJson(
        Map<String, dynamic>.from(_bootstrapJson),
      );
      expect(r.created, isTrue);
      expect(r.person.uuid, '4ea1a18b-ff02-411e-a163-77bc2a233a20');
      expect(r.profile.timezone, 'America/Sao_Paulo');
    });

    test('WellnessMe.fromJson parses me payload (no created flag)', () {
      final me = WellnessMe.fromJson({
        'person': _bootstrapJson['person']!,
        'profile': _bootstrapJson['profile']!,
      });
      expect(me.person.uuid, '4ea1a18b-ff02-411e-a163-77bc2a233a20');
    });
  });

  group('WellnessApiService', () {
    test('bootstrap POSTs to /wellness/bootstrap/ and parses response', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(),
            'https://api.hml.noana.link/v1/wellness/bootstrap/');
        expect(request.headers['Authorization'], 'Bearer id-token-1');
        return http.Response(jsonEncode(_bootstrapJson), 200,
            headers: {'content-type': 'application/json'});
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      final service = WellnessApiService(apiClient: api);

      final result = await service.bootstrap();
      expect(result.created, isTrue);
      expect(result.person.uuid, '4ea1a18b-ff02-411e-a163-77bc2a233a20');
    });

    test('getMe GETs /wellness/me/', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(),
            'https://api.hml.noana.link/v1/wellness/me/');
        return http.Response(
          jsonEncode({
            'person': _bootstrapJson['person']!,
            'profile': _bootstrapJson['profile']!,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      final service = WellnessApiService(apiClient: api);

      final me = await service.getMe();
      expect(me.person.cognitoSub, 'sub-real-123');
    });

    test('updateMe PATCHes only provided fields', () async {
      late Map<String, dynamic> sentBody;
      final client = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.toString(),
            'https://api.hml.noana.link/v1/wellness/me/');
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        final merged = {
          ...(_bootstrapJson['person']! as Map<String, dynamic>),
          ...sentBody,
        };
        return http.Response(
          jsonEncode({'person': merged, 'profile': _bootstrapJson['profile']!}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      final service = WellnessApiService(apiClient: api);

      final me = await service.updateMe(displayName: 'Novo Nome', goalSteps: 12000);
      expect(sentBody, {'display_name': 'Novo Nome', 'goal_steps': 12000});
      expect(me.person.displayName, 'Novo Nome');
    });

    test('bootstrap failure surfaces ApiException', () async {
      final client = MockClient((request) async {
        return http.Response('{"detail":"nope"}', 500);
      });
      final api = ApiClient(config: config, auth: auth, httpClient: client);
      final service = WellnessApiService(apiClient: api);

      expect(service.bootstrap(), throwsA(isA<ApiException>()));
    });
  });
}
