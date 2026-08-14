/// Home placeholder (Phase 1+2). Shows the resolved WellnessPerson identity
/// and, when a real DailyScore exists, today's scores (Phase 5, spec §47).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../services/gamification_providers.dart';
import '../../services/score_providers.dart';
import '../../services/wellness_identity_providers.dart';
import '../../shared/models/score.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final identity = auth.currentIdentity;
    final personAsync = ref.watch(currentWellnessPersonProvider);
    final latestScoreAsync = ref.watch(latestDailyScoreProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Noana Wellness'),
        actions: [
          IconButton(
            icon: const Icon(Icons.groups_outlined),
            tooltip: 'Comunidades',
            onPressed: () => context.go('/communities'),
          ),
          IconButton(
            icon: const Icon(Icons.emoji_events_outlined),
            tooltip: 'Progresso',
            onPressed: () => context.go('/gamification'),
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Chat diagnóstico',
            onPressed: () => context.go('/chat/diagnostic'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sair',
            onPressed: () => auth.logout(),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.self_improvement, size: 64, color: Color(0xFF4CAF50)),
              const SizedBox(height: 12),
              Text('Bem-vindo!', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                identity != null ? identity.username : '—',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              personAsync.when(
                loading: () => const CircularProgressIndicator(strokeWidth: 2),
                error: (e, _) => Text(
                  'WellnessPerson indisponível: $e',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                data: (person) => person == null
                    ? const Text('Bootstrap pendente…')
                    : Column(
                        children: [
                          Text(
                            person.displayName.isEmpty
                                ? 'WellnessPerson ${person.uuid.substring(0, 8)}'
                                : person.displayName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'cognito_sub: ${person.cognitoSub}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 24),
              // Fase 5 (spec §47): valores REAIS do DailyScore — nunca demo.
              latestScoreAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (e, _) => Text(
                  'Scores indisponíveis: $e',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                data: (score) => score == null
                    ? Text(
                        'Nenhum DailyScore ainda.',
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    : _TodayScoresCard(score: score),
              ),
              const SizedBox(height: 16),
              const _ProgressCard(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fase 8 (spec §54): seção pequena "Seu progresso" no Home — streak +
/// conquistas, navega para a tela de gamificação.
class _ProgressCard extends ConsumerWidget {
  const _ProgressCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(gamificationSummaryProvider);
    return summaryAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const SizedBox.shrink(),
      data: (summary) => Card(
        child: ListTile(
          leading: const Icon(Icons.emoji_events_outlined, color: Colors.amber),
          title: Text(
            '🔥 ${summary.currentStreak} ${summary.currentStreak == 1 ? 'dia' : 'dias'} '
            '· ${summary.unlockedCount} conquistas',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          subtitle: const Text('Seu progresso'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/gamification'),
        ),
      ),
    );
  }
}

class _TodayScoresCard extends StatelessWidget {
  const _TodayScoresCard({required this.score});

  final DailyScore score;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <(String, int?)>[
      ('Readiness', score.readiness),
      ('Sleep', score.sleep),
      ('Activity', score.activity),
      ('Strain', score.strain),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Hoje (${score.scoreDate})',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(item.$1, style: theme.textTheme.bodyMedium),
                      Text(
                        item.$2?.toString() ?? '—',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 4),
            Text(
              'formula ${score.formulaVersion} • ${score.computedBy}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
