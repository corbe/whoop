/// Member social profile (Social Phase).
///
/// SOCIAL data only — the backend endpoint never returns physiological data
/// (HR/HRV/sleep/recovery/DailyScore of others). Every section renders only
/// when the backend has real data; nothing is manufactured client-side.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/noana_widgets.dart';
import '../../services/community_providers.dart';
import '../../shared/models/social_profile.dart';

class MemberProfileScreen extends ConsumerWidget {
  const MemberProfileScreen({
    super.key,
    required this.communityUuid,
    required this.personUuid,
  });

  final String communityUuid;
  final String personUuid;

  ({String communityUuid, String personUuid}) get _params =>
      (communityUuid: communityUuid, personUuid: personUuid);

  /// Rótulo de papel — membro comum NÃO tem rótulo (redundante).
  static String? memberRoleLabel(String? role) {
    switch (role) {
      case 'owner':
        return 'Dono';
      case 'admin':
        return 'Administrador';
      default:
        return null;
    }
  }

  String? _formatJoinedAt(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return null;
    final months = [
      'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
      'jul', 'ago', 'set', 'out', 'nov', 'dez',
    ];
    return '${parsed.day} ${months[parsed.month - 1]} ${parsed.year}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(memberSocialProfileProvider(_params));
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: async.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Falha ao carregar perfil: $e',
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(memberSocialProfileProvider(_params)),
                  child: const Text('Tentar novamente'),
                ),
              ],
            ),
          ),
        ),
        data: (profile) => _build(context, profile),
      ),
    );
  }

  Widget _build(BuildContext context, MemberSocialProfile profile) {
    final theme = Theme.of(context);
    final joinedAt = _formatJoinedAt(profile.joinedAt);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── identidade ──
        Center(
          child: CircleAvatar(
            radius: 40,
            backgroundColor: theme.colorScheme.secondaryContainer,
            foregroundImage: profile.avatarUrl.isNotEmpty
                ? NetworkImage(profile.avatarUrl)
                : null,
            child: profile.avatarUrl.isNotEmpty
                ? null
                : Text(
                    profile.displayName.isEmpty
                        ? 'M'
                        : profile.displayName[0].toUpperCase(),
                    style: theme.textTheme.headlineMedium,
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            profile.displayName.isEmpty ? 'Membro' : profile.displayName,
            style: theme.textTheme.titleLarge,
          ),
        ),
        if (MemberProfileScreen.memberRoleLabel(profile.role) != null)
          Center(
            child: Text(
              MemberProfileScreen.memberRoleLabel(profile.role)!,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        // Rank comunitário no header (WHOOP-style hierarquia).
        if (profile.communityRank.rank != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '#${profile.communityRank.rank} '
                '${profile.communityRank.total != null ? 'de ${profile.communityRank.total}' : ''}'
                ' na comunidade',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        const Divider(height: 32),

        // ── stats compactas (só com dados reais) ──
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (profile.streakDays > 0)
              NoanaMetricValue(
                '${profile.streakDays}',
                subtitle: '🔥 ${profile.streakDays} '
                    '${profile.streakDays == 1 ? 'dia' : 'dias'} de streak',
              ),
            if (profile.badges.isNotEmpty)
              NoanaMetricValue('${profile.badges.length}',
                  subtitle: '🏅 conquistas'),
            if (profile.challenges.completed > 0)
              NoanaMetricValue('${profile.challenges.completed}',
                  subtitle: '🎯 desafios'),
          ],
        ),
        const SizedBox(height: 8),

        // ── desafios ──
        const NoanaSectionHeader('DESAFIOS'),
        if (!profile.challenges.isEmpty)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _StatItem(label: 'Ativos', value: '${profile.challenges.active}'),
              _StatItem(
                  label: 'Concluídos', value: '${profile.challenges.completed}'),
              _StatItem(label: 'Vitórias', value: '${profile.challenges.wins}'),
              _StatItem(label: 'Top 3', value: '${profile.challenges.top3}'),
            ],
          )
        else
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Este membro ainda não concluiu desafios.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ),
        const SizedBox(height: 16),

        // ── conquistas ──
        const NoanaSectionHeader('CONQUISTAS'),
        if (profile.badges.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Nenhuma conquista ainda.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: profile.badges
                  .map((b) => Chip(
                        label: Text(b.name),
                        avatar: b.iconKey.isNotEmpty
                            ? null
                            : const Icon(Icons.emoji_events, size: 16),
                      ))
                  .toList(),
            ),
          ),

        if (joinedAt != null) ...[
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Membro desde $joinedAt',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(value,
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.primary)),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
