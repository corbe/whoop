/// Community Leaderboard (Phase 5, spec §44–§46).
///
/// Metric + period selectors, avatar/name/position/score/days_count, current
/// user highlighted. Empty states handled — never fake ranking data.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/score_providers.dart';
import '../../services/wellness_identity_providers.dart';
import '../../shared/models/score.dart';
import '../../shared/models/social_identity.dart';

class LeaderboardTab extends ConsumerStatefulWidget {
  const LeaderboardTab({super.key, required this.communityUuid});

  final String communityUuid;

  @override
  ConsumerState<LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends ConsumerState<LeaderboardTab> {
  String _metric = 'readiness';
  String _period = 'week';

  static const _metrics = [
    ('readiness', 'Readiness'),
    ('sleep', 'Sleep'),
    ('activity', 'Activity'),
    ('strain', 'Strain'),
  ];

  @override
  Widget build(BuildContext context) {
    final myPerson = ref.watch(currentWellnessPersonProvider).valueOrNull;
    final myUuid = myPerson?.uuid;
    final rankingAsync = ref.watch(communityRankingProvider((
      uuid: widget.communityUuid,
      metric: _metric,
      period: _period,
      date: null,
    )));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              DropdownButton<String>(
                value: _metric,
                items: _metrics
                    .map((m) => DropdownMenuItem(value: m.$1, child: Text(m.$2)))
                    .toList(),
                onChanged: (v) => setState(() => _metric = v ?? 'readiness'),
              ),
              const Spacer(),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'day', label: Text('Dia')),
                  ButtonSegment(value: 'week', label: Text('Semana')),
                  ButtonSegment(value: 'month', label: Text('Mês')),
                ],
                selected: {_period},
                onSelectionChanged: (s) => setState(() => _period = s.first),
              ),
            ],
          ),
        ),
        Expanded(
          child: rankingAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Falha ao carregar ranking: $e',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
            data: (ranking) => _buildRanking(context, ranking, myUuid),
          ),
        ),
      ],
    );
  }

  Widget _buildRanking(BuildContext context, CommunityRanking ranking, String? myUuid) {
    if (ranking.entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sem dados suficientes ainda.\nQuando alguém compartilhar scores nesta '
            'comunidade, o ranking aparece aqui.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final myPosition = ranking.currentUserPosition;
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(communityRankingProvider),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (myPosition != null)
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.person_pin),
                title: Text('Sua posição: #$myPosition'),
                subtitle: Text(
                  '${ranking.totalMembers} membros com dados no período',
                ),
              ),
            ),
          ...ranking.entries.map((e) => _entryTile(context, ranking, e, myUuid)),
        ],
      ),
    );
  }

  Widget _entryTile(BuildContext context, CommunityRanking ranking, CommunityRankingEntry e, String? myUuid) {
    final isMe = myUuid != null && e.personUuid == myUuid;
    final highlight = isMe || (ranking.currentUserPosition == e.position);
    final identity = SocialIdentity(
      personUuid: e.personUuid,
      displayName: e.displayName,
      avatarUrl: e.avatarUrl,
    );
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        foregroundImage: identity.hasAvatar ? NetworkImage(identity.avatarUrl) : null,
        child: identity.hasAvatar ? null : Text(identity.initial),
      ),
      title: Text(
        identity.safeDisplayName,
        style: TextStyle(
          fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Text('${e.daysCount} dia(s) de dados'),
      trailing: Text(
        e.score.toStringAsFixed(1),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: highlight ? Theme.of(context).colorScheme.primary : null,
              fontWeight: FontWeight.w600,
            ),
      ),
      tileColor: isMe ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4) : null,
    );
  }
}
