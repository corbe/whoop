/// Community detail (Phase 4, spec §31–§34).
///
/// Tabs: Overview / Members / Chat. No Rankings/Scores yet (later phase).
/// Chat is only shown to active members (backend also enforces access).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/community_providers.dart';
import '../../services/score_providers.dart';
import '../../shared/models/community.dart';
import 'challenges_tab.dart';
import 'community_chat_screen.dart';
import 'leaderboard_tab.dart';
import 'notification_settings_screen.dart';
import 'privacy_screen.dart';

class CommunityDetailScreen extends ConsumerStatefulWidget {
  const CommunityDetailScreen({super.key, required this.uuid});

  final String uuid;

  @override
  ConsumerState<CommunityDetailScreen> createState() =>
      _CommunityDetailScreenState();
}

class _CommunityDetailScreenState extends ConsumerState<CommunityDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _openPrivacy(Community community) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrivacyScreen(
          communityUuid: community.uuid,
          communityName: community.name,
        ),
        settings: RouteSettings(arguments: community.shareScopeJson),
      ),
    ).then((_) {
      if (mounted) {
        ref.invalidate(communityDetailProvider(community.uuid));
        ref.invalidate(communityRankingProvider);
      }
    });
  }

  bool _isOwnerOrAdmin(Community community) {
    final role = community.currentUserRole;
    return role == 'owner' || role == 'admin';
  }

  @override
  Widget build(BuildContext context) {
    final communityAsync = ref.watch(communityDetailProvider(widget.uuid));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Comunidade'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Visão geral'),
            Tab(text: 'Leaderboard'),
            Tab(text: 'Desafios'),
            Tab(text: 'Membros'),
            Tab(text: 'Chat'),
          ],
        ),
      ),
      body: communityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(child: Text('Falha: $e')),
        data: (community) => TabBarView(
          controller: _tabController,
          children: [
            _OverviewTab(community: community, onOpenPrivacy: () => _openPrivacy(community)),
            LeaderboardTab(communityUuid: widget.uuid),
            ChallengesTab(
              communityUuid: widget.uuid,
              communityName: community.name,
              isOwnerOrAdmin: _isOwnerOrAdmin(community),
            ),
            _MembersTab(uuid: widget.uuid, community: community),
            _ChatTab(community: community),
          ],
        ),
      ),
    );
  }
}

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab({required this.community, required this.onOpenPrivacy});

  final Community community;
  final VoidCallback onOpenPrivacy;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final visibilityLabel = switch (community.visibility) {
      'public_code' => 'Código público',
      'private' => 'Privada',
      _ => 'Somente convite',
    };
    final isMember = community.isActiveMember;
    final isOwner = community.isOwner;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: CircleAvatar(
            radius: 40,
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundImage: community.avatarUrl.isNotEmpty
                ? NetworkImage(community.avatarUrl)
                : null,
            child: community.avatarUrl.isEmpty
                ? Text(
                    community.name.isEmpty
                        ? '?'
                        : community.name[0].toUpperCase(),
                    style: theme.textTheme.displaySmall,
                  )
                : null,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          community.name,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          '${community.memberCount} membros • $visibilityLabel',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        if (isOwner)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Você é o owner',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        const Divider(height: 32),
        if (community.description.isNotEmpty) ...[
          Text('Descrição', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(community.description),
          const Divider(height: 32),
        ],
        if (community.visibility == 'public_code' && community.joinCode.isNotEmpty) ...[
          Text('Código de entrada', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(community.joinCode),
          const Divider(height: 32),
        ],
        if (!community.chatSynced)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Chat ainda não sincronizado (${community.chatSyncStatus}). '
                'A reconciliação corrige automaticamente.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        const SizedBox(height: 16),
        if (isMember)
          OutlinedButton.icon(
            onPressed: () async {
              try {
                await ref
                    .read(communityActionControllerProvider)
                    .leave(community.uuid);
                if (context.mounted) context.go('/communities');
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Falha ao sair: $e')),
                  );
                }
              }
            },
            icon: const Icon(Icons.logout),
            label: const Text('Sair da comunidade'),
          )
        else
          FilledButton.icon(
            onPressed: community.isBanned
                ? null
                : () => _join(context, ref),
            icon: const Icon(Icons.group_add),
            label: Text(community.isBanned ? 'Banido' : 'Entrar'),
          ),
        if (isMember) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onOpenPrivacy,
            icon: const Icon(Icons.shield_outlined),
            label: const Text('Privacidade / Compartilhamento'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => NotificationSettingsScreen(
                  communityUuid: community.uuid,
                  communityName: community.name,
                ),
              ),
            ),
            icon: const Icon(Icons.notifications_outlined),
            label: const Text('Notificações'),
          ),
        ],
      ],
    );
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    try {
      final result = await ref
          .read(communityActionControllerProvider)
          .join(community.uuid, joinCode: null);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.message)));
      // Refresh detail so tabs update.
      ref.invalidate(communityDetailProvider(community.uuid));
    } catch (e) {
      if (!context.mounted) return;
      _promptJoinCode(context, ref, e);
    }
  }

  Future<void> _promptJoinCode(
      BuildContext context, WidgetRef ref, Object error) async {
    if (community.visibility != 'public_code') {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Falha ao entrar: $error')));
      return;
    }
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Código de entrada'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Informe o código da comunidade',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Entrar'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    try {
      await ref
          .read(communityActionControllerProvider)
          .join(community.uuid, joinCode: code);
      if (context.mounted) {
        ref.invalidate(communityDetailProvider(community.uuid));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Falha ao entrar: $e')));
      }
    }
  }
}

class _MembersTab extends ConsumerWidget {
  const _MembersTab({required this.uuid, required this.community});

  final String uuid;
  final Community community;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membersAsync = ref.watch(communityMembersProvider(uuid));
    return membersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(child: Text('Falha: $e')),
      data: (members) {
        if (members.isEmpty) {
          return const Center(child: Text('Nenhum membro.'));
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(communityMembersProvider(uuid)),
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: members.length,
            itemBuilder: (context, i) {
              final member = members[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                  foregroundImage: member.avatarUrl.isNotEmpty
                      ? NetworkImage(member.avatarUrl)
                      : null,
                  child: member.avatarUrl.isEmpty
                      ? Text(_initial(member.displayName))
                      : null,
                ),
                title: Text(member.displayName.isEmpty
                    ? member.personUuid.substring(0, 8)
                    : member.displayName),
                subtitle: Text('${member.role} • ${member.status}'),
                trailing: community.isOwner && member.personUuid != community.ownerPersonUuid
                    ? _memberActions(context, ref, member)
                    : null,
              );
            },
          ),
        );
      },
    );
  }

  Widget _memberActions(BuildContext context, WidgetRef ref, CommunityMember member) {
    return PopupMenuButton<String>(
      onSelected: (action) async {
        try {
          final controller = ref.read(communityActionControllerProvider);
          switch (action) {
            case 'ban':
              await controller.ban(uuid, member.personUuid);
            case 'unban':
              await controller.unban(uuid, member.personUuid);
            case 'admin':
              await controller.updateRole(uuid, member.personUuid, 'admin');
            case 'member':
              await controller.updateRole(uuid, member.personUuid, 'member');
          }
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Atualizado.')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Falha: $e')),
            );
          }
        }
      },
      itemBuilder: (context) => [
        if (member.isActive && !member.isOwner)
          const PopupMenuItem(value: 'ban', child: Text('Banir')),
        if (member.status == 'banned')
          const PopupMenuItem(value: 'unban', child: Text('Desbanir')),
        if (member.isActive && member.role == 'member')
          const PopupMenuItem(value: 'admin', child: Text('Tornar admin')),
        if (member.isActive && member.role == 'admin')
          const PopupMenuItem(value: 'member', child: Text('Rebaixar p/ membro')),
      ],
    );
  }

  String _initial(String name) {
    if (name.isEmpty) return '?';
    return name[0].toUpperCase();
  }
}

class _ChatTab extends ConsumerWidget {
  const _ChatTab({required this.community});

  final Community community;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!community.isActiveMember) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Entre na comunidade para acessar o chat.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final groupId = community.juggleGroupId.isNotEmpty
        ? community.juggleGroupId
        : community.deterministicGroupId;
    return CommunityChatScreen(
      communityName: community.name,
      groupId: groupId,
    );
  }
}
