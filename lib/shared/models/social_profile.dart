/// Member social profile (Social Phase) — mirrors the backend
/// `social-profile/` endpoint. SOCIAL data only: identity, community rank,
/// challenge stats, badges, streak. NEVER physiological data.
library;

class CommunityRankInfo {
  const CommunityRankInfo({
    this.rank,
    this.total,
    this.metric = '',
    this.period = '',
  });

  final int? rank;
  final int? total;
  final String metric;
  final String period;

  factory CommunityRankInfo.fromJson(Map<String, dynamic> json) {
    return CommunityRankInfo(
      rank: json['rank'] as int?,
      total: json['total'] as int?,
      metric: (json['metric'] as String?) ?? '',
      period: (json['period'] as String?) ?? '',
    );
  }
}

class ChallengeStats {
  const ChallengeStats({
    this.active = 0,
    this.completed = 0,
    this.wins = 0,
    this.top3 = 0,
  });

  final int active;
  final int completed;
  final int wins;
  final int top3;

  bool get isEmpty => active == 0 && completed == 0 && wins == 0 && top3 == 0;

  factory ChallengeStats.fromJson(Map<String, dynamic> json) {
    return ChallengeStats(
      active: (json['active'] as int?) ?? 0,
      completed: (json['completed'] as int?) ?? 0,
      wins: (json['wins'] as int?) ?? 0,
      top3: (json['top_3'] as int?) ?? 0,
    );
  }
}

class SocialBadge {
  const SocialBadge({required this.code, required this.name, this.iconKey = ''});

  final String code;
  final String name;
  final String iconKey;

  factory SocialBadge.fromJson(Map<String, dynamic> json) {
    return SocialBadge(
      code: (json['code'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      iconKey: (json['icon_key'] as String?) ?? '',
    );
  }
}

class MemberSocialProfile {
  const MemberSocialProfile({
    required this.personUuid,
    this.displayName = '',
    this.avatarUrl = '',
    this.role,
    this.status,
    this.joinedAt,
    this.communityRank = const CommunityRankInfo(),
    this.challenges = const ChallengeStats(),
    this.badges = const [],
    this.streakDays = 0,
  });

  final String personUuid;
  final String displayName;
  final String avatarUrl;
  final String? role;
  final String? status;
  final String? joinedAt; // ISO datetime
  final CommunityRankInfo communityRank;
  final ChallengeStats challenges;
  final List<SocialBadge> badges;
  final int streakDays;

  factory MemberSocialProfile.fromJson(Map<String, dynamic> json) {
    return MemberSocialProfile(
      personUuid: (json['person_uuid'] as String?) ?? '',
      displayName: (json['display_name'] as String?) ?? '',
      avatarUrl: (json['avatar_url'] as String?) ?? '',
      role: json['role'] as String?,
      status: json['status'] as String?,
      joinedAt: json['joined_at'] as String?,
      communityRank: CommunityRankInfo.fromJson(
          (json['community_rank'] as Map<String, dynamic>?) ?? const {}),
      challenges: ChallengeStats.fromJson(
          (json['challenges'] as Map<String, dynamic>?) ?? const {}),
      badges: ((json['badges'] as List?) ?? const [])
          .map((e) => SocialBadge.fromJson(e as Map<String, dynamic>))
          .toList(),
      streakDays: (json['streak_days'] as int?) ?? 0,
    );
  }
}
