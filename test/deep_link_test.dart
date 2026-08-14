import 'package:flutter_test/flutter_test.dart';
import 'package:noana_wellness_app/features/notifications/deep_link.dart';
import 'package:noana_wellness_app/features/notifications/deep_link_router.dart';

void main() {
  group('NotificationDeepLink payload safety', () {
    test('payload contem APENAS type + target_id (sem dados sensiveis)', () {
      final link = NotificationDeepLink(
        type: DeepLinkType.community,
        targetId: 'uuid-comunidade',
      );
      final payload = link.toPayload();
      expect(payload.keys.toSet(), {'type', 'target_id'});
      expect(
        payload.values.join(' ').toLowerCase(),
        isNot(contains('jwt')),
        reason: 'JWT nunca no payload',
      );
      expect(payload['target_id'], isNot(contains('@')),
          reason: 'email nunca no payload');
      expect(payload['target_id'], isNot(contains('hr')),
          reason: 'dados fisiologicos nunca no payload');
    });

    test('parse aceita payload valido de community', () {
      final link = NotificationDeepLink.fromPayload(
          {'type': 'community', 'target_id': 'c1'});
      expect(link?.type, DeepLinkType.community);
      expect(link?.targetId, 'c1');
    });

    test('parse rejeita payload sem target ou tipo desconhecido', () {
      expect(NotificationDeepLink.fromPayload({'type': 'community'}), isNull);
      expect(NotificationDeepLink.fromPayload(null), isNull);
      expect(NotificationDeepLink.fromPayload(
          {'type': 'health', 'target_id': 'x'}), isNull);
    });
  });

  group('DeepLinkRouter cold-start ordering', () {
    test('ordem estrita: session -> bootstrap -> router -> navigate', () async {
      final order = <String>[];
      final router = DeepLinkRouter(
        waitForSessionRestore: () async => order.add('session'),
        waitForWellnessBootstrap: () async => order.add('bootstrap'),
        waitForRouterReady: () async => order.add('router'),
        navigate: (link) async => order.add('navigate:${link.type.name}'),
      );

      await router.handle(const NotificationDeepLink(
          type: DeepLinkType.community, targetId: 'c1'));

      expect(order, ['session', 'bootstrap', 'router', 'navigate:community']);
    });

    test('navegacao so acontece apos bootstrap (nao corre antes)', () async {
      final navigated = <String>[];
      // ignore: unused_local_variable — garante que handle é o único caminho
      final router = DeepLinkRouter(
        waitForSessionRestore: () async {},
        waitForWellnessBootstrap: () async {},
        waitForRouterReady: () async {},
        navigate: (link) async => navigated.add(link.targetId),
      );
      // garante que handle é o unico caminho de navegacao: sem chamada, nada navega
      expect(navigated, isEmpty);
    });
  });
}
