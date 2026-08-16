/// Member social profile (Social Phase).
///
/// SOCIAL data only — the backend endpoint never returns physiological data
/// (HR/HRV/sleep/recovery/DailyScore of others). Every section renders only
/// when the backend has real data; nothing is manufactured client-side.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        const Divider(height: 32),

        // ── rank comunitário ──
        if (profile.communityRank.rank != null) ...[
          _StatCard(
            icon: '🏆',
            title: 'Comunidade',
            value: '#${profile.communityRank.rank}',
            detail: profile.communityRank.total != null
                ? 'de ${profile.communityRank.total}'
                : null,
          ),
          const SizedBox(height: 12),
        ],

        // ── streak ──
        if (profile.streakDays > 0) ...[
          _StatCard(
            icon: '🔥',
            title: 'Streak',
            value: '${profile.streakDays} ${profile.streakDays == 1 ? 'dia' : 'dias'}',
          ),
          const SizedBox(height: 12),
        ],

        // ── desafios ──
        if (!profile.challenges.isEmpty) ...[
          _StatCard(
            icon: '🎯',
            title: 'Desafios',
            value: '',
            detail: '',
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatItem(label: 'Ativos', value: '${profile.challenges.active}'),
                _StatItem(
                    label: 'Concluídos', value: '${profile.challenges.completed}'),
                _StatItem(label: 'Vitórias', value: '${profile.challenges.wins}'),
                _StatItem(label: 'Top 3', value: '${profile.challenges.top3}'),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          const Text(
            'Este membro ainda não concluiu desafios.',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 12),
        ],

        // ── conquistas ──
        Text('🏅 Conquistas', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (profile.badges.isEmpty)
          const Text(
            'Nenhuma conquista ainda.',
            style: TextStyle(fontStyle: FontStyle.italic),
          )
        else
          Wrap(
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

        if (joinedAt != null) ...[
          const Divider(height: 32),
          Text(
            'Membro desde $joinedAt',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.title,
    required this.value,
    this.detail,
    this.child,
  });

  final String icon;
  final String title;
  final String value;
  final String? detail;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(icon, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                if (value.isNotEmpty)
                  Text(
                    value,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(color: theme.colorScheme.primary),
                  )
                else if (detail != null)
                  Text(detail!, style: theme.textTheme.bodySmall),
              ],
            ),
            if (detail != null && value.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(detail!, style: theme.textTheme.bodySmall),
            ],
            if (child != null) ...[
              const SizedBox(height: 12),
              child!,
            ],
          ],
        ),
      ),
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
