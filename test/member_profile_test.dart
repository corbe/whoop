/// Member social profile (Social Phase): model parsing + screen rendering
/// with real backend shape; empty states; NO physiological labels.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/features/communities/member_profile_screen.dart';
import 'package:noana_wellness_app/services/community_providers.dart';
import 'package:noana_wellness_app/shared/models/social_profile.dart';

const _profileJson = {
  'person_uuid': '11111111-2222-3333-4444-555555555555',
  'display_name': 'Maria',
  'avatar_url': '',
  'role': 'member',
  'status': 'active',
  'joined_at': '2026-06-01T12:00:00Z',
  'community_rank': {'rank': 4, 'total': 28, 'metric': 'readiness', 'period': 'week'},
  'challenges': {'active': 1, 'completed': 3, 'wins': 1, 'top_3': 2},
  'badges': [
    {'code': 'first_challenge', 'name': 'Primeiro Desafio', 'icon_key': ''},
    {'code': 'challenge_completed', 'name': 'Desafio Concluído', 'icon_key': ''},
  ],
  'streak_days': 12,
};

const _emptyJson = {
  'person_uuid': '22222222-2222-3333-4444-555555555555',
  'display_name': '',
  'avatar_url': '',
  'role': 'member',
  'status': 'active',
  'joined_at': null,
  'community_rank': {'rank': null, 'total': null, 'metric': 'readiness', 'period': 'week'},
  'challenges': {'active': 0, 'completed': 0, 'wins': 0, 'top_3': 0},
  'badges': <Map<String, dynamic>>[],
  'streak_days': 0,
};

Widget _screen(MemberSocialProfile profile) {
  return ProviderScope(
    overrides: [
      memberSocialProfileProvider.overrideWith((ref, params) async => profile),
    ],
    child: const MaterialApp(
      home: MemberProfileScreen(
        communityUuid: 'c1',
        personUuid: 'p1',
      ),
    ),
  );
}

void main() {
  group('MemberSocialProfile model', () {
    test('parses the backend response shape', () {
      final profile = MemberSocialProfile.fromJson(_profileJson);
      expect(profile.personUuid, '11111111-2222-3333-4444-555555555555');
      expect(profile.displayName, 'Maria');
      expect(profile.role, 'member');
      expect(profile.communityRank.rank, 4);
      expect(profile.communityRank.total, 28);
      expect(profile.challenges.active, 1);
      expect(profile.challenges.completed, 3);
      expect(profile.challenges.wins, 1);
      expect(profile.challenges.top3, 2);
      expect(profile.badges, hasLength(2));
      expect(profile.badges.first.code, 'first_challenge');
      expect(profile.streakDays, 12);
    });

    test('never exposes physiological keys', () {
      final json = Map<String, dynamic>.from(_profileJson);
      const forbidden = [
        'hr', 'hrv', 'rhr', 'spo2', 'blood_pressure', 'temperature',
        'sleep', 'readiness', 'strain', 'health_score', 'glucose',
        'daily_score', 'recovery', 'stress',
      ];
      for (final key in forbidden) {
        expect(json.containsKey(key), isFalse, reason: 'leak: $key');
      }
    });
  });

  group('MemberProfileScreen', () {
    testWidgets('renders identity, rank, streak, challenges and badges',
        (tester) async {
      await tester.pumpWidget(_screen(MemberSocialProfile.fromJson(_profileJson)));
      await tester.pumpAndSettle();

      expect(find.text('Maria'), findsOneWidget);
      expect(find.text('Membro'), findsOneWidget); // role label
      expect(find.text('#4'), findsOneWidget);
      expect(find.text('de 28'), findsOneWidget);
      expect(find.text('12 dias'), findsOneWidget);
      expect(find.text('Desafios'), findsOneWidget);
      expect(find.text('Ativos'), findsOneWidget);
      expect(find.text('Concluídos'), findsOneWidget);
      expect(find.text('Vitórias'), findsOneWidget);
      expect(find.text('Top 3'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Primeiro Desafio'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Primeiro Desafio'), findsOneWidget);
      expect(find.text('Desafio Concluído'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('Membro desde'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Membro desde'), findsOneWidget);
    });

    testWidgets('empty sections show honest empty states', (tester) async {
      await tester.pumpWidget(_screen(MemberSocialProfile.fromJson(_emptyJson)));
      await tester.pumpAndSettle();

      expect(find.text('Membro'), findsWidgets); // fallback name + role
      await tester.scrollUntilVisible(
          find.text('Este membro ainda não concluiu desafios.'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Este membro ainda não concluiu desafios.'),
          findsOneWidget);
      expect(find.text('Nenhuma conquista ainda.'), findsOneWidget);
      expect(find.text('#4'), findsNothing);
      expect(find.text('12 dias'), findsNothing);
    });

    testWidgets('error state offers retry', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          memberSocialProfileProvider.overrideWith(
            (ref, params) async => throw Exception('boom'),
          ),
        ],
        child: const MaterialApp(
          home: MemberProfileScreen(
            communityUuid: 'c1',
            personUuid: 'p1',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Falha ao carregar perfil'), findsOneWidget);
      expect(find.text('Tentar novamente'), findsOneWidget);
    });
  });
}
