/// Score domain models (Phase 5) — mirror the backend serializers.
library;

/// DailyScore (spec §4) — private wellness score record. Score fields are
/// nullable (no authoritative formula exists yet — see SCORE_AUDIT.md).
class DailyScore {
  const DailyScore({
    required this.uuid,
    required this.personUuid,
    required this.scoreDate,
    this.sleep,
    this.readiness,
    this.stressTrend,
    this.stressInstant,
    this.activity,
    this.strain,
    this.strainTargetPct,
    this.physicalCapacity,
    this.formulaVersion = '',
    this.computedBy = 'client',
    this.sourceDeviceId = '',
    this.computedAt,
    this.receivedAt,
  });

  final String uuid;
  final String personUuid;
  final String scoreDate; // YYYY-MM-DD (wellness day, user timezone)
  final int? sleep;
  final int? readiness;
  final int? stressTrend;
  final int? stressInstant;
  final int? activity;
  final int? strain;
  final int? strainTargetPct;
  final int? physicalCapacity;
  final String formulaVersion;
  final String computedBy;
  final String sourceDeviceId;
  final String? computedAt;
  final String? receivedAt;

  factory DailyScore.fromJson(Map<String, dynamic> json) {
    return DailyScore(
      uuid: json['uuid'] as String,
      personUuid: json['person_uuid'] as String,
      scoreDate: json['score_date'] as String,
      sleep: json['sleep'] as int?,
      readiness: json['readiness'] as int?,
      stressTrend: json['stress_trend'] as int?,
      stressInstant: json['stress_instant'] as int?,
      activity: json['activity'] as int?,
      strain: json['strain'] as int?,
      strainTargetPct: json['strain_target_pct'] as int?,
      physicalCapacity: json['physical_capacity'] as int?,
      formulaVersion: (json['formula_version'] as String?) ?? '',
      computedBy: (json['computed_by'] as String?) ?? 'client',
      sourceDeviceId: (json['source_device_id'] as String?) ?? '',
      computedAt: json['computed_at'] as String?,
      receivedAt: json['received_at'] as String?,
    );
  }
}

/// Upload payload for PUT /wellness/scores/daily/{date}/ (spec §8).
class DailyScoreUpload {
  const DailyScoreUpload({
    this.sleep,
    this.readiness,
    this.stressTrend,
    this.stressInstant,
    this.activity,
    this.strain,
    this.strainTargetPct,
    this.physicalCapacity,
    required this.formulaVersion,
    this.computedBy = 'client',
    this.sourceDeviceId = '',
  });

  final int? sleep;
  final int? readiness;
  final int? stressTrend;
  final int? stressInstant;
  final int? activity;
  final int? strain;
  final int? strainTargetPct;
  final int? physicalCapacity;
  final String formulaVersion;
  final String computedBy;
  final String sourceDeviceId;

  Map<String, dynamic> toJson() => {
        if (sleep != null) 'sleep': sleep,
        if (readiness != null) 'readiness': readiness,
        if (stressTrend != null) 'stress_trend': stressTrend,
        if (stressInstant != null) 'stress_instant': stressInstant,
        if (activity != null) 'activity': activity,
        if (strain != null) 'strain': strain,
        if (strainTargetPct != null) 'strain_target_pct': strainTargetPct,
        if (physicalCapacity != null) 'physical_capacity': physicalCapacity,
        'formula_version': formulaVersion,
        'computed_by': computedBy,
        'source_device_id': sourceDeviceId,
      };
}

/// Ranking entry (spec §29) — safe social fields only.
class CommunityRankingEntry {
  const CommunityRankingEntry({
    required this.position,
    required this.personUuid,
    required this.displayName,
    required this.avatarUrl,
    required this.score,
    required this.daysCount,
  });

  final int position;
  final String personUuid;
  final String displayName;
  final String avatarUrl;
  final double score;
  final int daysCount;

  factory CommunityRankingEntry.fromJson(Map<String, dynamic> json) {
    return CommunityRankingEntry(
      position: json['position'] as int,
      personUuid: json['person_uuid'] as String,
      displayName: (json['display_name'] as String?) ?? '',
      avatarUrl: (json['avatar_url'] as String?) ?? '',
      score: (json['score'] as num).toDouble(),
      daysCount: (json['days_count'] as int?) ?? 0,
    );
  }
}

/// Community ranking response (spec §29–§31).
class CommunityRanking {
  const CommunityRanking({
    required this.communityUuid,
    required this.metric,
    required this.period,
    required this.periodStart,
    required this.periodEnd,
    required this.totalMembers,
    required this.page,
    required this.pageSize,
    this.currentUserPosition,
    required this.entries,
  });

  final String communityUuid;
  final String metric;
  final String period;
  final String periodStart;
  final String periodEnd;
  final int totalMembers;
  final int page;
  final int pageSize;
  final int? currentUserPosition;
  final List<CommunityRankingEntry> entries;

  factory CommunityRanking.fromJson(Map<String, dynamic> json) {
    return CommunityRanking(
      communityUuid: json['community_uuid'] as String,
      metric: json['metric'] as String,
      period: json['period'] as String,
      periodStart: json['period_start'] as String,
      periodEnd: json['period_end'] as String,
      totalMembers: (json['total_members'] as int?) ?? 0,
      page: (json['page'] as int?) ?? 1,
      pageSize: (json['page_size'] as int?) ?? 50,
      currentUserPosition: json['current_user_position'] as int?,
      entries: ((json['entries'] as List<dynamic>?) ?? [])
          .map((e) => CommunityRankingEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// CommunityShareScope — the share toggles per community (spec §14–§16).
class CommunityShareScope {
  const CommunityShareScope({
    this.readiness = false,
    this.sleep = false,
    this.activity = false,
    this.strain = false,
  });

  final bool readiness;
  final bool sleep;
  final bool activity;
  final bool strain;

  static const List<String> keys = ['readiness', 'sleep', 'activity', 'strain'];

  bool valueFor(String key) => switch (key) {
        'readiness' => readiness,
        'sleep' => sleep,
        'activity' => activity,
        'strain' => strain,
        _ => false,
      };

  CommunityShareScope copyWith({
    bool? readiness,
    bool? sleep,
    bool? activity,
    bool? strain,
  }) {
    return CommunityShareScope(
      readiness: readiness ?? this.readiness,
      sleep: sleep ?? this.sleep,
      activity: activity ?? this.activity,
      strain: strain ?? this.strain,
    );
  }

  Map<String, dynamic> toJson() => {
        'readiness': readiness,
        'sleep': sleep,
        'activity': activity,
        'strain': strain,
      };

  factory CommunityShareScope.fromJson(Map<String, dynamic> json) {
    return CommunityShareScope(
      readiness: (json['readiness'] as bool?) ?? false,
      sleep: (json['sleep'] as bool?) ?? false,
      activity: (json['activity'] as bool?) ?? false,
      strain: (json['strain'] as bool?) ?? false,
    );
  }
}
