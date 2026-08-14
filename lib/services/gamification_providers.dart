/// Gamification Riverpod state (Phase 8, spec §47).
///
/// Includes a lightweight "newly unlocked" tracker so the unlock celebration
/// fires only once per achievement per session (spec §52).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../shared/models/gamification.dart';
import 'gamification_service.dart';

final gamificationServiceProvider = Provider<GamificationService>((ref) {
  return GamificationService(apiClient: ref.watch(apiClientProvider));
});

/// Catalog + current user state.
final achievementsProvider =
    FutureProvider<List<Achievement>>((ref) {
  return ref.watch(gamificationServiceProvider).getAchievements();
});

/// Gamification summary (badges, streak, points, level).
final gamificationSummaryProvider = FutureProvider<GamificationSummary>((ref) {
  return ref.watch(gamificationServiceProvider).getSummary();
});

/// Streaks.
final streakProvider = FutureProvider<List<WellnessStreak>>((ref) {
  return ref.watch(gamificationServiceProvider).getStreaks();
});

/// Codes already celebrated this session (unlock UX dedup, spec §52).
final celebratedUnlocksProvider =
    NotifierProvider<CelebratedUnlocks, Set<String>>(CelebratedUnlocks.new);

class CelebratedUnlocks extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void mark(String code) {
    state = {...state, code};
  }

  bool isCelebrated(String code) => state.contains(code);
}

/// Controller for gamification mutations.
class GamificationActionController {
  GamificationActionController(this._ref);

  final Ref _ref;

  Future<List<SelectedBadge>> selectBadges(List<String> codes) async {
    final badges = await _ref
        .read(gamificationServiceProvider)
        .selectBadges(codes);
    _ref.invalidate(gamificationSummaryProvider);
    return badges;
  }

  /// Returns codes newly unlocked (not celebrated this session) — spec §52.
  List<Achievement> newlyUnlocked(List<Achievement> achievements) {
    final celebrated = _ref.read(celebratedUnlocksProvider);
    return achievements
        .where((a) => a.unlocked && !celebrated.contains(a.code))
        .toList();
  }

  void markCelebrated(String code) {
    _ref.read(celebratedUnlocksProvider.notifier).mark(code);
  }
}

final gamificationActionControllerProvider =
    Provider<GamificationActionController>((ref) {
  return GamificationActionController(ref);
});
