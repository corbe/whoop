/// Challenge status/countdown/rules helpers (Social Phase) — pure functions.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/features/communities/challenge_status_ui.dart';
import 'package:noana_wellness_app/shared/models/challenge.dart';

Challenge _challenge({
  ChallengeStatus status = ChallengeStatus.active,
  String start = '2026-08-10',
  String end = '2026-08-20',
  String metric = 'readiness',
  String aggregation = 'average',
  int? minDays,
}) {
  return Challenge(
    uuid: 'challenge-1',
    communityUuid: 'community-1',
    name: 'Desafio Teste',
    metric: metric,
    aggregation: aggregation,
    startDate: start,
    endDate: end,
    status: status,
    minDays: minDays,
  );
}

void main() {
  group('calendarDaysBetween', () {
    test('same day is zero', () {
      expect(
        calendarDaysBetween(DateTime(2026, 8, 16), DateTime(2026, 8, 16)),
        0,
      );
    });

    test('positive when a is later', () {
      expect(
        calendarDaysBetween(DateTime(2026, 8, 20), DateTime(2026, 8, 10)),
        10,
      );
    });

    test('negative when a is earlier', () {
      expect(
        calendarDaysBetween(DateTime(2026, 8, 10), DateTime(2026, 8, 20)),
        -10,
      );
    });

    test('ignores time-of-day (calendar days)', () {
      expect(
        calendarDaysBetween(
          DateTime(2026, 8, 16, 23, 59),
          DateTime(2026, 8, 16, 0, 1),
        ),
        0,
      );
    });
  });

  group('challengeCountdown', () {
    final today = DateTime(2026, 8, 16);

    test('active shows days remaining', () {
      expect(challengeCountdown(_challenge(), today), '🔥 4 dias restantes');
    });

    test('active singular day', () {
      expect(
        challengeCountdown(_challenge(end: '2026-08-17'), today),
        '🔥 1 dia restante',
      );
    });

    test('active last day', () {
      expect(
        challengeCountdown(_challenge(end: '2026-08-16'), today),
        '🔥 Último dia!',
      );
    });

    test('active finished date says encerrado', () {
      expect(
        challengeCountdown(_challenge(end: '2026-08-15'), today),
        'Encerrado',
      );
    });

    test('upcoming shows start countdown', () {
      expect(
        challengeCountdown(
          _challenge(
            status: ChallengeStatus.upcoming,
            start: '2026-08-18',
            end: '2026-08-28',
          ),
          today,
        ),
        'Começa em 2 dias',
      );
    });

    test('upcoming today', () {
      expect(
        challengeCountdown(
          _challenge(
            status: ChallengeStatus.upcoming,
            start: '2026-08-16',
            end: '2026-08-26',
          ),
          today,
        ),
        'Começa hoje',
      );
    });

    test('completed and cancelled have fixed labels', () {
      expect(
        challengeCountdown(
          _challenge(status: ChallengeStatus.completed),
          today,
        ),
        'Finalizado',
      );
      expect(
        challengeCountdown(
          _challenge(status: ChallengeStatus.cancelled),
          today,
        ),
        'Cancelado',
      );
    });
  });

  group('challengeStatusLabel', () {
    test('maps every status to a PT label', () {
      expect(challengeStatusLabel(ChallengeStatus.active), 'Ativo');
      expect(challengeStatusLabel(ChallengeStatus.upcoming), 'Em breve');
      expect(challengeStatusLabel(ChallengeStatus.completed), 'Concluído');
      expect(challengeStatusLabel(ChallengeStatus.cancelled), 'Cancelado');
      expect(challengeStatusLabel(ChallengeStatus.draft), 'Rascunho');
    });
  });

  group('challengeRules', () {
    test('explains goal, aggregation, tie-break and qualification', () {
      final rules = challengeRules(
        _challenge(minDays: 5),
        userSharesMetric: true,
      );
      final text = rules.join('\n');
      expect(text, contains('Objetivo'));
      expect(text, contains('Média entre 2026-08-10 e 2026-08-20'));
      expect(text, contains('5 dias válidos'));
      expect(text, contains('Desempate'));
      expect(
        text,
        isNot(contains('Privacidade')),
        reason: 'sharing bullet only for non-participants',
      );
    });

    test('privacy bullet appears when the user does not share the metric', () {
      final rules = challengeRules(
        _challenge(metric: 'sleep', aggregation: 'best'),
        userSharesMetric: false,
      );
      final text = rules.join('\n');
      expect(text, contains('compartilhe Sleep'));
      expect(text, contains('Melhor dia'));
    });

    test('never mentions internal identifiers or formulas', () {
      final rules = challengeRules(_challenge(), userSharesMetric: true);
      final text = rules.join('\n');
      expect(text, isNot(contains('uuid')));
      expect(text, isNot(contains('personUuid')));
      expect(text, isNot(contains('DailyScore')), reason: 'user-facing text');
      expect(text, isNot(contains('z-score')));
    });
  });

  group('Fase 3 — tipos de desafio (2026-08-28)', () {
    test('challengeTypeLabel maps the three types', () {
      expect(challengeTypeLabel('sum_zones'), 'Soma de zonas');
      expect(challengeTypeLabel('sleep_consistency'), 'Consistência de sono');
      expect(challengeTypeLabel('recovery_king'), 'Rei da recuperação');
      expect(challengeTypeLabel('standard'), 'Desafio');
      expect(challengeTypeLabel(null), 'Desafio');
    });

    test('challengeTargetSentence without target is comparative', () {
      expect(
        challengeTargetSentence(null, null),
        'Sem meta fixa — o melhor do grupo vence.',
      );
    });

    test('challengeTargetSentence with target and no data is neutral', () {
      final s = challengeTargetSentence(50, null);
      expect(s, contains('50'));
      expect(s, isNot(contains('NaN')));
    });

    test('challengeTargetSentence clamps percent to 100 visually', () {
      final s = challengeTargetSentence(60, 133.3);
      expect(s, contains('100%'));
      expect(s, isNot(contains('133')));
    });

    test('challengeTypeDescription covers the three types', () {
      expect(challengeTypeDescription('sum_zones'), isNotEmpty);
      expect(challengeTypeDescription('sleep_consistency'), isNotEmpty);
      expect(challengeTypeDescription('recovery_king'), isNotEmpty);
      expect(challengeTypeDescription(null), isEmpty);
    });
  });
}
