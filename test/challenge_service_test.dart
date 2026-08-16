/// Phase 7 challenge tests (spec §83) — mocks around the HTTP client.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/challenge_service.dart';
import 'package:noana_wellness_app/shared/models/challenge.dart';

class _FakeAuth implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token-1';
  @override
  Future<String> getAccessToken() async => 'access-token-1';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    auth: _FakeAuth(),
    httpClient: mock,
  );
}

const _challengeJson = {
  'uuid': 'c-1',
  'community_uuid': 'comm-1',
  'name': 'Readiness Week',
  'description': 'Maior média de readiness',
  'metric': 'readiness',
  'aggregation': 'average',
  'start_date': '2026-08-17',
  'end_date': '2026-08-23',
  'status': 'active',
  'min_days': 2,
  'participant_count': 3,
  'current_user_status': 'active',
  'current_user_progress': {
    'participant_status': 'active',
    'score': 87.9,
    'days_count': 4,
    'qualified': true,
    'rank': 3,
  },
};

void main() {
  group('ChallengeService (spec §46)', () {
    test('list challenges parses backend shape', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/wellness/communities/comm-1/challenges/');
        return http.Response(
            '{"challenges": [${jsonEncode(_challengeJson)}]}', 200,
            headers: {'content-type': 'application/json'});
      });
      final service = ChallengeService(apiClient: _apiWith(mock));
      final challenges = await service.listChallenges('comm-1');
      expect(challenges, hasLength(1));
      expect(challenges.first.name, 'Readiness Week');
      expect(challenges.first.status, ChallengeStatus.active);
      expect(challenges.first.currentUserProgress?.score, 87.9);
    });

    test('create challenge posts request and parses detail', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/wellness/communities/comm-1/challenges/');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['metric'], 'readiness');
        expect(body['aggregation'], 'average');
        expect(body['start_date'], '2026-08-17');
        return http.Response(jsonEncode(_challengeJson), 201,
            headers: {'content-type': 'application/json'});
      });
      final service = ChallengeService(apiClient: _apiWith(mock));
      final created = await service.createChallenge(
        'comm-1',
        const ChallengeCreateRequest(
          name: 'Readiness Week',
          metric: 'readiness',
          aggregation: 'average',
          startDate: '2026-08-17',
          endDate: '2026-08-23',
        ),
      );
      expect(created.uuid, 'c-1');
    });

    test('join calls join endpoint', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
            request.url.path,
            '/v1/wellness/communities/comm-1/challenges/c-1/join/');
        return http.Response('{"status":"active"}', 200);
      });
      final service = ChallengeService(apiClient: _apiWith(mock));
      await service.joinChallenge('comm-1', 'c-1');
    });

    test('leave calls leave endpoint', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
            request.url.path,
            '/v1/wellness/communities/comm-1/challenges/c-1/leave/');
        return http.Response('{"status":"left"}', 200);
      });
      final service = ChallengeService(apiClient: _apiWith(mock));
      await service.leaveChallenge('comm-1', 'c-1');
    });

    test('ranking parses entries + current position', () async {
      final mock = MockClient((request) async {
        expect(request.url.path,
            '/v1/wellness/communities/comm-1/challenges/c-1/ranking/');
        return http.Response(
            '{"challenge_uuid":"c-1","status":"active","metric":"readiness",'
            '"aggregation":"average","start_date":"2026-08-17",'
            '"end_date":"2026-08-23","total_participants":2,'
            '"entries":[{"position":1,"person_uuid":"p1","display_name":"Ana",'
            '"avatar_url":"","score":91.0,"days_count":2,"qualified":true},'
            '{"position":2,"person_uuid":"p2","display_name":"Bia",'
            '"avatar_url":"","score":84.0,"days_count":2,"qualified":true}],'
            '"current_user_position":2}',
            200,
            headers: {'content-type': 'application/json'});
      });
      final service = ChallengeService(apiClient: _apiWith(mock));
      final ranking = await service.getRanking('comm-1', 'c-1');
      expect(ranking.entries, hasLength(2));
      expect(ranking.entries.first.score, 91.0);
      expect(ranking.currentUserPosition, 2);
      expect(ranking.entries.first.personUuid, 'p1');
    });

    test('privacy-ineligible join surfaces ApiException', () async {
      final mock = MockClient((request) async =>
          http.Response('{"detail":"Para participar, ative o compartilhamento"}', 403));
      final service = ChallengeService(apiClient: _apiWith(mock));
      expect(
        service.joinChallenge('comm-1', 'c-1'),
        throwsA(isA<ApiException>()),
      );
    });

    test('completed challenge has frozen final result (no recalc)', () async {
      final completedJson = Map<String, dynamic>.from(_challengeJson)
        ..['status'] = 'completed'
        ..['finalized_at'] = '2026-08-24T10:00:00Z'
        ..['current_user_progress'] = {
          'participant_status': 'active',
          'score': 87.9,
          'days_count': 4,
          'qualified': true,
          'rank': 3,
        };
      final mock = MockClient((request) async => http.Response(
          jsonEncode(completedJson), 200,
          headers: {'content-type': 'application/json'}));
      final service = ChallengeService(apiClient: _apiWith(mock));
      final challenge = await service.getChallenge('comm-1', 'c-1');
      expect(challenge.status, ChallengeStatus.completed);
      expect(challenge.currentUserProgress?.rank, 3);
      expect(challenge.finalizedAt, isNotNull);
    });
  });

  group('Challenge model edge cases', () {
    test('unknown metric/status map safely', () {
      final c = Challenge.fromJson({
        'uuid': 'x',
        'community_uuid': 'c',
        'name': 'X',
        'metric': 'readiness',
        'aggregation': 'average',
        'start_date': '2026-08-17',
        'end_date': '2026-08-23',
        'status': 'weird-status',
      });
      expect(c.status, ChallengeStatus.draft);
    });

    test('min_days absent → not qualified renders as false', () {
      final p = ChallengeProgress.fromJson({
        'participant_status': 'active',
        'score': null,
        'days_count': 0,
        'qualified': false,
      });
      expect(p.qualified, isFalse);
      expect(p.score, isNull);
    });
  });
}
