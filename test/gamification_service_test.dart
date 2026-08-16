/// Phase 8 gamification tests (spec §82) — mocks around the HTTP client.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/gamification_providers.dart';
import 'package:noana_wellness_app/services/gamification_service.dart';
import 'package:noana_wellness_app/shared/models/gamification.dart';

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

Map<String, dynamic> _achievementJson({
  String code = 'SCORE_7_DAYS',
  bool unlocked = false,
  int progress = 5,
}) {
  return {
    'code': code,
    'name': '7 dias registrados',
    'description': 'Registre scores em 7 dias distintos',
    'category': 'scores',
    'icon_key': 'seven_days',
    'points': 20,
    'progress': progress,
    'target': 7,
    'unlocked': unlocked,
    'unlocked_at': unlocked ? '2026-08-14T10:00:00Z' : null,
  };
}

void main() {
  group('GamificationService (spec §46)', () {
    test('parses achievements with state', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/v1/wellness/achievements/');
        return http.Response(
            '{"items": [${jsonEncode(_achievementJson())}]}', 200,
            headers: {'content-type': 'application/json'});
      });
      final service = GamificationService(apiClient: _apiWith(mock));
      final items = await service.getAchievements();
      expect(items, hasLength(1));
      expect(items.first.code, 'SCORE_7_DAYS');
      expect(items.first.progress, 5);
      expect(items.first.target, 7);
      expect(items.first.unlocked, isFalse);
    });

    test('parses summary', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/v1/wellness/gamification/summary/');
        return http.Response(
            '{"unlocked_count":4,"total_count":11,"current_streak":6,'
            '"best_streak":12,"points":85,"level":2,'
            '"selected_badges":[{"code":"FIRST_SCORE","name":"Primeiro registro",'
            '"icon_key":"first_score","position":1}]}',
            200,
            headers: {'content-type': 'application/json'});
      });
      final service = GamificationService(apiClient: _apiWith(mock));
      final summary = await service.getSummary();
      expect(summary.unlockedCount, 4);
      expect(summary.currentStreak, 6);
      expect(summary.bestStreak, 12);
      expect(summary.points, 85);
      expect(summary.level, 2);
      expect(summary.selectedBadges, hasLength(1));
    });

    test('parses streaks', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/v1/wellness/streaks/');
        return http.Response(
            '{"streaks":[{"streak_type":"daily_score","current_count":3,'
            '"best_count":5,"current_start_date":"2026-08-11",'
            '"last_qualified_date":"2026-08-13"}]}',
            200,
            headers: {'content-type': 'application/json'});
      });
      final service = GamificationService(apiClient: _apiWith(mock));
      final streaks = await service.getStreaks();
      expect(streaks.first.currentCount, 3);
      expect(streaks.first.bestCount, 5);
    });

    test('selectBadges posts codes', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/wellness/gamification/select-badges/');
        expect(jsonDecode(request.body), {'codes': ['FIRST_SCORE']});
        return http.Response(
            '{"selected_badges":[{"code":"FIRST_SCORE","name":"Primeiro registro",'
            '"icon_key":"first_score","position":1}]}',
            200,
            headers: {'content-type': 'application/json'});
      });
      final service = GamificationService(apiClient: _apiWith(mock));
      final badges = await service.selectBadges(['FIRST_SCORE']);
      expect(badges.first.code, 'FIRST_SCORE');
    });

    test('API error surfaces as ApiException', () async {
      final mock =
          MockClient((request) async => http.Response('{"detail":"no"}', 500));
      final service = GamificationService(apiClient: _apiWith(mock));
      expect(service.getSummary(), throwsA(isA<ApiException>()));
    });
  });

  group('unlock dedup (spec §52)', () {
    test('newlyUnlocked returns only new codes once', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller =
          container.read(gamificationActionControllerProvider);

      final unlocked = Achievement.fromJson(_achievementJson(unlocked: true));
      final locked = Achievement.fromJson(_achievementJson());

      // primeira vez: celebra
      final first = controller.newlyUnlocked([unlocked, locked]);
      expect(first, hasLength(1));
      expect(first.single.code, 'SCORE_7_DAYS');
      controller.markCelebrated(first.single.code);

      // segunda vez: não celebra de novo
      final second = controller.newlyUnlocked([unlocked, locked]);
      expect(second, isEmpty);
    });
  });

  group('model rendering states', () {
    test('locked achievement has progress < target', () {
      final a = Achievement.fromJson(_achievementJson(progress: 5));
      expect(a.unlocked, isFalse);
      expect(a.progress, lessThan(a.target));
    });

    test('unlocked achievement carries unlockedAt', () {
      final a = Achievement.fromJson(_achievementJson(unlocked: true, progress: 7));
      expect(a.unlocked, isTrue);
      expect(a.unlockedAt, isNotNull);
    });

    test('summary empty state (zero everything)', () {
      final s = GamificationSummary.fromJson({
        'unlocked_count': 0,
        'total_count': 11,
        'current_streak': 0,
        'best_streak': 0,
        'points': 0,
        'level': 1,
        'selected_badges': [],
      });
      expect(s.unlockedCount, 0);
      expect(s.currentStreak, 0);
      expect(s.selectedBadges, isEmpty);
    });
  });
}
