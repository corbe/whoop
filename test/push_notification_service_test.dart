import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/features/notifications/deep_link.dart';
import 'package:noana_wellness_app/services/push_notification_service.dart';
import 'package:noana_wellness_app/services/push_registration_service.dart';

/// Gateway fake: simula FirebaseMessaging sem Firebase real (spec §25).
class _FakeGateway implements MessagingGateway {
  final tokenController = StreamController<String>.broadcast();
  final foregroundController = StreamController<Map<String, dynamic>>.broadcast();
  final openedController = StreamController<Map<String, dynamic>>.broadcast();

  PushPermissionStatus permissionResult = PushPermissionStatus.authorized;
  String? token = 'fcm-token-1';
  String? apnsToken = 'apns-token-1';
  Map<String, dynamic>? initialMessage;
  int permissionRequests = 0;

  @override
  Future<PushPermissionStatus> requestPermission() async {
    permissionRequests++;
    return permissionResult;
  }

  @override
  Future<String?> getToken() async => token;

  @override
  Future<String?> getApnsToken() async => apnsToken;

  @override
  Stream<String> get onTokenRefresh => tokenController.stream;

  @override
  Stream<Map<String, dynamic>> get onForegroundMessage => foregroundController.stream;

  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp => openedController.stream;

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async => initialMessage;

  void dispose() {
    tokenController.close();
    foregroundController.close();
    openedController.close();
  }
}

/// ApiClient fake: captura POST/DELETE.
class _FakeApi implements ApiClient {
  final posts = <Map<String, dynamic>>[];
  final deletes = <String>[];

  @override
  Future<ApiResponse> get(String path,
          {bool authenticated = true, Map<String, String>? query}) async =>
      throw UnimplementedError();

  @override
  Future<ApiResponse> post(String path,
      {bool authenticated = true, Object? body}) async {
    posts.add({'path': path, 'body': body});
    return ApiResponse(data: {'id': 'device-abc-123'}, statusCode: 201);
  }

  @override
  Future<ApiResponse> patch(String path,
          {bool authenticated = true, Object? body}) async =>
      throw UnimplementedError();

  @override
  Future<ApiResponse> put(String path,
          {bool authenticated = true, Object? body}) async =>
      throw UnimplementedError();

  @override
  Future<ApiResponse> delete(String path,
      {bool authenticated = true}) async {
    deletes.add(path);
    return ApiResponse(data: null, statusCode: 204);
  }
}

void main() {
  late _FakeGateway gateway;
  late _FakeApi api;
  late PushNotificationService service;

  setUp(() {
    gateway = _FakeGateway();
    api = _FakeApi();
    service = PushNotificationService(
      gateway: gateway,
      registration: PushRegistrationService(apiClient: api),
      platformOverride: 'ios',
    );
  });

  tearDown(() => gateway.dispose());

  group('init', () {
    test('solicita permissao e captura tokens', () async {
      await service.init();
      expect(gateway.permissionRequests, 1);
      expect(service.permission, PushPermissionStatus.authorized);
    });

    test('permissao negada degrada sem erro', () async {
      gateway.permissionResult = PushPermissionStatus.denied;
      await service.init();
      expect(service.permission, PushPermissionStatus.denied);
    });
  });

  group('registro após login (spec §11, §13)', () {
    test('onAuthenticated registra device com token+platform', () async {
      await service.init();
      await service.onAuthenticated();

      expect(api.posts.single['path'], '/wellness/devices/push/');
      final body = api.posts.single['body'] as Map;
      expect(body['token'], 'fcm-token-1');
      expect(body['platform'], 'ios');
      expect(service.deviceId, 'device-abc-123');
    });

    test('sem token não registra (degradado)', () async {
      gateway.token = null;
      await service.init();
      await service.onAuthenticated();
      expect(api.posts, isEmpty);
    });
  });

  group('token refresh (spec §10)', () {
    test('refresh após autenticado re-registra idempotentemente', () async {
      await service.init();
      await service.onAuthenticated();
      expect(api.posts.length, 1);

      gateway.tokenController.add('fcm-token-2');
      await Future<void>.delayed(Duration.zero);

      expect(api.posts.length, 2);
      final body = api.posts.last['body'] as Map;
      expect(body['token'], 'fcm-token-2');
    });

    test('refresh ANTES de autenticar não registra', () async {
      await service.init();
      gateway.tokenController.add('fcm-token-early');
      await Future<void>.delayed(Duration.zero);
      expect(api.posts, isEmpty);
    });
  });

  group('logout / troca de conta A→B (spec §12–§13)', () {
    test('logout desassocia o device do usuário atual', () async {
      await service.init();
      await service.onAuthenticated();
      expect(service.deviceId, 'device-abc-123');

      await service.onLoggedOut();

      expect(api.deletes.single, '/wellness/devices/push/device-abc-123/');
      expect(service.deviceId, isNull);
    });

    test('A→B: logout A desassocia; login B registra no MESMO device', () async {
      await service.init();
      await service.onAuthenticated(); // A
      expect(api.posts.length, 1);

      await service.onLoggedOut(); // logout A → DELETE
      expect(api.deletes.single, '/wellness/devices/push/device-abc-123/');

      // Mesmo device físico → MESMO token FCM; a associação muda via JWT no
      // backend (A teve a linha deletada; B cria a dele no POST seguinte).
      await service.onAuthenticated(); // B
      expect(api.posts.length, 2);
      final body = api.posts.last['body'] as Map;
      expect(body['token'], 'fcm-token-1');
      // A garantia de isolamento é servidor-side: DELETE de A + JWT de B.
      expect(api.deletes.length, 1);
    });

    test('logout sem registro não chama a rede', () async {
      await service.init();
      await service.onLoggedOut();
      expect(api.deletes, isEmpty);
    });
  });

  group('mensagens e deep links (spec §15–§18)', () {
    test('opened com payload chat navega para a comunidade', () async {
      final links = <NotificationDeepLink>[];
      service.onOpenLink = (link) async => links.add(link);
      await service.init();

      gateway.openedController.add({
        'type': 'chat',
        'target_id': 'community-uuid-1',
        'message_id': 'msg-1',
      });
      await Future<void>.delayed(Duration.zero);

      expect(links.single.type, DeepLinkType.community);
      expect(links.single.targetId, 'community-uuid-1');
      expect(links.single.extras['message_id'], 'msg-1');
    });

    test('opened com convite navega com token', () async {
      final links = <NotificationDeepLink>[];
      service.onOpenLink = (link) async => links.add(link);
      await service.init();

      gateway.openedController.add({
        'type': 'community_invite',
        'target_id': 'invite-token-xyz',
        'community_uuid': 'community-uuid-9',
      });
      await Future<void>.delayed(Duration.zero);

      expect(links.single.type, DeepLinkType.communityInvite);
      expect(links.single.extras['community_uuid'], 'community-uuid-9');
    });

    test('opened com challenge/achievement navega', () async {
      final links = <NotificationDeepLink>[];
      service.onOpenLink = (link) async => links.add(link);
      await service.init();

      gateway.openedController.add({
        'type': 'challenge',
        'target_id': 'challenge-uuid-7',
        'final_rank': 3,
      });
      gateway.openedController.add({
        'type': 'achievement',
        'target_id': 'achievement-id-4',
        'code': 'FIRST_CHALLENGE',
      });
      await Future<void>.delayed(Duration.zero);

      expect(links.length, 2);
      expect(links[0].type, DeepLinkType.challenge);
      expect(links[1].type, DeepLinkType.achievement);
    });

    test('payload malformado NÃO navega (fallback seguro)', () async {
      var navigated = false;
      service.onOpenLink = (link) async => navigated = true;
      await service.init();

      gateway.openedController.add({'type': 'chat'}); // sem target_id
      gateway.openedController.add({'target_id': 'x'}); // sem type
      gateway.openedController.add({'type': 'unknown', 'target_id': 'y'});
      await Future<void>.delayed(Duration.zero);

      expect(navigated, isFalse);
    });

    test('initialMessage (cold-start) navega após init', () async {
      final links = <NotificationDeepLink>[];
      service.onOpenLink = (link) async => links.add(link);
      gateway.initialMessage = {
        'type': 'achievement',
        'target_id': 'achievement-id-4',
      };

      await service.init();

      expect(links.single.type, DeepLinkType.achievement);
    });
  });

  group('parse de payload (spec §17)', () {
    test('chat', () {
      final link = NotificationDeepLink.fromPayload({
        'type': 'chat',
        'target_id': 'c-1',
        'message_id': 'm-1',
      });
      expect(link?.type, DeepLinkType.community);
      expect(link?.targetId, 'c-1');
    });

    test('community_invite', () {
      final link = NotificationDeepLink.fromPayload({
        'type': 'community_invite',
        'target_id': 'tok',
        'community_uuid': 'c-2',
      });
      expect(link?.type, DeepLinkType.communityInvite);
      expect(link?.extras['community_uuid'], 'c-2');
    });

    test('challenge', () {
      final link = NotificationDeepLink.fromPayload({
        'type': 'challenge',
        'target_id': 'ch-3',
        'final_rank': 1,
      });
      expect(link?.type, DeepLinkType.challenge);
      expect(link?.extras['final_rank'], 1);
    });

    test('achievement', () {
      final link = NotificationDeepLink.fromPayload({
        'type': 'achievement',
        'target_id': 'a-4',
        'code': 'FIRST_SCORE',
      });
      expect(link?.type, DeepLinkType.achievement);
      expect(link?.extras['code'], 'FIRST_SCORE');
    });

    test('malformados retornam null', () {
      expect(NotificationDeepLink.fromPayload(null), isNull);
      expect(NotificationDeepLink.fromPayload({}), isNull);
      expect(
        NotificationDeepLink.fromPayload({'type': 'chat', 'target_id': ''}),
        isNull,
      );
    });
  });
}
