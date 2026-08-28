/// Community Access & Privacy — widget tests (2026-08-28).
///
/// Cobre a decisão de produto:
/// - NÃO-membro NUNCA vê o bloco COMPARTILHAMENTO / Código de entrada
///   (o backend já sanitiza; a UI também não renderiza);
/// - owner/admin de public_code VEEM o código + botão copiar;
/// - membro comum NÃO vê o código (credencial restrita a owner/admin);
/// - abas internas (Ranking/Desafios/Membros) mostram placeholder para
///   não-membros e NÃO disparam requests.
library;

import 'dart:async';

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
const _secretCode = 'SECRET-XYZ';

/// Código de entrada que NUNCA deve aparecer na tela para não autorizados.
Community _community({
  required String visibility,
  required String? role,
  required String? status,
  String joinCode = _secretCode,
}) =>
    Community(
      uuid: _communityUuid,
      name: 'Comunidade Teste',
      visibility: visibility,
      joinCode: joinCode,
      memberCount: 2,
      currentUserRole: role,
      currentUserStatus: status,
    );

class _FakeJuggleImService extends JuggleImService {
  final _messages = StreamController<ChatMessage>.broadcast();
  final _reactions =
      StreamController<({String messageId, String emoji, bool added})>.broadcast();

  @override
  ChatSession? get session => null;

  @override
  JuggleConnectionState get state => JuggleConnectionState.disconnected;

  @override
  Stream<ChatMessage> get messageStream => _messages.stream;

  @override
  Stream<({String messageId, String emoji, bool added})> get reactionStream =>
      _reactions.stream;

  @override
  Future<void> initializeAndConnect(ChatSession session) async {}

  @override
  Future<void> disconnect() async {}

  @override
  void dispose() {
    _messages.close();
    _reactions.close();
  }
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

class _FakePersonNotifier extends CurrentWellnessPersonNotifier {
  @override
  Future<WellnessPerson?> build() async =>
      const WellnessPerson(uuid: 'person-1', cognitoSub: 'sub-1');
}

List<CommunityMember> _members() => const [
      CommunityMember(
        personUuid: 'person-1',
        displayName: 'Ana',
        role: 'member',
        status: 'active',
      ),
    ];

Future<ProviderScope> _app(Community community) async {
  final fake = _FakeJuggleImService();
  return ProviderScope(
    overrides: [
      communityDetailProvider.overrideWith((ref, uuid) async => community),
      communityMembersProvider.overrideWith((ref, uuid) async => _members()),
      communityNotificationPreferenceProvider
          .overrideWith((ref, uuid) async => 'default'),
      currentWellnessPersonProvider.overrideWith(() => _FakePersonNotifier()),
      reactionCatalogProvider.overrideWith(
        (ref) async => const ReactionCatalog(reactions: [], quick: ['❤️', '👍']),
      ),
      juggleImServiceProvider.overrideWithValue(fake),
      chatSessionServiceProvider.overrideWithValue(_FakeChatSessionService()),
    ],
    child: const MaterialApp(
      home: CommunityDetailScreen(uuid: _communityUuid),
    ),
  );
}

Future<void> _openOverview(WidgetTester tester) async {
  // NUNCA pumpAndSettle aqui: para membros o Chat tab (índice 0) monta
  // CommunityChatScreen com animações contínuas → pumpAndSettle estouraria.
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  // Aba Visão geral (última do TabBar rolável). Não-membros já caem nela
  // via auto-jump; membros navegam manualmente.
  await tester.ensureVisible(find.text('Visão geral'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('Visão geral'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('non-member: NUNCA vê código; vê label "Acesso por código" + Entrar',
      (tester) async {
    await tester.pumpWidget(await _app(_community(
      visibility: 'public_code',
      role: null,
      status: null,
    )));
    await _openOverview(tester);

    // Label novo (nomenclatura): "Acesso por código".
    expect(find.textContaining('Acesso por código'), findsOneWidget);
    expect(find.textContaining('Código público'), findsNothing);

    // Bloco COMPARTILHAMENTO e o código NÃO aparecem para não-membro.
    expect(find.text('COMPARTILHAMENTO'), findsNothing);
    expect(find.text('Código de entrada'), findsNothing);
    expect(find.text(_secretCode), findsNothing,
        reason: 'não-membro não pode ver o código de entrada');
    expect(find.byIcon(Icons.copy), findsNothing);

    // Botão Entrar visível (fluxo de entrada preservado).
    expect(find.text('Entrar'), findsOneWidget);
  });

  testWidgets('non-member: abas internas mostram placeholder, sem requests',
      (tester) async {
    await tester.pumpWidget(await _app(_community(
      visibility: 'public_code',
      role: null,
      status: null,
    )));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // Aba Membros (índice 3) → placeholder, não a lista.
    await tester.ensureVisible(find.text('Membros'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Membros'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Entre na comunidade para visualizar.'), findsOneWidget);
    // Nenhum membro real renderizado (não disparou a listagem).
    expect(find.text('Ana'), findsNothing);
  });

  testWidgets('owner de public_code vê código + botão copiar', (tester) async {
    await tester.pumpWidget(await _app(_community(
      visibility: 'public_code',
      role: 'owner',
      status: 'active',
    )));
    await _openOverview(tester);

    expect(find.text('COMPARTILHAMENTO'), findsOneWidget);
    expect(find.text('Código de entrada'), findsOneWidget);
    expect(find.text(_secretCode), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });

  testWidgets('admin de public_code vê código + botão copiar', (tester) async {
    await tester.pumpWidget(await _app(_community(
      visibility: 'public_code',
      role: 'admin',
      status: 'active',
    )));
    await _openOverview(tester);

    expect(find.text('COMPARTILHAMENTO'), findsOneWidget);
    expect(find.text(_secretCode), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });

  testWidgets('membro comum NÃO vê código (credencial owner/admin)',
      (tester) async {
    await tester.pumpWidget(await _app(_community(
      visibility: 'public_code',
      role: 'member',
      status: 'active',
    )));
    await _openOverview(tester);

    expect(find.text('COMPARTILHAMENTO'), findsNothing);
    expect(find.text('Código de entrada'), findsNothing);
    expect(find.text(_secretCode), findsNothing);
    expect(find.byIcon(Icons.copy), findsNothing);
    // Membro vê "Sair da comunidade", não "Entrar".
    expect(find.text('Sair da comunidade'), findsOneWidget);
  });

  testWidgets('owner de invite_only não vê código (mecanismo é public_code)',
      (tester) async {
    await tester.pumpWidget(await _app(_community(
      visibility: 'invite_only',
      role: 'owner',
      status: 'active',
      joinCode: 'LEGACY-CODE',
    )));
    await _openOverview(tester);

    expect(find.text('COMPARTILHAMENTO'), findsNothing);
    expect(find.text('LEGACY-CODE'), findsNothing);
    expect(find.textContaining('Somente convite'), findsOneWidget);
  });
}
