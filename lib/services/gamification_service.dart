/// GamificationService (Phase 8, spec §46) — achievements/streaks/summary.
library;

import '../core/network/api_client.dart';
import '../shared/models/gamification.dart';

class GamificationService {
  GamificationService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  /// GET /wellness/achievements/ (spec §38).
  Future<List<Achievement>> getAchievements() async {
    final res = await _api.get('/wellness/achievements/');
    return ((res.data as Map<String, dynamic>)['items'] as List? ?? [])
        .map((e) => Achievement.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /wellness/gamification/summary/ (spec §39).
  Future<GamificationSummary> getSummary() async {
    final res = await _api.get('/wellness/gamification/summary/');
    return GamificationSummary.fromJson(res.data as Map<String, dynamic>);
  }

  /// GET /wellness/streaks/ (spec §40).
  Future<List<WellnessStreak>> getStreaks() async {
    final res = await _api.get('/wellness/streaks/');
    return ((res.data as Map<String, dynamic>)['streaks'] as List? ?? [])
        .map((e) => WellnessStreak.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /wellness/gamification/select-badges/ (spec §43) — up to 3.
  Future<List<SelectedBadge>> selectBadges(List<String> codes) async {
    final res = await _api.post(
      '/wellness/gamification/select-badges/',
      body: {'codes': codes},
    );
    return ((res.data as Map<String, dynamic>)['selected_badges'] as List? ?? [])
        .map((e) => SelectedBadge.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
