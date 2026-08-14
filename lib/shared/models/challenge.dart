/// Challenge domain models (Phase 7) — mirror the backend API.
library;

enum ChallengeStatus { draft, upcoming, active, completed, cancelled }

ChallengeStatus challengeStatusFrom(String? value) {
  switch (value) {
    case 'upcoming':
      return ChallengeStatus.upcoming;
    case 'active':
      return ChallengeStatus.active;
    case 'completed':
      return ChallengeStatus.completed;
    case 'cancelled':
      return ChallengeStatus.cancelled;
    default:
      return ChallengeStatus.draft;
  }
}

/// Challenge (spec §4) — metric allowlist + aggregation from backend.
class Challenge {
  const Challenge({
    required this.uuid,
    required this.communityUuid,
    required this.name,
    required this.metric,
    required this.aggregation,
    required this.startDate,
    required this.endDate,
    required this.status,
    this.description = '',
    this.minDays,
    this.maxParticipants,
    this.participantCount = 0,
    this.currentUserStatus,
    this.currentUserProgress,
    this.finalizedAt,
  });

  final String uuid;
  final String communityUuid;
  final String name;
  final String description;
  final String metric;
  final String aggregation;
  final String startDate;
  final String endDate;
  final ChallengeStatus status;
  final int? minDays;
  final int? maxParticipants;
  final int participantCount;
  final String? currentUserStatus;
  final ChallengeProgress? currentUserProgress;
  final DateTime? finalizedAt;

  factory Challenge.fromJson(Map<String, dynamic> json) {
    return Challenge(
      uuid: json['uuid'] as String,
      communityUuid: json['community_uuid'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      metric: json['metric'] as String,
      aggregation: json['aggregation'] as String,
      startDate: json['start_date'] as String,
      endDate: json['end_date'] as String,
      status: challengeStatusFrom(json['status'] as String?),
      minDays: json['min_days'] as int?,
      maxParticipants: json['max_participants'] as int?,
      participantCount: (json['participant_count'] as int?) ?? 0,
      currentUserStatus: json['current_user_status'] as String?,
      currentUserProgress: json['current_user_progress'] == null
          ? null
          : ChallengeProgress.fromJson(
              json['current_user_progress'] as Map<String, dynamic>),
      finalizedAt: json['finalized_at'] == null
          ? null
          : DateTime.tryParse(json['finalized_at'] as String),
    );
  }
}

/// ChallengeProgress (spec §22–§23, §28–§31).
class ChallengeProgress {
  const ChallengeProgress({
    required this.participantStatus,
    this.score,
    required this.daysCount,
    required this.qualified,
    this.rank,
  });

  final String participantStatus;
  final double? score;
  final int daysCount;
  final bool qualified;
  final int? rank;

  factory ChallengeProgress.fromJson(Map<String, dynamic> json) {
    return ChallengeProgress(
      participantStatus: json['participant_status'] as String? ?? 'active',
      score: (json['score'] as num?)?.toDouble(),
      daysCount: (json['days_count'] as int?) ?? 0,
      qualified: (json['qualified'] as bool?) ?? false,
      rank: json['rank'] as int?,
    );
  }
}

/// ChallengeRanking (spec §33).
class ChallengeRanking {
  const ChallengeRanking({
    required this.challengeUuid,
    required this.status,
    required this.metric,
    required this.aggregation,
    required this.startDate,
    required this.endDate,
    required this.totalParticipants,
    required this.entries,
    this.currentUserPosition,
  });

  final String challengeUuid;
  final ChallengeStatus status;
  final String metric;
  final String aggregation;
  final String startDate;
  final String endDate;
  final int totalParticipants;
  final List<ChallengeRankingEntry> entries;
  final int? currentUserPosition;

  factory ChallengeRanking.fromJson(Map<String, dynamic> json) {
    return ChallengeRanking(
      challengeUuid: json['challenge_uuid'] as String,
      status: challengeStatusFrom(json['status'] as String?),
      metric: json['metric'] as String,
      aggregation: json['aggregation'] as String,
      startDate: json['start_date'] as String,
      endDate: json['end_date'] as String,
      totalParticipants: (json['total_participants'] as int?) ?? 0,
      entries: ((json['entries'] as List?) ?? const [])
          .map((e) => ChallengeRankingEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      currentUserPosition: json['current_user_position'] as int?,
    );
  }
}

/// ChallengeRankingEntry — safe social identity + metric result only
/// (spec §24, §90).
class ChallengeRankingEntry {
  const ChallengeRankingEntry({
    this.position,
    required this.personUuid,
    required this.displayName,
    required this.avatarUrl,
    required this.score,
    required this.daysCount,
    required this.qualified,
  });

  final int? position;
  final String personUuid;
  final String displayName;
  final String avatarUrl;
  final double score;
  final int daysCount;
  final bool qualified;

  factory ChallengeRankingEntry.fromJson(Map<String, dynamic> json) {
    return ChallengeRankingEntry(
      position: json['position'] as int?,
      personUuid: json['person_uuid'] as String,
      displayName: json['display_name'] as String,
      avatarUrl: (json['avatar_url'] as String?) ?? '',
      score: (json['score'] as num).toDouble(),
      daysCount: (json['days_count'] as int?) ?? 0,
      qualified: (json['qualified'] as bool?) ?? true,
    );
  }
}

/// Create request (spec §11/§50) — metric/aggregation from allowlist.
class ChallengeCreateRequest {
  const ChallengeCreateRequest({
    required this.name,
    required this.metric,
    required this.aggregation,
    required this.startDate,
    required this.endDate,
    this.description = '',
    this.minDays,
  });

  final String name;
  final String metric;
  final String aggregation;
  final String startDate;
  final String endDate;
  final String description;
  final int? minDays;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'metric': metric,
        'aggregation': aggregation,
        'start_date': startDate,
        'end_date': endDate,
        if (minDays != null) 'min_days': minDays,
      };
}

/// Supported metrics/aggregations (spec §6, §8) — mirrors backend allowlist.
const challengeMetrics = ['readiness', 'sleep', 'activity', 'strain'];
const challengeAggregations = ['average', 'best', 'days_recorded'];
