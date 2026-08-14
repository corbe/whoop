/// Challenges tab (Phase 7, spec §48–§49).
///
/// Sections: Active / Upcoming / Completed. Create button only for
/// owner/admin (backend enforces too — spec §10).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/challenge_providers.dart';
import '../../shared/models/challenge.dart';
import 'challenge_detail_screen.dart';
import 'create_challenge_screen.dart';

class ChallengesTab extends ConsumerWidget {
  const ChallengesTab({
    super.key,
    required this.communityUuid,
    required this.communityName,
    required this.isOwnerOrAdmin,
  });

  final String communityUuid;
  final String communityName;
  final bool isOwnerOrAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final challengesAsync = ref.watch(communityChallengesProvider(communityUuid));
    return Column(
      children: [
        if (isOwnerOrAdmin)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CreateChallengeScreen(
                      communityUuid: communityUuid,
                      communityName: communityName,
                    ),
                  ),
                ),
                icon: const Icon(Icons.emoji_events_outlined),
                label: const Text('Criar desafio'),
              ),
            ),
          ),
        Expanded(
          child: challengesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Falha ao carregar desafios: $e',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => ref.invalidate(
                          communityChallengesProvider(communityUuid)),
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            ),
            data: (challenges) => _buildList(context, challenges),
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, List<Challenge> challenges) {
    final active = challenges
        .where((c) => c.status == ChallengeStatus.active)
        .toList();
    final upcoming = challenges
        .where((c) => c.status == ChallengeStatus.upcoming)
        .toList();
    final completed = challenges
        .where((c) => c.status == ChallengeStatus.completed)
        .toList();

    if (challenges.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nenhum desafio ainda. Crie o primeiro para competir com a comunidade!',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (active.isNotEmpty) ...[
          _SectionHeader('Ativos'),
          ...active.map((c) => _ChallengeCard(communityUuid, c)),
        ],
        if (upcoming.isNotEmpty) ...[
          _SectionHeader('Em breve'),
          ...upcoming.map((c) => _ChallengeCard(communityUuid, c)),
        ],
        if (completed.isNotEmpty) ...[
          _SectionHeader('Concluídos'),
          ...completed.map((c) => _ChallengeCard(communityUuid, c)),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard(this.communityUuid, this.challenge);

  final String communityUuid;
  final Challenge challenge;

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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = challenge.currentUserProgress;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.emoji_events_outlined),
        title: Text(challenge.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${challenge.startDate} – ${challenge.endDate}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '${_aggLabel(challenge.aggregation)} · ${_metricLabel(challenge.metric)}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '${challenge.participantCount} participantes'
              '${progress != null && progress.rank != null ? ' · Sua posição: #${progress.rank}' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        isThreeLine: true,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChallengeDetailScreen(
              communityUuid: communityUuid,
              communityName: challenge.name,
              challengeUuid: challenge.uuid,
            ),
          ),
        ),
      ),
    );
  }
}
