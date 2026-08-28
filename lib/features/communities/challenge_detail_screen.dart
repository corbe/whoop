/// Challenge detail (Phase 7, spec §53–§57).
///
/// Shows challenge info, current user progress (transparent calculation),
/// leaderboard with current-user highlight, join/leave with privacy gate,
/// and frozen final result when completed (spec §38, §56).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/challenge_providers.dart';
import '../../services/wellness_identity_providers.dart';
import '../../shared/models/social_identity.dart';
import '../../shared/models/challenge.dart';
import '../../core/ui/noana_widgets.dart';
import 'challenge_status_ui.dart';
import 'member_profile_screen.dart';

class ChallengeDetailScreen extends ConsumerWidget {
  const ChallengeDetailScreen({
    super.key,
    required this.communityUuid,
    required this.communityName,
    required this.challengeUuid,
  });

  final String communityUuid;
  final String communityName;
  final String challengeUuid;

  ({String communityUuid, String challengeUuid}) get _params =>
      (communityUuid: communityUuid, challengeUuid: challengeUuid);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(challengeDetailProvider(_params));
    return Scaffold(
      appBar: AppBar(title: const Text('Desafio')),
      body: detailAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Falha ao carregar desafio: $e',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(challengeDetailProvider(_params)),
                  child: const Text('Tentar novamente'),
                ),
              ],
            ),
          ),
        ),
        data: (challenge) => _buildDetail(context, ref, challenge),
      ),
    );
  }

  Widget _buildDetail(
    BuildContext context,
    WidgetRef ref,
    Challenge challenge,
  ) {
    final theme = Theme.of(context);
    final progress = challenge.currentUserProgress;
    final isParticipant = challenge.currentUserStatus == 'active';
    final isCompleted = challenge.status == ChallengeStatus.completed;
    final isCancelled = challenge.status == ChallengeStatus.cancelled;
    final countdown = challengeCountdown(challenge, DateTime.now());
    final minDays = challenge.minDays;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── cabeçalho: nome + status + contagem regressiva ──
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(challenge.name, style: theme.textTheme.titleLarge),
            ),
            _StatusChip(status: challenge.status),
          ],
        ),
        const SizedBox(height: 4),
        if (countdown.isNotEmpty)
          Text(
            countdown,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        Text(
          '${challenge.startDate} – ${challenge.endDate}',
          style: theme.textTheme.bodyMedium,
        ),
        Text(
          '${challengeAggregationLabel(challenge.aggregation)} · '
          '${challengeMetricLabel(challenge.metric)}'
          '${challenge.minDays != null ? ' · mín. ${challenge.minDays} dias' : ''}',
          style: theme.textTheme.bodyMedium,
        ),
        // Fase 3 — tipo + meta (neutro; dados insuficientes não frustram).
        if (challenge.challengeType != null &&
            challenge.challengeType != 'standard') ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                challengeTypeIcon(challenge.challengeType),
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  challengeTypeLabel(challenge.challengeType),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          if (challenge.targetValue != null) ...[
            const SizedBox(height: 2),
            Text(
              challengeTargetSentence(challenge.targetValue, progress?.percent),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
        if (challenge.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(challenge.description, style: theme.textTheme.bodyMedium),
        ],
        if (isCancelled) ...[
          const SizedBox(height: 12),
          Card(
            color: theme.colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Desafio cancelado',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
        if (isCompleted)
          _WinnerBanner(
            communityUuid: communityUuid,
            challengeUuid: challengeUuid,
          ),
        const Divider(height: 24),

        // ── ação join/leave / privacidade (spec §51–§52) ──
        if (!isCompleted && !isCancelled) ...[
          if (isParticipant)
            OutlinedButton.icon(
              onPressed: () => _confirmLeave(context, ref, challenge, progress),
              icon: const Icon(Icons.exit_to_app),
              label: const Text('Sair do desafio'),
            )
          else
            FilledButton.icon(
              onPressed: () async {
                try {
                  await ref
                      .read(challengeActionControllerProvider)
                      .joinChallenge(communityUuid, challengeUuid);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Não foi possível entrar: '
                          '${_privacyMessage(e, challenge.metric)}',
                        ),
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.emoji_events_outlined),
              label: const Text('Participar do desafio'),
            ),
          if (!isParticipant)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Este desafio usa ${challengeMetricLabel(challenge.metric)}. '
                'Ative o compartilhamento de '
                '${challengeMetricLabel(challenge.metric)} '
                'nas configurações de privacidade da comunidade para participar.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
        ],

        const Divider(height: 24),

        // ── progresso transparente (spec §55) ──
        if (progress != null && isParticipant) ...[
          Text('Seu progresso', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (isCompleted)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Posição final', style: theme.textTheme.bodySmall),
                    Text(
                      '#${progress.rank ?? '—'}',
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('Pontuação final', style: theme.textTheme.bodySmall),
                    Text(
                      progress.score?.toStringAsFixed(1) ?? '—',
                      style: theme.textTheme.headlineMedium,
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sua ${challengeAggregationLabel(challenge.aggregation).toLowerCase()}',
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      progress.score == null
                          ? 'Sem dados ainda'
                          : progress.score!.toStringAsFixed(1),
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${progress.daysCount} ${progress.daysCount == 1 ? 'dia válido' : 'dias válidos'}'
                      '${challenge.minDays != null ? ' · mínimo: ${challenge.minDays}' : ''}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    // Fase 3 — barra de meta limitada visualmente a 100%
                    // (o valor real pode superar a meta; a UI não explode).
                    if (progress.percent != null &&
                        challenge.targetValue != null) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: (progress.percent! / 100).clamp(0.0, 1.0),
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        challengeTargetSentence(
                          challenge.targetValue,
                          progress.percent,
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (minDays != null) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: (progress.daysCount / minDays).clamp(0.0, 1.0),
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${progress.daysCount} / $minDays dias',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (!progress.qualified && minDays != null)
                      Text(
                        'Não qualificado: faltam dias válidos.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],

        const Divider(height: 24),

        // ── regras legíveis (spec: "Como funciona") ──
        Text('Como funciona', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children:
                  challengeRules(challenge, userSharesMetric: isParticipant)
                      .map(
                        (rule) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 2, right: 8),
                                child: Icon(
                                  Icons.check_circle_outline,
                                  size: 18,
                                ),
                              ),
                              Expanded(child: Text(rule)),
                            ],
                          ),
                        ),
                      )
                      .toList(),
            ),
          ),
        ),
        const Divider(height: 24),

        Text('Classificação', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _RankingSection(
          communityUuid: communityUuid,
          challengeUuid: challengeUuid,
        ),
      ],
    );
  }

  Future<void> _confirmLeave(
    BuildContext context,
    WidgetRef ref,
    Challenge challenge,
    ChallengeProgress? progress,
  ) async {
    final hasProgress =
        progress != null && (progress.daysCount > 0 || progress.score != null);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sair do desafio?'),
        content: Text(
          hasProgress
              ? 'Seu progresso (${progress.daysCount} '
                    '${progress.daysCount == 1 ? 'dia válido' : 'dias válidos'}) '
                    'será perdido e você sai do ranking.'
              : 'Você sairá do desafio e não aparecerá mais no ranking.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sair'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref
        .read(challengeActionControllerProvider)
        .leaveChallenge(communityUuid, challengeUuid);
  }

  String _privacyMessage(Object e, String metric) {
    final text = e.toString();
    if (text.toLowerCase().contains('compartilhamento')) {
      return 'Ative o compartilhamento de ${challengeMetricLabel(metric)} na '
          'comunidade para participar (Privacidade na aba Visão geral).';
    }
    return text;
  }
}

/// Status chip with brand colors (no random colors — M3 scheme tones).
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final ChallengeStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status) {
      ChallengeStatus.active => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      ChallengeStatus.upcoming => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      ChallengeStatus.completed => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      ChallengeStatus.cancelled => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      ChallengeStatus.draft => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        challengeStatusLabel(status),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Winner banner for a finished challenge — top of the FROZEN ranking
/// (backend-authoritative; never client-computed).
class _WinnerBanner extends ConsumerWidget {
  const _WinnerBanner({
    required this.communityUuid,
    required this.challengeUuid,
  });

  final String communityUuid;
  final String challengeUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ref
        .watch(
          challengeRankingProvider((
            communityUuid: communityUuid,
            challengeUuid: challengeUuid,
          )),
        )
        .maybeWhen(
          data: (ranking) {
            final winner = ranking.entries.isEmpty
                ? null
                : ranking.entries.first;
            final name = winner == null
                ? 'Sem vencedor — nenhum participante com dados válidos.'
                : SocialIdentity(
                    personUuid: winner.personUuid,
                    displayName: winner.displayName,
                    avatarUrl: winner.avatarUrl,
                  ).safeDisplayName;
            return Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Text('🏆', style: TextStyle(fontSize: 24)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        winner == null ? name : 'Vencedor: $name',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          orElse: () => const SizedBox.shrink(),
        );
  }
}

class _RankingSection extends ConsumerWidget {
  const _RankingSection({
    required this.communityUuid,
    required this.challengeUuid,
  });

  final String communityUuid;
  final String challengeUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rankingAsync = ref.watch(
      challengeRankingProvider((
        communityUuid: communityUuid,
        challengeUuid: challengeUuid,
      )),
    );
    final me = ref.watch(currentWellnessPersonProvider).valueOrNull;
    final myUuid = me?.uuid;
    return rankingAsync.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Text('Falha ao carregar ranking: $e'),
      data: (ranking) {
        if (ranking.entries.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Nenhum participante com dados válidos ainda.'),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: ranking.entries.map((e) {
            final isMe = myUuid != null && e.personUuid == myUuid;
            return Card(
              margin: const EdgeInsets.only(bottom: 6),
              color: isMe
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: NoanaRankRow(
                position: e.position ?? 0,
                name: SocialIdentity(
                  personUuid: e.personUuid,
                  displayName: e.displayName,
                  avatarUrl: e.avatarUrl,
                ).safeDisplayName,
                value: e.score.toStringAsFixed(1),
                avatarUrl: e.avatarUrl,
                subtitle: e.qualified
                    ? '${e.daysCount} ${e.daysCount == 1 ? 'dia' : 'dias'}'
                    : 'Não qualificado',
                highlight: e.personUuid == myUuid,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MemberProfileScreen(
                      communityUuid: communityUuid,
                      personUuid: e.personUuid,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
