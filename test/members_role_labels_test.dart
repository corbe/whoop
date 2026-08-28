/// BUG 3 regression: Members tab role labels (Social Phase UX).
///
/// Membro comum NÃO exibe rótulo de papel redundante ("Membro"); admin →
/// "Administrador"; owner → "Dono". Nunca renderizar role/status crus
/// (ex.: "member • active"), UUIDs ou IDs Juggle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/features/communities/community_detail_screen.dart';
import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/community_providers.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';
import 'package:noana_wellness_app/services/reaction_providers.dart';
import 'package:noana_wellness_app/services/wellness_identity_providers.dart';
import 'package:noana_wellness_app/shared/models/chat.dart';
import 'package:noana_wellness_app/shared/models/community.dart';
import 'package:noana_wellness_app/shared/models/wellness_identity.dart';

const _communityUuid = 'c1';

Community _community() => Community(
      uuid: _communityUuid,
      name: 'Comunidade Teste',
      // Membro ATIVO: o teste valida os rótulos de papel na aba Membros.
      // (Não-membros agora veem placeholder "Entre na comunidade para
      // visualizar." — política Community Access & Privacy.)
      currentUserRole: 'member',
      currentUserStatus: 'active',
    );

/// Fixture NÃO-membro para o teste do back button: sem o stack real de chat
/// (que monta um segundo AppBar/BackButton), o finder permanece único.
Community _communityNonMember() => Community(
      uuid: _communityUuid,
      name: 'Comunidade Teste',
      currentUserRole: null,
      currentUserStatus: null,
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

class _FakeJuggleImService extends JuggleImService {
  @override
  ChatSession? get session => null;

  @override
  JuggleConnectionState get state => JuggleConnectionState.disconnected;

  @override
  Stream<ChatMessage> get messageStream => const Stream.empty();

  @override
  Stream<({String messageId, String emoji, bool added})> get reactionStream =>
      const Stream.empty();

  @override
  Future<void> initializeAndConnect(ChatSession session) async {}

  @override
  Future<void> disconnect() async {}
}

class _FakeChatSessionService extends ChatSessionService {
  _FakeChatSessionService() : super(apiClient: _dummyApi());

  static ApiClient _dummyApi() => ApiClient(
        config: const AppConfig(
          environment: AppEnvironment.hml,
          wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
          juggleApiUrl: 'https://juggleim-api.hml.noana.link',
          juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
          juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
        ),
        auth: _FakeAuthService(),
        httpClient: MockClient((r) async => http.Response('{}', 200)),
      );

  @override
  Future<ChatSession> obtainSession() async => const ChatSession(
        userId: 'wellness:me',
        token: 't',
        wsUrl: 'wss://x',
        apiUrl: 'https://x',
        navUrl: 'https://x',
      );
}

class _FakeAuthService implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token-1';

  @override
  Future<String> getAccessToken() async => 'access-token-1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
      juggleImServiceProvider.overrideWithValue(_FakeJuggleImService()),
      chatSessionServiceProvider.overrideWithValue(_FakeChatSessionService()),
    ],
    child: const MaterialApp(
      home: CommunityDetailScreen(uuid: _communityUuid),
    ),
  );
}

class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const CommunityDetailScreen(uuid: _communityUuid),
            ),
          ),
          child: const Text('Host inicial'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('normal member has NO role label; privileged roles shown',
      (tester) async {
    await tester.pumpWidget(_app());
    // Membro ativo: o Chat tab (índice 0) tem animações contínuas — usar
    // pumps limitados, nunca pumpAndSettle.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // Aba Membros (Chat é a aba 0; Membros é a 3 — TabBar rolável).
    await tester.ensureVisible(find.text('Membros'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Membros'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

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

  testWidgets('Community AppBar has a back button that pops to the previous '
      'screen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        communityDetailProvider
            .overrideWith((ref, uuid) async => _communityNonMember()),
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
        juggleImServiceProvider.overrideWithValue(_FakeJuggleImService()),
        chatSessionServiceProvider.overrideWithValue(_FakeChatSessionService()),
      ],
      child: const MaterialApp(home: _Host()),
    ));
    // Pumps limitados (o chat do membro ativo tem animações contínuas).
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // Entra na comunidade via Navigator stack (como o app faz). Espera a
    // transição terminar sem pumpAndSettle (animação contínua do chat).
    await tester.tap(find.text('Host inicial'));
    await _pumpUntilFound(tester, find.byType(CommunityDetailScreen));

    // AppBar: seta de volta + título com o NOME da comunidade.
    expect(find.byType(BackButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Comunidade Teste'),
      ),
      findsOneWidget,
      reason: 'o título da AppBar deve ser o nome da comunidade',
    );

    // Voltar → retorna ao host (a lista anterior), não reconstrói nada.
    await tester.tap(find.byType(BackButton));
    await _pumpUntilGone(tester, find.byType(CommunityDetailScreen));
    expect(find.text('Host inicial'), findsOneWidget);
    expect(find.byType(CommunityDetailScreen), findsNothing);
  });
}

/// Pumpa frames até o finder encontrar algo (ou timeout). Necessário porque
/// o Chat tab do membro ativo mantém animações contínuas — pumpAndSettle
/// nunca estabiliza.
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('timeout esperando por $finder');
}

Future<void> _pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
  }
  fail('timeout esperando sumir $finder');
}
