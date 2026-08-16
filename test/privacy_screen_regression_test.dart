/// Regression: PrivacyScreen must not read inherited widgets in initState().
///
/// Reproduces the real Android runtime failure:
///   "dependOnInheritedWidgetOfExactType<_ModalScopeStatus>() or
///    dependOnInheritedElement() was called before _PrivacyScreenState
///    .initState() completed."
/// caused by `ModalRoute.of(context)` inside initState() (privacy_screen.dart).
///
/// The screen is mounted through the SAME routing path the app uses
/// (Navigator.push + MaterialPageRoute), with the share scope passed via the
/// constructor — exactly like community_detail_screen._openPrivacy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/features/communities/privacy_screen.dart';
import 'package:noana_wellness_app/shared/models/score.dart';

void main() {
  testWidgets(
      'PrivacyScreen mounts via Navigator.push without inherited-widget '
      'access in initState (first and second open)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: _Host(
            onOpen: (context) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PrivacyScreen(
                    communityUuid: 'community-uuid-1',
                    communityName: 'Comunidade Teste',
                    initialScope: CommunityShareScope(
                      readiness: true,
                      sleep: false,
                      activity: true,
                      strain: false,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    // First open.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'initState must not access ModalRoute/inherited widgets');
    expect(find.text('Privacidade / Compartilhamento'), findsOneWidget);
    expect(find.text('Compartilhar com Comunidade Teste'), findsOneWidget);

    // Toggles reflect the constructor-passed scope.
    final readinessSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Readiness'),
    );
    expect(readinessSwitch.value, isTrue);

    // Navigate away and open again — re-initialization must stay correct.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'second open must not re-enter the lifecycle violation');
    expect(find.text('Privacidade / Compartilhamento'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Host extends StatelessWidget {
  const _Host({required this.onOpen});

  final void Function(BuildContext) onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => onOpen(context),
          child: const Text('Abrir privacidade'),
        ),
      ),
    );
  }
}
