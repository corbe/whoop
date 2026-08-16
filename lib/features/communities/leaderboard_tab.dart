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
import '../../core/ui/noana_widgets.dart';
import 'member_profile_screen.dart';
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
    final theme = Theme.of(context);
    final myPerson = ref.watch(currentWellnessPersonProvider).valueOrNull;
    final myUuid = myPerson?.uuid;
    final rankingAsync = ref.watch(communityRankingProvider((
      uuid: widget.communityUuid,
      metric: _metric,
      period: _period,
      date: null,
    )));
    final ranking = rankingAsync.valueOrNull;
    final metricLabel =
        _metrics.firstWhere((m) => m.$1 == _metric, orElse: () => _metrics[0]).$2;

    // Valor real do METRIC BLOCK: score do próprio usuário quando disponível,
    // senão o primeiro entry — dados reais, nunca fabricados.
    String? metricValue;
    if (ranking != null && ranking.entries.isNotEmpty) {
      if (myUuid != null) {
        for (final e in ranking.entries) {
          if (e.personUuid == myUuid) {
            metricValue = e.score.toStringAsFixed(1);
            break;
          }
        }
      }
      metricValue ??= ranking.entries.first.score.toStringAsFixed(1);
    }

    return Column(
      children: [
        // ── METRIC BLOCK: a métrica é o assunto da tela ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Column(
            children: [
              InkWell(
                onTap: () => _showMetricMenu(context),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        metricLabel.toUpperCase(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down,
                          color: Color(0xFF9E9E9E)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                metricValue ?? '–',
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              RitmaSegmentedControl(
                options: const [
                  ('day', 'Dia'),
                  ('week', 'Semana'),
                  ('month', 'Mês'),
                ],
                selected: _period,
                onChanged: (v) => setState(() => _period = v),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        Expanded(
          child: rankingAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Falha ao carregar ranking: $e',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () =>
                          ref.invalidate(communityRankingProvider),
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            ),
            data: (ranking) => _buildRanking(context, ranking, myUuid),
          ),
        ),
      ],
    );
  }

  Future<void> _showMetricMenu(BuildContext context) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(120, 120, 120, 120),
      items: [
        for (final m in _metrics)
          PopupMenuItem(value: m.$1, child: Text(m.$2)),
      ],
    );
    if (selected != null && mounted) {
      setState(() => _metric = selected);
    }
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
    return NoanaRankRow(
      position: e.position,
      name: e.displayName.isNotEmpty ? e.displayName : 'Membro',
      value: e.score.toStringAsFixed(1),
      avatarUrl: e.avatarUrl,
      subtitle: '${e.daysCount} ${e.daysCount == 1 ? 'dia' : 'dias'} de dados',
      highlight: highlight,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MemberProfileScreen(
            communityUuid: widget.communityUuid,
            personUuid: e.personUuid,
          ),
        ),
      ),
    );
  }
}
