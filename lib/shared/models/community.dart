/// Community domain models (Phase 4) — mirror the backend serializers.
library;

/// Community (spec §4) — social domain entity; the JuggleIM group is only the
/// realtime messaging projection (spec §47). Source of truth: Noana backend.
class Community {
  const Community({
    required this.uuid,
    required this.name,
    this.description = '',
    this.avatarUrl = '',
    this.visibility = 'invite_only',
    this.joinCode = '',
    this.ownerPersonUuid,
    this.juggleGroupId = '',
    this.chatSyncStatus = 'pending',
    this.chatSyncError = '',
    this.chatSyncedAt,
    this.memberCount = 0,
    this.currentUserRole,
    this.currentUserStatus,
    this.shareScopeJson = const {},
    this.chatSynced = false,
    this.createdAt,
    this.updatedAt,
  });

  final String uuid;
  final String name;
  final String description;
  final String avatarUrl;
  final String visibility;
  final String joinCode;
  final String? ownerPersonUuid;
  final String juggleGroupId;
  final String chatSyncStatus;
  final String chatSyncError;
  final String? chatSyncedAt;
  final int memberCount;
  final String? currentUserRole;
  final String? currentUserStatus;
  final Map<String, dynamic> shareScopeJson;
  final bool chatSynced;
  final String? createdAt;
  final String? updatedAt;

  bool get isPublicCode => visibility == 'public_code';
  bool get isInviteOnly => visibility == 'invite_only';
  bool get isPrivate => visibility == 'private';
  bool get isOwner => currentUserRole == 'owner';
  bool get isAdmin => currentUserRole == 'admin';
  bool get isActiveMember => currentUserStatus == 'active';
  bool get isBanned => currentUserStatus == 'banned';

  /// Deterministic JuggleIM group id (spec §5): `community:<uuid>`.
  String get deterministicGroupId => 'community:$uuid';

  factory Community.fromJson(Map<String, dynamic> json) {
    return Community(
      uuid: json['uuid'] as String,
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      avatarUrl: (json['avatar_url'] as String?) ?? '',
      visibility: (json['visibility'] as String?) ?? 'invite_only',
      joinCode: (json['join_code'] as String?) ?? '',
      ownerPersonUuid: json['owner_person_uuid'] as String?,
      juggleGroupId: (json['juggle_group_id'] as String?) ?? '',
      chatSyncStatus: (json['chat_sync_status'] as String?) ?? 'pending',
      chatSyncError: (json['chat_sync_error'] as String?) ?? '',
      chatSyncedAt: json['chat_synced_at'] as String?,
      memberCount: (json['member_count'] as int?) ?? 0,
      currentUserRole: json['current_user_role'] as String?,
      currentUserStatus: json['current_user_status'] as String?,
      shareScopeJson: (json['share_scope_json'] as Map<String, dynamic>?) ?? const {},
      chatSynced: (json['chat_synced'] as bool?) ?? false,
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }
}

/// CommunityMember (spec §6) — safe social fields only (spec §17).
class CommunityMember {
  const CommunityMember({
    required this.personUuid,
    this.displayName = '',
    this.avatarUrl = '',
    this.role = 'member',
    this.status = 'active',
    this.joinedAt,
  });

  final String personUuid;
  final String displayName;
  final String avatarUrl;
  final String role;
  final String status;
  final String? joinedAt;

  bool get isActive => status == 'active';
  bool get isOwner => role == 'owner';
  bool get isAdmin => role == 'admin';

  factory CommunityMember.fromJson(Map<String, dynamic> json) {
    return CommunityMember(
      personUuid: json['person_uuid'] as String,
      displayName: (json['display_name'] as String?) ?? '',
      avatarUrl: (json['avatar_url'] as String?) ?? '',
      role: (json['role'] as String?) ?? 'member',
      status: (json['status'] as String?) ?? 'active',
      joinedAt: json['joined_at'] as String?,
    );
  }
}

/// Create-community payload (spec §8). The client never sends owner fields.
class CommunityCreateRequest {
  const CommunityCreateRequest({
    required this.name,
    this.description = '',
    this.avatarUrl = '',
    this.visibility = 'invite_only',
    this.joinCode = '',
  });

  final String name;
  final String description;
  final String avatarUrl;
  final String visibility;
  final String joinCode;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'avatar_url': avatarUrl,
        'visibility': visibility,
        'join_code': joinCode,
      };
}
