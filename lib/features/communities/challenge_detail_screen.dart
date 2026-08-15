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

  String _metricLabel(String metric) {
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

  String _aggLabel(String aggregation) {
    switch (aggregation) {
      case 'average':
        return 'Média';
      case 'best':
        return 'Melhor dia';
      case 'days_recorded':
        return 'Dias registrados';
      default:
        return aggregation;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(challengeDetailProvider(_params));
    return Scaffold(
      appBar: AppBar(title: const Text('Desafio')),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Falha ao carregar desafio: $e', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(challengeDetailProvider(_params)),
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

  Widget _buildDetail(BuildContext context, WidgetRef ref, Challenge challenge) {
    final theme = Theme.of(context);
    final progress = challenge.currentUserProgress;
    final isParticipant = challenge.currentUserStatus == 'active';
    final isCompleted = challenge.status == ChallengeStatus.completed;
    final isCancelled = challenge.status == ChallengeStatus.cancelled;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(challenge.name, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('${challenge.startDate} – ${challenge.endDate}',
            style: theme.textTheme.bodyMedium),
        Text(
          '${_aggLabel(challenge.aggregation)} · ${_metricLabel(challenge.metric)}'
          '${challenge.minDays != null ? ' · mín. ${challenge.minDays} dias' : ''}',
          style: theme.textTheme.bodyMedium,
        ),
        if (challenge.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(challenge.description, style: theme.textTheme.bodyMedium),
        ],
        if (isCancelled) ...[
          const SizedBox(height: 12),
          const Card(
            color: Colors.orange,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('Desafio cancelado',
                  style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
        const Divider(height: 24),

        // ── ação join/leave / privacidade (spec §51–§52) ──
        if (!isCompleted && !isCancelled) ...[
          if (isParticipant)
            OutlinedButton.icon(
              onPressed: () async {
                await ref
                    .read(challengeActionControllerProvider)
                    .leaveChallenge(communityUuid, challengeUuid);
              },
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
                              '${_privacyMessage(e, challenge.metric)}')),
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
                'Este desafio usa ${_metricLabel(challenge.metric)}. '
                'Ative o compartilhamento de ${_metricLabel(challenge.metric)} '
                'nas configurações de privacidade da comunidade para participar.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.secondary),
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
                    Text('Final position',
                        style: theme.textTheme.bodySmall),
                    Text('#${progress.rank ?? '—'}',
                        style: theme.textTheme.headlineMedium),
                    const SizedBox(height: 8),
                    Text('Final score',
                        style: theme.textTheme.bodySmall),
                    Text(progress.score?.toStringAsFixed(1) ?? '—',
                        style: theme.textTheme.headlineMedium),
                  ],
                ),
              ),
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sua ${_aggLabel(challenge.aggregation).toLowerCase()}',
                        style: theme.textTheme.bodySmall),
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
                    if (!progress.qualified && challenge.minDays != null)
                      Text(
                        'Não qualificado: faltam dias válidos.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                  ],
                ),
              ),
            ),
          const Divider(height: 24),
        ],

        Text('Classificação', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _RankingSection(communityUuid: communityUuid, challengeUuid: challengeUuid),
      ],
    );
  }

  String _privacyMessage(Object e, String metric) {
    final text = e.toString();
    if (text.toLowerCase().contains('compartilhamento')) {
      return 'Ative o compartilhamento de ${_metricLabel(metric)} na '
          'comunidade para participar (Privacidade na aba Visão geral).';
    }
    return text;
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
    final rankingAsync = ref.watch(challengeRankingProvider(
        (communityUuid: communityUuid, challengeUuid: challengeUuid)));
    final me = ref.watch(currentWellnessPersonProvider).valueOrNull;
    final myUuid = me?.uuid;
    return rankingAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
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
              child: ListTile(
                dense: true,
                leading: SizedBox(
                  width: 36,
                  child: Text(
                    e.position == null ? '–' : '#${e.position}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                title: Text(
                  SocialIdentity(
                    personUuid: e.personUuid,
                    displayName: e.displayName,
                    avatarUrl: e.avatarUrl,
                  ).safeDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: e.qualified
                    ? Text('${e.daysCount} ${e.daysCount == 1 ? 'dia' : 'dias'}')
                    : const Text('Não qualificado'),
                trailing: Text(
                  e.score.toStringAsFixed(1),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
