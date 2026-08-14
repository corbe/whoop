/// Gamification screen (Phase 8, spec §48–§52).
///
/// Progress header (streak, points, level), achievement cards with progress
/// (never fake values, spec §49), and a lightweight one-time unlock
/// celebration (dedup per session, spec §52).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/gamification_providers.dart';
import '../../shared/models/gamification.dart';

IconData _iconFor(String iconKey) {
  switch (iconKey) {
    case 'first_score':
      return Icons.edit_calendar_outlined;
    case 'seven_days':
      return Icons.calendar_view_week_outlined;
    case 'thirty_days':
      return Icons.calendar_month_outlined;
    case 'first_community':
      return Icons.people_outline;
    case 'community_3':
      return Icons.groups_outlined;
    case 'first_challenge':
      return Icons.emoji_events_outlined;
    case 'challenge_completed':
      return Icons.flag_outlined;
    case 'challenge_3':
      return Icons.emoji_events;
    case 'top_three':
      return Icons.military_tech_outlined;
    case 'streak_7':
    case 'streak_30':
      return Icons.local_fire_department_outlined;
    default:
      return Icons.stars_outlined;
  }
}

class GamificationScreen extends ConsumerStatefulWidget {
  const GamificationScreen({super.key});

  @override
  ConsumerState<GamificationScreen> createState() => _GamificationScreenState();
}

class _GamificationScreenState extends ConsumerState<GamificationScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Seu progresso')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(achievementsProvider);
          ref.invalidate(gamificationSummaryProvider);
          ref.invalidate(streakProvider);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SummaryHeader(),
            const Divider(height: 24),
            Text('Conquistas', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const _AchievementsList(),
          ],
        ),
      ),
    );
  }
}

class _SummaryHeader extends ConsumerWidget {
  const _SummaryHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(gamificationSummaryProvider);
    return summaryAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Falha ao carregar progresso: $e'),
        ),
      ),
      data: (summary) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Nível ${summary.level}',
                        style: Theme.of(context).textTheme.titleMedium),
                    Text('${summary.points} pontos',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.local_fire_department,
                        color: Colors.deepOrange),
                    const SizedBox(width: 6),
                    Text(
                      '${summary.currentStreak} ${summary.currentStreak == 1 ? 'dia' : 'dias'} consecutivos',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
                Text(
                  'Melhor: ${summary.bestStreak} dias',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Dias consecutivos com um wellness score registrado',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.secondary),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: summary.totalCount == 0
                      ? 0
                      : summary.unlockedCount / summary.totalCount,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 4),
                Text(
                  '${summary.unlockedCount} / ${summary.totalCount} conquistas',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AchievementsList extends ConsumerWidget {
  const _AchievementsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final achievementsAsync = ref.watch(achievementsProvider);
    return achievementsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Text('Falha ao carregar conquistas: $e'),
      data: (achievements) {
        // Unlock UX dedup (spec §52): celebra apenas os novos da sessão.
        final controller = ref.read(gamificationActionControllerProvider);
        final newly = controller.newlyUnlocked(achievements);
        for (final a in newly) {
          controller.markCelebrated(a.code);
        }
        if (newly.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                icon: const Icon(Icons.emoji_events, size: 48,
                    color: Colors.amber),
                title: const Text('Conquista desbloqueada!'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: newly
                      .map((a) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text('${_iconFor(a.iconKey) == Icons.emoji_events ? "🏆" : "⭐"} ${a.name}',
                                textAlign: TextAlign.center),
                          ))
                      .toList(),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Legal!'),
                  ),
                ],
              ),
            );
          });
        }
        return Column(
          children: achievements
              .map((a) => _AchievementCard(achievement: a))
              .toList(),
        );
      },
    );
  }
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard({required this.achievement});

  final Achievement achievement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unlocked = achievement.unlocked;
    final icon = _iconFor(achievement.iconKey);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: unlocked ? theme.colorScheme.primaryContainer : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: unlocked
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(icon,
              color: unlocked ? Colors.white : theme.colorScheme.secondary),
        ),
        title: Text(achievement.name,
            style: TextStyle(
                fontWeight: unlocked ? FontWeight.bold : FontWeight.normal)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(achievement.description,
                style: theme.textTheme.bodySmall),
            if (!unlocked)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: achievement.target == 0
                            ? 0
                            : achievement.progress / achievement.target,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${achievement.progress} / ${achievement.target}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              )
            else if (achievement.unlockedAt != null)
              Text(
                'Desbloqueado ${_formatDate(achievement.unlockedAt!)}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = [
      'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
      'jul', 'ago', 'set', 'out', 'nov', 'dez'
    ][local.month - 1];
    return '$day $month ${local.year}';
  }
}
