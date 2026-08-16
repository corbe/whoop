/// Noana visual system (WHOOP-like density + Noana brand).
///
/// Small set of reusable widgets + spacing/radius tokens so screens share a
/// consistent hierarchy: compact rows, strong values, subtle dividers,
/// minimal borders. Colors always from ColorScheme (light + dark).
library;

import 'package:flutter/material.dart';

/// Spacing tokens — 4/8/12/16/24/32. Never random values.
abstract final class NoanaSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Radius tokens — small 8 / medium 12 / large 16.
abstract final class NoanaRadius {
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
}

/// Section header: compact semibold label with a hairline divider.
class NoanaSectionHeader extends StatelessWidget {
  const NoanaSectionHeader(this.title, {super.key, this.padding});

  final String title;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Big primary value (WHOOP-like metric emphasis).
class NoanaMetricValue extends StatelessWidget {
  const NoanaMetricValue(this.value, {super.key, this.subtitle});

  final String value;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
        ),
        if (subtitle != null)
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

/// Empty state: restrained icon + message.
class NoanaEmptyState extends StatelessWidget {
  const NoanaEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rank row: position/medal + avatar + name + trailing value — the unit used
/// by the leaderboard and challenge ranking. One surface, no per-row cards.
class NoanaRankRow extends StatelessWidget {
  const NoanaRankRow({
    super.key,
    required this.position,
    required this.name,
    required this.value,
    this.avatarUrl = '',
    this.subtitle,
    this.highlight = false,
    this.onTap,
  });

  final int position;
  final String name;
  final String value;
  final String avatarUrl;
  final String? subtitle;
  final bool highlight;
  final VoidCallback? onTap;

  static String medal(int position) => switch (position) {
        1 => '🥇',
        2 => '🥈',
        3 => '🥉',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = medal(position);
    return ListTile(
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 30,
            child: Text(
              m.isNotEmpty ? m : (position <= 0 ? '–' : '#$position'),
              textAlign: TextAlign.center,
              style: m.isNotEmpty
                  ? const TextStyle(fontSize: 18)
                  : theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.secondaryContainer,
            foregroundImage:
                avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
            child: avatarUrl.isEmpty
                ? Text(name.isEmpty ? '?' : name[0].toUpperCase())
                : null,
          ),
        ],
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
      trailing: Text(
        value,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: highlight ? theme.colorScheme.primary : null,
        ),
      ),
      tileColor: highlight
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      onTap: onTap,
    );
  }
}

/// Compact WHOOP-team-style community row (Minhas / Descobrir).
/// One surface, hairline divider, no giant cards.
class NoanaCommunityRow extends StatelessWidget {
  const NoanaCommunityRow({
    super.key,
    required this.name,
    required this.memberCount,
    this.avatarUrl = '',
    this.subtitle,
    this.extra,
    this.trailing,
    this.onTap,
  });

  final String name;
  final int memberCount;
  final String avatarUrl;
  final String? subtitle;
  final String? extra;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final members = '$memberCount ${memberCount == 1 ? 'membro' : 'membros'}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NoanaRadius.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: theme.colorScheme.secondaryContainer,
              foregroundImage: avatarUrl.isNotEmpty
                  ? NetworkImage(avatarUrl)
                  : null,
              child: avatarUrl.isEmpty
                  ? Text(name.isEmpty ? '?' : name[0].toUpperCase())
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      members,
                      if (subtitle != null && subtitle!.isNotEmpty)
                        subtitle!,
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (extra != null && extra!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      extra!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (trailing != null)
              trailing!
            else
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.outline,
              ),
          ],
        ),
      ),
    );
  }
}
