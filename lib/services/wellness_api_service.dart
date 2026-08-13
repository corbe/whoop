/// Wellness API service (Phase 2).
///
/// Talks to the Noana backend `/v1/wellness/*` endpoints through [ApiClient]
/// (Cognito Bearer injection + 401 refresh-retry, spec §62). Widgets never
/// call HTTP directly — they consume Riverpod providers built on this service.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/providers.dart';
import '../shared/models/wellness_identity.dart';

class WellnessApiService {
  WellnessApiService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  static const String _base = '/wellness';

  /// POST /wellness/bootstrap/ — idempotent resolve-or-create (spec §6, §10).
  Future<WellnessBootstrapResponse> bootstrap() async {
    final res = await _api.post('$_base/bootstrap/', body: {});
    return WellnessBootstrapResponse.fromJson(
      res.data as Map<String, dynamic>,
    );
  }

  /// GET /wellness/me/ — person + profile (404 if bootstrap pending).
  Future<WellnessMe> getMe() async {
    final res = await _api.get('$_base/me/');
    return WellnessMe.fromJson(res.data as Map<String, dynamic>);
  }

  /// PATCH /wellness/me/ — update editable fields (whitelist server-side).
  Future<WellnessMe> updateMe({
    String? displayName,
    String? avatarUrl,
    double? heightCm,
    String? birthDate,
    String? gender,
    String? bedTimeMin,
    int? sleepTargetMin,
    int? goalSteps,
    String? timezone,
    String? formulaClientVersion,
  }) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['display_name'] = displayName;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;
    if (heightCm != null) body['height_cm'] = heightCm;
    if (birthDate != null) body['birth_date'] = birthDate;
    if (gender != null) body['gender'] = gender;
    if (bedTimeMin != null) body['bed_time_min'] = bedTimeMin;
    if (sleepTargetMin != null) body['sleep_target_min'] = sleepTargetMin;
    if (goalSteps != null) body['goal_steps'] = goalSteps;
    if (timezone != null) body['timezone'] = timezone;
    if (formulaClientVersion != null) {
      body['formula_client_version'] = formulaClientVersion;
    }
    final res = await _api.patch('$_base/me/', body: body);
    return WellnessMe.fromJson(res.data as Map<String, dynamic>);
  }
}

/// Riverpod provider for [WellnessApiService].
final wellnessApiServiceProvider = Provider<WellnessApiService>((ref) {
  return WellnessApiService(apiClient: ref.watch(apiClientProvider));
});
