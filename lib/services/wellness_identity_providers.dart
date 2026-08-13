/// Wellness identity Riverpod state (spec §61).
///
/// - [currentWellnessPersonProvider]: the authenticated user's WellnessPerson
///   (AsyncValue; resolves via bootstrap on first access).
/// - [wellnessProfileProvider]: the 1:1 WellnessProfile.
/// - [bootstrapWellnessProvider]: imperative handle to (re)run bootstrap after
///   login/session restore; keeps person uuid in secure storage.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_service.dart';
import '../core/providers.dart';
import '../shared/models/wellness_identity.dart';
import 'wellness_api_service.dart';

/// Runs bootstrap (idempotent) and persists the person uuid in secure storage.
final bootstrapWellnessProvider = Provider<Future<WellnessBootstrapResponse> Function()>(
  (ref) {
    final api = ref.watch(wellnessApiServiceProvider);
    final storage = ref.watch(secureStorageProvider);
    return () async {
      final result = await api.bootstrap();
      await storage.saveWellnessPersonUuid(result.person.uuid);
      return result;
    };
  },
);

/// Current WellnessPerson (null while not bootstrapped / not authenticated).
final currentWellnessPersonProvider =
    AsyncNotifierProvider<CurrentWellnessPersonNotifier, WellnessPerson?>(
  CurrentWellnessPersonNotifier.new,
);

class CurrentWellnessPersonNotifier extends AsyncNotifier<WellnessPerson?> {
  @override
  Future<WellnessPerson?> build() async {
    // Only meaningful when authenticated; resolves person lazily.
    final authStatus = ref.watch(authStatusProvider).valueOrNull;
    if (authStatus != AuthStatus.authenticated) return null;
    try {
      final bootstrap = ref.watch(bootstrapWellnessProvider);
      final result = await bootstrap();
      return result.person;
    } catch (_) {
      // Offline or backend unavailable: fall back to stored uuid if present.
      final stored = await ref.read(secureStorageProvider).getWellnessPersonUuid();
      if (stored == null) rethrow;
      return WellnessPerson(uuid: stored, cognitoSub: '');
    }
  }

  /// Re-runs bootstrap after login/logout cycles.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => build());
  }
}

/// WellnessProfile of the current person (derived from bootstrap/me).
final wellnessProfileProvider =
    AsyncNotifierProvider<WellnessProfileNotifier, WellnessProfile?>(
  WellnessProfileNotifier.new,
);

class WellnessProfileNotifier extends AsyncNotifier<WellnessProfile?> {
  @override
  Future<WellnessProfile?> build() async {
    final person = await ref.watch(currentWellnessPersonProvider.future);
    if (person == null) return null;
    final api = ref.watch(wellnessApiServiceProvider);
    final me = await api.getMe();
    return me.profile;
  }

  Future<void> applyProfileUpdate(Map<String, dynamic> fields) async {
    final api = ref.watch(wellnessApiServiceProvider);
    final updated = await api.updateMe(
      displayName: fields['display_name'] as String?,
      avatarUrl: fields['avatar_url'] as String?,
      heightCm: (fields['height_cm'] as num?)?.toDouble(),
      birthDate: fields['birth_date'] as String?,
      gender: fields['gender'] as String?,
      bedTimeMin: fields['bed_time_min'] as String?,
      sleepTargetMin: fields['sleep_target_min'] as int?,
      goalSteps: fields['goal_steps'] as int?,
      timezone: fields['timezone'] as String?,
      formulaClientVersion: fields['formula_client_version'] as String?,
    );
    state = AsyncValue.data(updated.profile);
  }
}
