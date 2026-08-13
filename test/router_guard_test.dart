/// Router guard tests: unauthenticated -> /login, authenticated -> home.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/providers.dart';
import 'package:noana_wellness_app/core/routing/app_router.dart';

import 'helpers/fakes.dart';

void main() {
  group('Router auth guard', () {
    late FakeCognitoGateway gateway;
    late FakeSecureStorage storage;

    setUp(() {
      gateway = FakeCognitoGateway();
      storage = FakeSecureStorage();
    });

    ProviderContainer makeContainer() {
      return ProviderContainer(overrides: [
        secureStorageProvider.overrideWithValue(storage),
        authServiceProvider.overrideWith((ref) {
          final service = AuthService(gateway: gateway, storage: storage);
          ref.onDispose(service.dispose);
          return service;
        }),
      ]);
    }

    Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: container.read(routerProvider),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('unauthenticated user lands on /login', (tester) async {
      final container = makeContainer();
      await container.read(authServiceProvider).initialize();
      addTearDown(container.dispose);

      await pumpApp(tester, container);

      expect(find.text('Noana Wellness'), findsOneWidget);
      expect(find.text('Entrar'), findsOneWidget);
    });

    testWidgets('authenticated user is redirected away from /login', (tester) async {
      final container = makeContainer();
      final auth = container.read(authServiceProvider);
      await auth.initialize();
      addTearDown(container.dispose);

      // Pump first so the auth status stream is being listened to, then log in.
      await pumpApp(tester, container);
      expect(find.text('Entrar'), findsOneWidget);

      await auth.login(username: 'user@noana.com', password: 'secret123');
      await tester.pumpAndSettle();

      expect(find.text('Bem-vindo!'), findsOneWidget);
      expect(find.text('Entrar'), findsNothing);
    });

    testWidgets('router redirects to login when session ends', (tester) async {
      final container = makeContainer();
      final auth = container.read(authServiceProvider);
      await auth.initialize();
      addTearDown(container.dispose);

      await pumpApp(tester, container);
      await auth.login(username: 'user@noana.com', password: 'secret123');
      await tester.pumpAndSettle();
      expect(find.text('Bem-vindo!'), findsOneWidget);

      await auth.logout();
      await tester.pumpAndSettle();

      expect(find.text('Entrar'), findsOneWidget);
    });
  });
}
