/// Identity display-name sync (Social Phase):
///
/// - [AuthService.preferredDisplayName] selects name/nickname, never email.
/// - [CurrentWellnessPersonNotifier] seeds an empty backend display_name from
///   the user's own Cognito attributes via PATCH /wellness/me/ (best-effort,
///   idempotent — a failure never breaks bootstrap).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/providers.dart';
import 'package:noana_wellness_app/services/wellness_api_service.dart';
import 'package:noana_wellness_app/services/wellness_identity_providers.dart';
import 'package:noana_wellness_app/shared/models/wellness_identity.dart';

import 'helpers/fakes.dart';

void main() {
  group('AuthService.preferredDisplayName', () {
    test('uses the name attribute when present', () {
      expect(
        AuthService.preferredDisplayName(const {'name': 'Maria Silva'}),
        'Maria Silva',
      );
    });

    test('falls back to nickname when name is absent', () {
      expect(
        AuthService.preferredDisplayName(const {'nickname': 'Mari'}),
        'Mari',
      );
    });

    test('prefers name over nickname', () {
      expect(
        AuthService.preferredDisplayName(
            const {'name': 'Maria', 'nickname': 'Mari'}),
        'Maria',
      );
    });

    test('never uses email as a display name', () {
      expect(
        AuthService.preferredDisplayName(
            const {'email': 'maria@noana.com'}),
        isNull,
      );
    });

    test('returns null for empty/whitespace values', () {
      expect(
        AuthService.preferredDisplayName(const {'name': '   '}),
        isNull,
      );
      expect(AuthService.preferredDisplayName(const {}), isNull);
    });

    test('falls back to the Cognito username when no name attribute exists',
        () {
      expect(
        AuthService.preferredDisplayName(
          const {'email': 'maria@noana.com'},
          username: 'maria',
        ),
        'maria',
      );
    });

    test('name still wins over the username', () {
      expect(
        AuthService.preferredDisplayName(
          const {'name': 'Maria Silva'},
          username: 'maria',
        ),
        'Maria Silva',
      );
    });

    test('skips an email-shaped username (pool with email usernames)', () {
      expect(
        AuthService.preferredDisplayName(
          const {},
          username: 'maria@noana.com',
        ),
        isNull,
      );
    });
  });

  group('CurrentWellnessPersonNotifier display-name sync', () {
    const personUuid = '11111111-2222-3333-4444-555555555555';
    const gatewayDefaultUsername = 'user@noana.com';
    Map<String, dynamic> personJson({String displayName = ''}) => {
          'uuid': personUuid,
          'cognito_sub': 'sub-1',
          'user_uuid': null,
          'display_name': displayName,
          'avatar_url': '',
          'height_cm': null,
          'birth_date': null,
          'gender': '',
          'created_at': null,
          'updated_at': null,
        };

    Future<ProviderContainer> containerWith({
      required Map<String, String> cognitoAttrs,
      required _FakeWellnessApi api,
      String? usernameOverride,
    }) async {
      final gateway = FakeCognitoGateway()
        ..userAttributes = cognitoAttrs
        ..usernameOverride = usernameOverride ?? gatewayDefaultUsername;
      final auth = AuthService(gateway: gateway, storage: FakeSecureStorage());
      // Authenticate the real service so its synchronous status is
      // `authenticated` (mirrors the app flow; the auth stream is left real).
      final login = await auth.login(
        username: gateway.validUsername,
        password: gateway.validPassword,
      );
      expect(login.ok, isTrue);
      return ProviderContainer(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          wellnessApiServiceProvider.overrideWithValue(api),
          secureStorageProvider.overrideWithValue(FakeSecureStorage()),
        ],
      );
    }

    test('seeds display_name from Cognito name when backend has none',
        () async {
      final api = _FakeWellnessApi(
        bootstrapPerson: personJson(),
        updatePerson: personJson(displayName: 'Maria Silva'),
      );
      final container = await containerWith(
        cognitoAttrs: const {'name': 'Maria Silva'},
        api: api,
      );
      addTearDown(container.dispose);

      final person = await container.read(currentWellnessPersonProvider.future);
      expect(person!.displayName, 'Maria Silva');
      expect(api.updateMeCallCount, 1,
          reason: 'PATCH /me/ must be called exactly once to seed the name');
    });

    test('does not PATCH when the backend already has a display name',
        () async {
      final api = _FakeWellnessApi(
        bootstrapPerson: personJson(displayName: 'Maria'),
      );
      final container = await containerWith(
        cognitoAttrs: const {'name': 'Maria Silva'},
        api: api,
      );
      addTearDown(container.dispose);

      final person = await container.read(currentWellnessPersonProvider.future);
      expect(person!.displayName, 'Maria');
      expect(api.updateMeCallCount, 0);
    });

    test('seeds display_name from the Cognito USERNAME when no name '
        'attribute exists (owner "daniel" case)', () async {
      final api = _FakeWellnessApi(
        bootstrapPerson: personJson(),
        updatePerson: personJson(displayName: 'daniel'),
      );
      final container = await containerWith(
        cognitoAttrs: const {'email': 'daniel.latorre@noana.com.br'},
        usernameOverride: 'daniel',
        api: api,
      );
      addTearDown(container.dispose);

      final person = await container.read(currentWellnessPersonProvider.future);
      expect(person!.displayName, 'daniel',
          reason: 'username fallback deve popular o display_name do owner');
      expect(api.updateMeCallCount, 1);
      expect(api.lastUpdateMeDisplayName, 'daniel');
    });

    test('does NOT PATCH when the username is email-shaped (email pool)',
        () async {
      final api = _FakeWellnessApi(bootstrapPerson: personJson());
      final container = await containerWith(
        cognitoAttrs: const {'email': 'maria@noana.com'},
        usernameOverride: 'maria@noana.com',
        api: api,
      );
      addTearDown(container.dispose);

      final person = await container.read(currentWellnessPersonProvider.future);
      expect(person!.displayName, isEmpty,
          reason: 'email-shaped username nunca vira display name');
      expect(api.updateMeCallCount, 0);
    });

    test('does not PATCH when Cognito has no usable name attribute',
        () async {
      final api = _FakeWellnessApi(bootstrapPerson: personJson());
      final container = await containerWith(
        cognitoAttrs: const {'email': 'maria@noana.com'},
        api: api,
      );
      addTearDown(container.dispose);

      final person = await container.read(currentWellnessPersonProvider.future);
      expect(person!.displayName, '');
      expect(api.updateMeCallCount, 0,
          reason: 'email must never seed a display name');
    });

    test('a failed PATCH does not break bootstrap (best-effort)', () async {
      final api = _FakeWellnessApi(bootstrapPerson: personJson())
        ..failUpdateMe = true;
      final container = await containerWith(
        cognitoAttrs: const {'name': 'Maria Silva'},
        api: api,
      );
      addTearDown(container.dispose);

      final person = await container.read(currentWellnessPersonProvider.future);
      expect(person!.displayName, '');
    });
  });
}

class _FakeWellnessApi implements WellnessApiService {
  _FakeWellnessApi({
    required this.bootstrapPerson,
    this.updatePerson,
  });

  final Map<String, dynamic> bootstrapPerson;
  final Map<String, dynamic>? updatePerson;
  int updateMeCallCount = 0;
  bool failUpdateMe = false;
  String? lastUpdateMeDisplayName;

  WellnessBootstrapResponse get _bootstrapResp => WellnessBootstrapResponse.fromJson({
        'person': bootstrapPerson,
        'profile': profileJson,
        'created': false,
      });

  static const profileJson = {
    'bed_time_min': '',
    'sleep_target_min': null,
    'goal_steps': null,
    'timezone': 'America/Sao_Paulo',
    'formula_client_version': '',
  };

  @override
  Future<WellnessBootstrapResponse> bootstrap() async => _bootstrapResp;

  @override
  Future<WellnessMe> getMe() async => WellnessMe.fromJson({
        'person': bootstrapPerson,
        'profile': profileJson,
      });

  @override
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
    updateMeCallCount++;
    lastUpdateMeDisplayName = displayName;
    if (failUpdateMe) {
      throw Exception('PATCH failed');
    }
    final person = updatePerson ?? bootstrapPerson;
    return WellnessMe.fromJson({'person': person, 'profile': profileJson});
  }
}
