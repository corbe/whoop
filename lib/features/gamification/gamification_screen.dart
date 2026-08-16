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
        // A MARCAÇÃO (escrita em CelebratedUnlocks) e o diálogo são efeitos
        // pós-montagem: escrever um provider dentro de build() viola o Riverpod
        // ("Tried to modify a provider while the widget tree was building").
        // O read() abaixo é somente leitura; toda mutação roda no callback
        // pós-frame, re-avaliando o conjunto celebrado no momento da execução
        // (idempotente mesmo se o build rodar mais de uma vez no mesmo frame).
        final controller = ref.read(gamificationActionControllerProvider);
        final newly = controller.newlyUnlocked(achievements);
        if (newly.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            final stillNew = controller.newlyUnlocked(achievements);
            if (stillNew.isEmpty) return;
            for (final a in stillNew) {
              controller.markCelebrated(a.code);
            }
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                icon: const Icon(Icons.emoji_events, size: 48,
                    color: Colors.amber),
                title: const Text('Conquista desbloqueada!'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: stillNew
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
        return GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          padding: const EdgeInsets.all(16),
          childAspectRatio: 0.95,
          children: achievements
              .map((a) => _AchievementTile(achievement: a))
              .toList(),
        );
      },
    );
  }
}

/// Tile compacto WHOOP-style: ícone + nome (+ progresso quando bloqueado).
class _AchievementTile extends StatelessWidget {
  const _AchievementTile({required this.achievement});

  final Achievement achievement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unlocked = achievement.unlocked;
    final icon = _iconFor(achievement.iconKey);
    return Container(
      decoration: BoxDecoration(
        color: unlocked
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(8),
      child: Opacity(
        opacity: unlocked ? 1 : 0.5,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: unlocked
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(icon,
                      size: 20,
                      color: unlocked
                          ? Colors.white
                          : theme.colorScheme.onSurfaceVariant),
                ),
                if (!unlocked)
                  const Positioned(
                    right: -4,
                    bottom: -4,
                    child: Icon(Icons.lock_outline,
                        size: 12, color: Colors.black54),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              achievement.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: unlocked ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            if (!unlocked && achievement.target > 1)
              Text(
                '${achievement.progress}/${achievement.target}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
