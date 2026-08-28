/// Regression: unlock celebration must NOT mutate providers during widget build.
///
/// Reproduces the real runtime failure seen on Android:
///   "Tried to modify a provider while the widget tree was building."
/// thrown from _AchievementsList.build → markCelebrated → CelebratedUnlocks.mark
/// (gamification_screen.dart:166 / gamification_providers.dart:42).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/features/gamification/gamification_screen.dart';
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
      wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
      juggleApiUrl: 'https://juggleim-api.hml.noana.link',
      juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
      juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
    ),
    auth: _FakeAuth(),
    httpClient: mock,
  );
}

class _FakeGamificationService extends GamificationService {
  _FakeGamificationService({required super.apiClient});

  @override
  Future<List<Achievement>> getAchievements() async => [
    const Achievement(
      code: 'SCORE_7_DAYS',
      name: '7 dias registrados',
      description: 'Registre scores em 7 dias distintos',
      category: AchievementCategory.scores,
      iconKey: 'seven_days',
      points: 20,
      progress: 7,
      target: 7,
      unlocked: true,
      unlockedAt: null,
    ),
  ];

  @override
  Future<GamificationSummary> getSummary() async => const GamificationSummary(
    unlockedCount: 1,
    totalCount: 1,
    currentStreak: 1,
    bestStreak: 1,
    points: 20,
    level: 1,
    selectedBadges: [],
    dailyPoints: DailyPointsSummary(
      date: '2026-08-28',
      todayTotal: 30,
      breakdown: {
        'day_completed': 5,
        'rings_closed': 10,
        'activity_zone': 5,
        'sleep_zone': 5,
        'strain_recorded': 5,
      },
      total: 120,
      history: [
        DailyPointsEntry(
          date: '2026-08-27',
          total: 25,
          breakdown: {'sleep_zone': 5},
        ),
      ],
    ),
  );

  @override
  Future<List<WellnessStreak>> getStreaks() async => const [];
}

void main() {
  testWidgets(
    'newly unlocked achievement renders without mutating providers during build',
    (tester) async {
      final mock = MockClient(
        (request) async => http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final service = _FakeGamificationService(apiClient: _apiWith(mock));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gamificationServiceProvider.overrideWithValue(service),
            // MEUS DESAFIOS section: no participations in this test.
          ],
          child: const MaterialApp(home: GamificationScreen()),
        ),
      );

      // The screen has an unlocked achievement -> the celebration path runs.
      // Before the fix this throws:
      //   "Tried to modify a provider while the widget tree was building."
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'celebration must not write providers during build',
      );

      // Celebration UX still works: dialog appears exactly once.
      expect(find.text('Conquista desbloqueada!'), findsOneWidget);

      await tester.tap(find.text('Legal!'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Session dedup state was actually marked (spec §52).
      final container = ProviderScope.containerOf(
        tester.element(find.byType(GamificationScreen)),
      );
      expect(
        container.read(celebratedUnlocksProvider),
        contains('SCORE_7_DAYS'),
      );
    },
  );

  testWidgets('no celebration dialog when nothing newly unlocked', (
    tester,
  ) async {
    final mock = MockClient(
      (request) async => http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    // Locked achievement -> newlyUnlocked is empty -> no write, no dialog.
    final lockedService = _LockedGamificationService(apiClient: _apiWith(mock));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamificationServiceProvider.overrideWithValue(lockedService),
        ],
        child: const MaterialApp(home: GamificationScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Conquista desbloqueada!'), findsNothing);
  });

  testWidgets('daily points card renders today breakdown and total', (
    tester,
  ) async {
    final mock = MockClient(
      (request) async => http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final service = _FakeGamificationService(apiClient: _apiWith(mock));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gamificationServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: GamificationScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Card "pontos de hoje" (Fase 1).
    expect(find.text('PONTOS DE HOJE'), findsOneWidget);
    expect(find.text('30 pts'), findsOneWidget);
    expect(find.textContaining('3 anéis fechados +10'), findsOneWidget);
    expect(find.textContaining('Dia completo +5'), findsOneWidget);
    expect(find.text('Total acumulado: 120 pts'), findsOneWidget);
  });

  testWidgets('daily points card empty state (no rewards yet)', (tester) async {
    final mock = MockClient(
      (request) async => http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final emptyService = _EmptyDailyPointsService(apiClient: _apiWith(mock));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamificationServiceProvider.overrideWithValue(emptyService),
        ],
        child: const MaterialApp(home: GamificationScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('PONTOS DE HOJE'), findsOneWidget);
    expect(find.text('0 pts'), findsOneWidget);
    expect(
      find.textContaining('Registre scores hoje para ganhar pontos'),
      findsOneWidget,
    );
  });

  testWidgets('Fase 4: level header renders progress + points to next', (
    tester,
  ) async {
    final mock = MockClient(
      (request) async => http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final service = _LevelProgressService(apiClient: _apiWith(mock));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gamificationServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: GamificationScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Nome do nível + pontos + pontos para o próximo (barra limitada).
    expect(find.text('Nível 2'), findsOneWidget);
    expect(find.text('137 PTS'), findsOneWidget);
    expect(find.textContaining('113 pts para'), findsOneWidget);
    expect(find.textContaining('Nível 3'), findsOneWidget);
    expect(find.textContaining('NaN'), findsNothing);
  });

  testWidgets('Fase 4: level max shows max message, no next', (tester) async {
    final mock = MockClient(
      (request) async => http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final service = _MaxLevelService(apiClient: _apiWith(mock));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [gamificationServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: GamificationScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('NÍVEL MÁXIMO'), findsOneWidget);
    expect(find.textContaining('alcançou o nível mais alto'), findsOneWidget);
  });

  testWidgets(
    'Fase 4: legacy response (level int) falls back to simple header',
    (tester) async {
      final mock = MockClient(
        (request) async => http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final service = _FakeGamificationService(apiClient: _apiWith(mock));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [gamificationServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: GamificationScreen()),
        ),
      );

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // header simples (sem levelProgress): "NÍVEL 1" + pontos.
      expect(find.text('NÍVEL 1'), findsOneWidget);
      expect(find.text('20 PTS'), findsOneWidget);
    },
  );
}

class _LevelProgressService extends GamificationService {
  _LevelProgressService({required super.apiClient});

  @override
  Future<List<Achievement>> getAchievements() async => const [];

  @override
  Future<GamificationSummary> getSummary() async => const GamificationSummary(
    unlockedCount: 1,
    totalCount: 1,
    currentStreak: 1,
    bestStreak: 1,
    points: 137,
    level: 2,
    selectedBadges: [],
    levelProgress: LevelProgress(
      current: 2,
      currentName: 'Nível 2',
      currentOrder: 2,
      totalPoints: 137,
      rangeStart: 50,
      next: 3,
      nextName: 'Nível 3',
      nextThreshold: 250,
      pointsInLevel: 87,
      pointsToNext: 113,
      percent: 43.5,
      isMaxLevel: false,
      ruleVersion: 'fase4/v1',
    ),
  );

  @override
  Future<List<WellnessStreak>> getStreaks() async => const [];
}

class _MaxLevelService extends GamificationService {
  _MaxLevelService({required super.apiClient});

  @override
  Future<List<Achievement>> getAchievements() async => const [];

  @override
  Future<GamificationSummary> getSummary() async => const GamificationSummary(
    unlockedCount: 17,
    totalCount: 17,
    currentStreak: 30,
    bestStreak: 30,
    points: 5000,
    level: 6,
    selectedBadges: [],
    levelProgress: LevelProgress(
      current: 6,
      currentName: 'Nível 6',
      currentOrder: 6,
      totalPoints: 5000,
      rangeStart: 1000,
      next: null,
      nextName: null,
      nextThreshold: null,
      pointsInLevel: 4000,
      pointsToNext: null,
      percent: 100.0,
      isMaxLevel: true,
      ruleVersion: 'fase4/v1',
    ),
  );

  @override
  Future<List<WellnessStreak>> getStreaks() async => const [];
}

class _EmptyDailyPointsService extends GamificationService {
  _EmptyDailyPointsService({required super.apiClient});

  @override
  Future<List<Achievement>> getAchievements() async => const [];

  @override
  Future<GamificationSummary> getSummary() async => const GamificationSummary(
    unlockedCount: 0,
    totalCount: 1,
    currentStreak: 0,
    bestStreak: 0,
    points: 0,
    level: 1,
    selectedBadges: [],
    dailyPoints: DailyPointsSummary(
      date: '2026-08-28',
      todayTotal: 0,
      breakdown: {},
      total: 0,
      history: [],
    ),
  );

  @override
  Future<List<WellnessStreak>> getStreaks() async => const [];
}

class _LockedGamificationService extends GamificationService {
  _LockedGamificationService({required super.apiClient});

  @override
  Future<List<Achievement>> getAchievements() async => [
    const Achievement(
      code: 'SCORE_7_DAYS',
      name: '7 dias registrados',
      description: 'Registre scores em 7 dias distintos',
      category: AchievementCategory.scores,
      iconKey: 'seven_days',
      points: 20,
      progress: 5,
      target: 7,
      unlocked: false,
      unlockedAt: null,
    ),
  ];

  @override
  Future<GamificationSummary> getSummary() async => const GamificationSummary(
    unlockedCount: 0,
    totalCount: 1,
    currentStreak: 0,
    bestStreak: 0,
    points: 0,
    level: 1,
    selectedBadges: [],
  );

  @override
  Future<List<WellnessStreak>> getStreaks() async => const [];
}
