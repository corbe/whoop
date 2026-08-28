/// Challenge status presentation helpers (Social Phase).
///
/// Pure functions — no fake data, no clocks hidden inside. All date math is
/// calendar-day based on the challenge's own start/end dates (the backend is
/// the source of truth for status; these helpers only describe it in words).
library;

import 'package:flutter/material.dart';

import '../../shared/models/challenge.dart';

/// Calendar-day difference (a - b), using local dates only.
int calendarDaysBetween(DateTime a, DateTime b) {
  final da = DateTime(a.year, a.month, a.day);
  final db = DateTime(b.year, b.month, b.day);
  return da.difference(db).inDays;
}

/// Days from [today] until the challenge starts (negative when started).
int daysUntilStart(Challenge challenge, DateTime today) => calendarDaysBetween(
  DateTime.parse(challenge.startDate),
  DateTime(today.year, today.month, today.day),
);

/// Days from [today] until the challenge ends (negative when finished).
int daysUntilEnd(Challenge challenge, DateTime today) => calendarDaysBetween(
  DateTime.parse(challenge.endDate),
  DateTime(today.year, today.month, today.day),
);

/// Short human label for a status (PT, matches app l10n tone).
String challengeStatusLabel(ChallengeStatus status) {
  switch (status) {
    case ChallengeStatus.draft:
      return 'Rascunho';
    case ChallengeStatus.upcoming:
      return 'Em breve';
    case ChallengeStatus.active:
      return 'Ativo';
    case ChallengeStatus.completed:
      return 'Concluído';
    case ChallengeStatus.cancelled:
      return 'Cancelado';
  }
}

/// Countdown line for cards/banners. Returns '' when there is nothing
/// meaningful to say (e.g. draft with no dates).
String challengeCountdown(Challenge challenge, DateTime today) {
  switch (challenge.status) {
    case ChallengeStatus.active:
      final d = daysUntilEnd(challenge, today);
      if (d < 0) return 'Encerrado';
      if (d == 0) return '🔥 Último dia!';
      return '🔥 $d ${d == 1 ? 'dia restante' : 'dias restantes'}';
    case ChallengeStatus.upcoming:
      final d = daysUntilStart(challenge, today);
      if (d <= 0) return 'Começa hoje';
      return 'Começa em $d ${d == 1 ? 'dia' : 'dias'}';
    case ChallengeStatus.completed:
      return 'Finalizado';
    case ChallengeStatus.cancelled:
      return 'Cancelado';
    case ChallengeStatus.draft:
      return '';
  }
}

/// Metric label (PT) — shared by tab, detail and rules.
String challengeMetricLabel(String metric) {
  switch (metric) {
    case 'readiness':
      return 'Readiness';
    case 'sleep':
      return 'Sleep';
    case 'activity':
      return 'Activity';
    case 'strain':
      return 'Strain';
    default:
      return metric;
  }
}

/// Aggregation label (PT) — shared by tab, detail and rules.
String challengeAggregationLabel(String aggregation) {
  switch (aggregation) {
    case 'average':
      return 'Média';
    case 'best':
      return 'Melhor dia';
    case 'days_recorded':
      return 'Dias registrados';
    case 'sum':
      return 'Soma';
    default:
      return aggregation;
  }
}

/// Fase 3 — tipo canônico do desafio (label amigável).
String challengeTypeLabel(String? type) {
  switch (type) {
    case 'sum_zones':
      return 'Soma de zonas';
    case 'sleep_consistency':
      return 'Consistência de sono';
    case 'recovery_king':
      return 'Rei da recuperação';
    default:
      return 'Desafio';
  }
}

/// Fase 3 — descrição curta do tipo (regras legíveis, sem fórmula).
String challengeTypeDescription(String? type) {
  switch (type) {
    case 'sum_zones':
      return 'Some pontos de strain durante o desafio para atingir a meta.';
    case 'sleep_consistency':
      return 'Sua média de sono no período conta — quanto mais perto da meta, melhor.';
    case 'recovery_king':
      return 'A melhor prontidão média do grupo vence.';
    default:
      return '';
  }
}

/// Fase 3 — frase de meta (progresso vs target), neutra e sem culpa.
String challengeTargetSentence(int? targetValue, double? percent) {
  if (targetValue == null) {
    return 'Sem meta fixa — o melhor do grupo vence.';
  }
  final pct = percent == null ? 0 : percent.clamp(0.0, 100.0);
  if (percent == null) {
    return 'Meta: $targetValue. Registre dados para ver seu progresso.';
  }
  return 'Meta: $targetValue · ${pct.toStringAsFixed(0)}%';
}

/// Fase 3 — ícone do tipo (design tokens).
IconData challengeTypeIcon(String? type) {
  switch (type) {
    case 'sum_zones':
      return Icons.add_chart;
    case 'sleep_consistency':
      return Icons.bedtime_outlined;
    case 'recovery_king':
      return Icons.workspace_premium_outlined;
    default:
      return Icons.emoji_events_outlined;
  }
}

/// How the aggregation maps to a goal sentence (user-facing, no internals).
String challengeGoalSentence(String metric, String aggregation) {
  final metricLabel = challengeMetricLabel(metric);
  switch (aggregation) {
    case 'average':
      return 'Sua $metricLabel média no período conta como pontuação.';
    case 'best':
      return 'Seu melhor dia de $metricLabel no período conta como pontuação.';
    case 'days_recorded':
      return 'Cada dia com $metricLabel registrada conta 1 ponto.';
    default:
      return 'Registre $metricLabel durante o período do desafio.';
  }
}

/// Rules block for the detail screen — every sentence maps to a real backend
/// behavior (aggregation, min_days qualification, tie-break, privacy gate).
List<String> challengeRules(
  Challenge challenge, {
  required bool userSharesMetric,
}) {
  final metricLabel = challengeMetricLabel(challenge.metric);
  final aggLabel = challengeAggregationLabel(challenge.aggregation);
  final rules = <String>[
    'Objetivo: ${challengeGoalSentence(challenge.metric, challenge.aggregation)}',
    'Pontuação: usa apenas os valores de $metricLabel já registrados no seu '
        'histórico — nenhuma fórmula de saúde é inventada.',
    'Agregação: $aggLabel entre ${challenge.startDate} e ${challenge.endDate}.',
    if (challenge.minDays != null)
      'Qualificação: para aparecer no ranking final, registre pelo menos '
          '${challenge.minDays} ${challenge.minDays == 1 ? 'dia válido' : 'dias válidos'} '
          'no período.',
    'Desempate: mais pontos; em empate, mais dias válidos; depois, quem '
        'entrou primeiro.',
    if (!userSharesMetric)
      'Privacidade: compartilhe $metricLabel nas configurações da comunidade '
          'para participar e aparecer no ranking.',
  ];
  return rules;
}
