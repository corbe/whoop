/// BUG 3 regression: Members tab role labels (Social Phase UX).
///
/// Membro comum NÃO exibe rótulo de papel redundante ("Membro"); admin →
/// "Administrador"; owner → "Dono". Nunca renderizar role/status crus
/// (ex.: "member • active"), UUIDs ou IDs Juggle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/features/communities/community_detail_screen.dart';
import 'package:noana_wellness_app/services/community_providers.dart';
import 'package:noana_wellness_app/services/reaction_providers.dart';
import 'package:noana_wellness_app/services/wellness_identity_providers.dart';
import 'package:noana_wellness_app/shared/models/chat.dart';
import 'package:noana_wellness_app/shared/models/community.dart';
import 'package:noana_wellness_app/shared/models/wellness_identity.dart';

const _communityUuid = 'c1';

Community _community() => Community(
      uuid: _communityUuid,
      name: 'Comunidade Teste',
      // Não-membro: a UI pula automaticamente do Chat para a Visão geral,
      // evitando montar o stack real de chat no teste.
      currentUserRole: 'member',
      currentUserStatus: 'left',
    );

List<CommunityMember> _members() => const [
      CommunityMember(
        personUuid: 'person-1',
        displayName: 'Daniel',
        role: 'member',
        status: 'active',
      ),
      CommunityMember(
        personUuid: 'person-2',
        displayName: 'Maria',
        role: 'admin',
        status: 'active',
      ),
      CommunityMember(
        personUuid: 'person-3',
        displayName: 'João',
        role: 'owner',
        status: 'active',
      ),
    ];

class _FakePersonNotifier extends CurrentWellnessPersonNotifier {
  @override
  Future<WellnessPerson?> build() async => const WellnessPerson(
        uuid: 'person-1',
        cognitoSub: 'sub-1',
        displayName: 'Daniel',
      );
}

Widget _app() {
  return ProviderScope(
    overrides: [
      communityDetailProvider.overrideWith((ref, uuid) async => _community()),
      communityMembersProvider.overrideWith((ref, uuid) async => _members()),
      communityNotificationPreferenceProvider
          .overrideWith((ref, uuid) async => 'default'),
      currentWellnessPersonProvider.overrideWith(() => _FakePersonNotifier()),
      reactionCatalogProvider.overrideWith(
        (ref) async => const ReactionCatalog(
          reactions: [],
          quick: ['❤️', '👍'],
        ),
      ),
    ],
    child: const MaterialApp(
      home: CommunityDetailScreen(uuid: _communityUuid),
    ),
  );
}

void main() {
  testWidgets('normal member has NO role label; privileged roles shown',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Aba Membros (Chat é a aba 0; Membros é a 3 — TabBar rolável).
    await tester.ensureVisible(find.text('Membros'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Membros'));
    await tester.pumpAndSettle();

    // Identidade real, sem rótulo redundante para membro comum.
    expect(find.text('Daniel'), findsOneWidget);
    expect(find.text('Membro'), findsNothing,
        reason: 'membro comum não pode exibir rótulo de papel redundante');

    // Papéis privilegiados com rótulos PT.
    expect(find.text('Maria'), findsOneWidget);
    expect(find.text('Administrador'), findsOneWidget);
    expect(find.text('João'), findsOneWidget);
    expect(find.text('Dono'), findsOneWidget);

    // Nada de role/status crus, UUID ou IDs.
    expect(find.textContaining('•'), findsNothing);
    expect(find.textContaining('member'), findsNothing);
    expect(find.textContaining('active'), findsNothing);
    expect(find.textContaining('person-'), findsNothing);
    expect(find.textContaining('wellness:'), findsNothing);
    expect(find.textContaining('11111111'), findsNothing);
  });
}
