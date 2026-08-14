/// Gamification domain models (Phase 8) — mirror the backend API.
library;

enum AchievementCategory { scores, community, challenge, consistency }

AchievementCategory achievementCategoryFrom(String? value) {
  switch (value) {
    case 'community':
      return AchievementCategory.community;
    case 'challenge':
      return AchievementCategory.challenge;
    case 'consistency':
      return AchievementCategory.consistency;
    default:
      return AchievementCategory.scores;
  }
}

/// Achievement catalog item + current user state (spec §38).
class Achievement {
  const Achievement({
    required this.code,
    required this.name,
    required this.description,
    required this.category,
    required this.iconKey,
    required this.points,
    required this.progress,
    required this.target,
    required this.unlocked,
    this.unlockedAt,
  });

  final String code;
  final String name;
  final String description;
  final AchievementCategory category;
  final String iconKey;
  final int points;
  final int progress;
  final int target;
  final bool unlocked;
  final DateTime? unlockedAt;

  factory Achievement.fromJson(Map<String, dynamic> json) {
    return Achievement(
      code: json['code'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      category: achievementCategoryFrom(json['category'] as String?),
      iconKey: (json['icon_key'] as String?) ?? '',
      points: (json['points'] as int?) ?? 0,
      progress: (json['progress'] as int?) ?? 0,
      target: (json['target'] as int?) ?? 1,
      unlocked: (json['unlocked'] as bool?) ?? false,
      unlockedAt: json['unlocked_at'] == null
          ? null
          : DateTime.tryParse(json['unlocked_at'] as String),
    );
  }
}

/// Gamification summary (spec §39).
class GamificationSummary {
  const GamificationSummary({
    required this.unlockedCount,
    required this.totalCount,
    required this.currentStreak,
    required this.bestStreak,
    required this.points,
    required this.level,
    required this.selectedBadges,
    this.lastQualifiedDate,
  });

  final int unlockedCount;
  final int totalCount;
  final int currentStreak;
  final int bestStreak;
  final int points;
  final int level;
  final List<SelectedBadge> selectedBadges;
  final DateTime? lastQualifiedDate;

  factory GamificationSummary.fromJson(Map<String, dynamic> json) {
    return GamificationSummary(
      unlockedCount: (json['unlocked_count'] as int?) ?? 0,
      totalCount: (json['total_count'] as int?) ?? 0,
      currentStreak: (json['current_streak'] as int?) ?? 0,
      bestStreak: (json['best_streak'] as int?) ?? 0,
      points: (json['points'] as int?) ?? 0,
      level: (json['level'] as int?) ?? 1,
      lastQualifiedDate: json['last_qualified_date'] == null
          ? null
          : DateTime.tryParse(json['last_qualified_date'] as String),
      selectedBadges: ((json['selected_badges'] as List?) ?? const [])
          .map((e) => SelectedBadge.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Selected badge for profile display (spec §43).
class SelectedBadge {
  const SelectedBadge({
    required this.code,
    required this.name,
    required this.iconKey,
    required this.position,
  });

  final String code;
  final String name;
  final String iconKey;
  final int position;

  factory SelectedBadge.fromJson(Map<String, dynamic> json) {
    return SelectedBadge(
      code: json['code'] as String,
      name: (json['name'] as String?) ?? '',
      iconKey: (json['icon_key'] as String?) ?? '',
      position: (json['position'] as int?) ?? 0,
    );
  }
}

/// WellnessStreak (spec §28–§32) — recording consistency, not health.
class WellnessStreak {
  const WellnessStreak({
    required this.streakType,
    required this.currentCount,
    required this.bestCount,
    this.currentStartDate,
    this.lastQualifiedDate,
  });

  final String streakType;
  final int currentCount;
  final int bestCount;
  final DateTime? currentStartDate;
  final DateTime? lastQualifiedDate;

  factory WellnessStreak.fromJson(Map<String, dynamic> json) {
    return WellnessStreak(
      streakType: (json['streak_type'] as String?) ?? 'daily_score',
      currentCount: (json['current_count'] as int?) ?? 0,
      bestCount: (json['best_count'] as int?) ?? 0,
      currentStartDate: json['current_start_date'] == null
          ? null
          : DateTime.tryParse(json['current_start_date'] as String),
      lastQualifiedDate: json['last_qualified_date'] == null
          ? null
          : DateTime.tryParse(json['last_qualified_date'] as String),
    );
  }
}
