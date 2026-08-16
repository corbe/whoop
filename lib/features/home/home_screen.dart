/// Home placeholder (Phase 1+2). Shows the resolved WellnessPerson identity
/// and, when a real DailyScore exists, today's scores (Phase 5, spec §47).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/providers.dart';
import '../../core/ui/noana_widgets.dart';
import '../../services/challenge_providers.dart';
import '../../services/community_providers.dart';
import '../../services/gamification_providers.dart';
import '../../shared/models/challenge.dart';
import '../../shared/models/community.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(authServiceProvider);
    final identity = auth.currentIdentity;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RITMA'),
        actions: [
          IconButton(
            icon: const Icon(Icons.groups_outlined),
            tooltip: 'Comunidades',
            onPressed: () => context.push('/communities'),
          ),
          IconButton(
            icon: const Icon(Icons.emoji_events_outlined),
            tooltip: 'Progresso',
            onPressed: () => context.push('/gamification'),
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Chat diagnóstico',
            onPressed: () => context.push('/chat/diagnostic'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sair',
            onPressed: () => auth.logout(),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: RitmaContentShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Saudação + identidade ──
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Text(
                          _greetingName(identity),
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Bom dia,',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            _greetingName(identity),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.logout),
                        tooltip: 'Sair',
                        onPressed: () => auth.logout(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // ── SEU PROGRESSO: métricas dominantes ──
                  const RitmaSectionLabel('SEU PROGRESSO'),
                  _HomeProgressBlock(),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  // ── COMUNIDADES ──
                  const RitmaSectionLabel('COMUNIDADES'),
                  const _HomeCommunities(),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  // ── DESAFIOS ──
                  const RitmaSectionLabel('DESAFIOS'),
                  const _HomeChallenges(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 600) return const SizedBox.shrink();
          return NavigationBar(
            selectedIndex: 0,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Início',
              ),
              NavigationDestination(
                icon: Icon(Icons.groups_outlined),
                selectedIcon: Icon(Icons.groups),
                label: 'Comunidades',
              ),
              NavigationDestination(
                icon: Icon(Icons.emoji_events_outlined),
                selectedIcon: Icon(Icons.emoji_events),
                label: 'Progresso',
              ),
            ],
            onDestinationSelected: (index) {
              if (index == 1) context.push('/communities');
              if (index == 2) context.push('/gamification');
            },
          );
        },
      ),
    );
  }

  String _greetingName(CurrentIdentity? identity) {
    final raw = identity?.username ?? '—';
    if (raw.isEmpty) return '—';
    return raw[0].toUpperCase() + raw.substring(1);
  }
}

/// SEU PROGRESSO — métricas grandes (streak + conquistas reais).
class _HomeProgressBlock extends ConsumerWidget {
  const _HomeProgressBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(gamificationSummaryProvider);
    final summary = summaryAsync.valueOrNull;
    final streak = summary?.currentStreak ?? 0;
    final unlocked = summary?.unlockedCount ?? 0;
    return Row(
      children: [
        Expanded(
          child: _HomeMetric(
            value: '$streak',
            label: streak == 1 ? 'dia seguido' : 'dias seguidos',
            icon: '🔥',
          ),
        ),
        Expanded(
          child: _HomeMetric(
            value: '$unlocked',
            label: unlocked == 1 ? 'conquista' : 'conquistas',
            icon: '🏆',
          ),
        ),
        if (summary != null && summary.points > 0)
          Expanded(
            child: _HomeMetric(
              value: '${summary.points}',
              label: 'pontos',
              icon: '⭐',
            ),
          ),
      ],
    );
  }
}

class _HomeMetric extends StatelessWidget {
  const _HomeMetric({
    required this.value,
    required this.label,
    required this.icon,
  });

  final String value;
  final String label;
  final String icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 4),
            Text(
              value,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// COMUNIDADES — atalhos reais (até 3) ou empty state honesto.
class _HomeCommunities extends ConsumerWidget {
  const _HomeCommunities();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myCommunitiesProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text(
        'Falha ao carregar comunidades: $e',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      data: (communities) {
        if (communities.isEmpty) {
          return const NoanaEmptyState(
            message: 'Você ainda não participa de comunidades.',
            icon: Icons.groups_outlined,
          );
        }
        return Column(
          children: [
            for (final c in communities.take(3))
              NoanaCommunityRow(
                name: c.name,
                memberCount: c.memberCount,
                avatarUrl: c.avatarUrl,
                onTap: () => context.push('/communities/${c.uuid}'),
              ),
          ],
        );
      },
    );
  }
}

/// DESAFIOS — desafios ativos reais (nome + progresso) ou empty state.
class _HomeChallenges extends ConsumerWidget {
  const _HomeChallenges();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final communitiesAsync = ref.watch(myCommunitiesProvider);
    final communities = communitiesAsync.valueOrNull ?? const <Community>[];
    final active = <({String name, String community, double progress})>[];
    for (final c in communities) {
      final challenges =
          ref.watch(communityChallengesProvider(c.uuid)).valueOrNull;
      if (challenges == null) continue;
      for (final ch in challenges) {
        if (ch.status == ChallengeStatus.active) {
          active.add((
            name: ch.name,
            community: c.name,
            progress: ch.minDays != null && ch.minDays! > 0
                ? ((ch.currentUserProgress?.daysCount ?? 0) / ch.minDays!)
                    .clamp(0, 1)
                : 0,
          ));
        }
      }
    }
    if (active.isEmpty) {
      return const NoanaEmptyState(
        message: 'Nenhum desafio ativo no momento.',
        icon: Icons.flag_outlined,
      );
    }
    return Column(
      children: [
        for (final d in active.take(3))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Text('🎯'),
            title: Text(d.name,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(d.community,
                style: Theme.of(context).textTheme.bodySmall),
            trailing: d.progress > 0
                ? Text(
                    '${(d.progress * 100).round()}%',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700),
                  )
                : null,
          ),
      ],
    );
  }
}

