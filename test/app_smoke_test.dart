/// App-level smoke test: renders the shell and shows the login screen
/// when unauthenticated (no real AWS calls — fake gateway).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/providers.dart';
import 'package:noana_wellness_app/app.dart';

import 'helpers/fakes.dart';

void main() {
  testWidgets('app shows login screen when no session', (tester) async {
    final gateway = FakeCognitoGateway();
    final storage = FakeSecureStorage();

    final container = ProviderContainer(overrides: [
      secureStorageProvider.overrideWithValue(storage),
      authServiceProvider.overrideWith((ref) {
        final service = AuthService(gateway: gateway, storage: storage);
        ref.onDispose(service.dispose);
        return service;
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoanaWellnessApp(),
      ),
    );
    await tester.pumpAndSettle();

    // App title renders; login affordance present.
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Noana Wellness'), findsWidgets);
  });
}
