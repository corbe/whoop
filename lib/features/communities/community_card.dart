/// Community card (Phase 4, spec §29) — avatar, name, member_count,
/// visibility, current role when useful.
library;

import 'package:flutter/material.dart';

import '../../shared/models/community.dart';

class CommunityCard extends StatelessWidget {
  const CommunityCard({super.key, required this.community, this.onTap});

  final Community community;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibilityLabel = switch (community.visibility) {
      'public_code' => 'Acesso por código',
      'private' => 'Privada',
      _ => 'Convite',
    };

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundImage: community.avatarUrl.isNotEmpty
                    ? NetworkImage(community.avatarUrl)
                    : null,
                child: community.avatarUrl.isEmpty
                    ? Text(
                        community.name.isEmpty
                            ? '?'
                            : community.name[0].toUpperCase(),
                        style: theme.textTheme.titleLarge,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      community.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${community.memberCount} membros • $visibilityLabel',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (community.currentUserRole != null &&
                        community.currentUserRole!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'seu papel: ${community.currentUserRole}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
