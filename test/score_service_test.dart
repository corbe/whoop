/// Tests for ScoreService + score models (Phase 5).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/score_service.dart';
import 'package:noana_wellness_app/shared/models/score.dart';

const _scoreJson = {
  'uuid': '11111111-1111-1111-1111-111111111111',
  'person_uuid': '22222222-2222-2222-2222-222222222222',
  'score_date': '2026-08-13',
  'sleep': 88,
  'readiness': 91,
  'stress_trend': null,
  'stress_instant': null,
  'activity': 84,
  'strain': 77,
  'strain_target_pct': null,
  'physical_capacity': null,
  'formula_version': '1.0.0',
  'computed_by': 'client',
  'source_device_id': 'device-1',
  'computed_at': '2026-08-13T12:00:00Z',
  'received_at': '2026-08-13T12:00:00Z',
};

const _rankingJson = {
  'community_uuid': '33333333-3333-3333-3333-333333333333',
  'metric': 'readiness',
  'period': 'week',
  'period_start': '2026-08-10',
  'period_end': '2026-08-16',
  'total_members': 2,
  'page': 1,
  'page_size': 50,
  'current_user_position': 1,
  'entries': [
    {
      'position': 1,
      'person_uuid': '22222222-2222-2222-2222-222222222222',
      'display_name': 'Ana',
      'avatar_url': '',
      'score': 91.0,
      'days_count': 1,
    },
    {
      'position': 2,
      'person_uuid': '44444444-4444-4444-4444-444444444444',
      'display_name': 'Bia',
      'avatar_url': '',
      'score': 84.0,
      'days_count': 1,
    },
  ],
};

ApiClient _apiWith(MockClient mock) {
  return ApiClient(
    config: const AppConfig(
      environment: AppEnvironment.hml,
      cognitoPoolId: 'us-east-1_BFGyiLUlb',
      cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
      wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
      juggleApiUrl: 'https://juggleim-api.hml.noana.link',
      juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
      juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
    ),
    auth: _FakeAuthService(),
    httpClient: mock,
  );
}

class _FakeAuthService implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token-1';
  @override
  Future<String> getAccessToken() async => 'access-token-1';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('DailyScore model', () {
    test('fromJson parses backend shape', () {
      final score = DailyScore.fromJson(_scoreJson);
      expect(score.scoreDate, '2026-08-13');
      expect(score.readiness, 91);
      expect(score.sleep, 88);
      expect(score.activity, 84);
      expect(score.strain, 77);
      expect(score.formulaVersion, '1.0.0');
      expect(score.computedBy, 'client');
      // Sem fórmula autoritativa → campos nullable (SCORE_AUDIT.md)
      expect(score.stressTrend, isNull);
      expect(score.physicalCapacity, isNull);
    });

    test('upload payload never carries identity fields', () {
      final upload = DailyScoreUpload(
        readiness: 91,
        formulaVersion: '1.0.0',
        sourceDeviceId: 'd1',
      ).toJson();
      expect(upload.containsKey('person_uuid'), isFalse);
      expect(upload.containsKey('cognito_sub'), isFalse);
      expect(upload.containsKey('user_uuid'), isFalse);
      expect(upload['formula_version'], '1.0.0');
    });

    test('share scope defaults privacy-safe', () {
      const scope = CommunityShareScope();
      expect(scope.readiness, isFalse);
      expect(scope.sleep, isFalse);
      expect(scope.activity, isFalse);
      expect(scope.strain, isFalse);
      final withReadiness = scope.copyWith(readiness: true);
      expect(withReadiness.readiness, isTrue);
      expect(withReadiness.sleep, isFalse);
    });
  });

  group('ScoreService', () {
    test('getLatest parses DailyScore', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/wellness/scores/daily/latest/');
        expect(request.headers['Authorization'], 'Bearer id-token-1');
        return http.Response(jsonEncode(_scoreJson), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = ScoreService(apiClient: _apiWith(mock));
      final score = await service.getLatest();
      expect(score!.readiness, 91);
    });

    test('getLatest returns null on 404 (no scores yet)', () async {
      final mock = MockClient(
          (request) async => http.Response('{"detail":"none"}', 404));
      final service = ScoreService(apiClient: _apiWith(mock));
      expect(await service.getLatest(), isNull);
    });

    test('uploadDailyScore PUTs with formula_version and no identity', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/v1/wellness/scores/daily/2026-08-13/');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['readiness'], 91);
        expect(body['formula_version'], '1.0.0');
        expect(body.containsKey('person_uuid'), isFalse);
        return http.Response(jsonEncode(_scoreJson), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = ScoreService(apiClient: _apiWith(mock));
      final score = await service.uploadDailyScore(
        '2026-08-13',
        const DailyScoreUpload(readiness: 91, formulaVersion: '1.0.0'),
      );
      expect(score.readiness, 91);
    });

    test('getRanking parses entries + current position', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/v1/wellness/communities/33333333-3333-3333-3333-333333333333/ranking/',
        );
        expect(request.url.queryParameters['metric'], 'readiness');
        expect(request.url.queryParameters['period'], 'week');
        return http.Response(jsonEncode(_rankingJson), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = ScoreService(apiClient: _apiWith(mock));
      final ranking = await service.getRanking(
        '33333333-3333-3333-3333-333333333333',
      );
      expect(ranking.metric, 'readiness');
      expect(ranking.entries, hasLength(2));
      expect(ranking.entries.first.position, 1);
      expect(ranking.entries.first.score, 91.0);
      expect(ranking.currentUserPosition, 1);
    });

    test('updateShareScope PATCHes only own privacy', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(
          request.url.path,
          '/v1/wellness/communities/33333333-3333-3333-3333-333333333333/privacy/',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['readiness'], isTrue);
        expect(body.containsKey('person_uuid'), isFalse);
        return http.Response(
          jsonEncode({
            'share_scope_json': {'readiness': true, 'sleep': false, 'activity': false, 'strain': false}
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = ScoreService(apiClient: _apiWith(mock));
      final saved = await service.updateShareScope(
        '33333333-3333-3333-3333-333333333333',
        const CommunityShareScope(readiness: true),
      );
      expect(saved.readiness, isTrue);
      expect(saved.sleep, isFalse);
    });
  });
}
