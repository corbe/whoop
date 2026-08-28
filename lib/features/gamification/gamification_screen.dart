/// Gamification screen (Phase 8, spec §48–§52).
///
/// Progress header (streak, points, level), achievement cards with progress
/// (never fake values, spec §49), and a lightweight one-time unlock
/// celebration (dedup per session, spec §52).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/noana_widgets.dart';

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
    case 'madrugador':
      return Icons.wb_sunny_outlined;
    case 'consistente':
      return Icons.verified_outlined;
    case 'explorador':
      return Icons.explore_outlined;
    case 'recuperado':
      return Icons.self_improvement_outlined;
    case 'maratonista':
      return Icons.directions_run_outlined;
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
            const RitmaContentShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SummaryHeader(),
                  Divider(height: 24),
                  Text('CONQUISTAS', style: TextStyle(fontSize: 16)),
                  SizedBox(height: 8),
                  _AchievementsList(),
                ],
              ),
            ),
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
    final theme = Theme.of(context);
    final summaryAsync = ref.watch(gamificationSummaryProvider);
    return summaryAsync.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Falha ao carregar progresso: $e'),
        ),
      ),
      data: (summary) {
        // DATA >> CONTAINER: métricas dominam, sem card gigante vazio.
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Nível + pontos (Fase 4: progressão estruturada)
              _LevelHeader(summary: summary),
              const SizedBox(height: 20),
              // Fase 1 — card "pontos de hoje" (consistência fisiológica).
              if (summary.dailyPoints != null)
                _DailyPointsCard(summary: summary.dailyPoints!),
              const SizedBox(height: 20),
              // Streak: o ZERO é a métrica
              Center(
                child: Column(
                  children: [
                    Text(
                      '${summary.currentStreak}',
                      style: theme.textTheme.displayLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      'DIAS CONSECUTIVOS',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Melhor: ${summary.bestStreak} dias',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Progresso das conquistas: trilha neutra + barra verde real
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: summary.totalCount == 0
                      ? 0
                      : summary.unlockedCount / summary.totalCount,
                  minHeight: 8,
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${summary.unlockedCount} / ${summary.totalCount} conquistas',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LevelHeader extends StatelessWidget {
  const _LevelHeader({required this.summary});

  final GamificationSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = summary.levelProgress;
    final points = summary.points;

    // Resposta antiga (sem levelProgress): fallback para o header simples.
    if (progress == null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'NÍVEL ${summary.level}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          Text(
            '$points PTS',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      );
    }

    // Barra SEMPRE entre 0 e 100 (clamp); nunca NaN/negativo.
    final percent = progress.percent.clamp(0.0, 100.0);
    final isMax = progress.isMaxLevel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                isMax
                    ? 'NÍVEL MÁXIMO · ${progress.currentName}'
                    : progress.currentName,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Text(
              '$points PTS',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent / 100,
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          isMax
              ? 'Você alcançou o nível mais alto — continue somando pontos!'
              : '${progress.pointsToNext ?? 0} pts para '
                    '${progress.nextName ?? 'o próximo nível'} '
                    '(${progress.nextThreshold ?? 0} pts)',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DailyPointsCard extends StatelessWidget {
  const _DailyPointsCard({required this.summary});

  final DailyPointsSummary summary;

  static const Map<String, String> _ruleLabels = {
    'day_completed': 'Dia completo',
    'rings_closed': '3 anéis fechados',
    'data_streak_7': 'Série de 7 dias',
    'activity_zone': 'Atividade na meta',
    'sleep_zone': 'Sono na meta',
    'strain_recorded': 'Strain registrado',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = summary.breakdown.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'PONTOS DE HOJE',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                '${summary.todayTotal} pts',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (rules.isEmpty)
            Text(
              'Registre scores hoje para ganhar pontos de consistência.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final rule in rules)
                  _PointsChip(
                    label:
                        '${_ruleLabels[rule.key] ?? rule.key} +${rule.value}',
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            'Total acumulado: ${summary.total} pts',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PointsChip extends StatelessWidget {
  const _PointsChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.stars_outlined,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _AchievementsList extends ConsumerWidget {
  const _AchievementsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final achievementsAsync = ref.watch(achievementsProvider);
    return achievementsAsync.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
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
                icon: const Icon(
                  Icons.emoji_events,
                  size: 48,
                  color: Colors.amber,
                ),
                title: const Text('Conquista desbloqueada!'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: stillNew
                      .map(
                        (a) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '${_iconFor(a.iconKey) == Icons.emoji_events ? "🏆" : "⭐"} ${a.name}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
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
        // Grade de conquistas: tiles de dimensão INTENCIONAL (nunca esticam
        // para preencher a viewport) — max 480px de coluna => tile ~160px.
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              padding: const EdgeInsets.all(16),
              childAspectRatio: 0.85,
              children: achievements
                  .map((a) => _AchievementTile(achievement: a))
                  .toList(),
            ),
          ),
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
      padding: const EdgeInsets.all(10),
      child: Opacity(
        opacity: unlocked ? 1 : 0.5,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: unlocked
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    icon,
                    size: 24,
                    color: unlocked
                        ? Colors.white
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (!unlocked)
                  const Positioned(
                    right: -4,
                    bottom: -4,
                    child: Icon(
                      Icons.lock_outline,
                      size: 12,
                      color: Colors.black54,
                    ),
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
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
