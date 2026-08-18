/// Widget regression: _send() lifecycle em CommunityChatScreen (fix
/// 2026-08-17, Bug B).
///
/// Bug: `_send()` aguardava `_controller.sendText(text)` (que no Android
/// pode levar ~15-30s entre gate de conexão e timeout) e DEPOIS chamava
/// `_messageController.clear()` SEM checar `mounted` — se o usuário navegava
/// (back/tab) durante o await, o State era descartado e o clear() estourava
/// "A TextEditingController was used after being disposed".
///
/// Fix: `if (!mounted) return;` após o await + `clear()` SÓ no sucesso
/// (falha preserva o texto digitado; o bubble falho com retry permanece).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juggle_im/model/conversation.dart';
import 'package:juggle_im/model/message.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/features/communities/community_chat_screen.dart';
import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/community_providers.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';
import 'package:noana_wellness_app/services/reaction_providers.dart';
import 'package:noana_wellness_app/services/wellness_identity_providers.dart';
import 'package:noana_wellness_app/shared/models/chat.dart';
import 'package:noana_wellness_app/shared/models/community.dart';
import 'package:noana_wellness_app/shared/models/wellness_identity.dart';

const _communityUuid = 'c1';
const _groupId = 'community:c1';

/// Juggle fake com sendText CONTROLÁVEL (Completer): o teste decide QUANDO
/// e COM QUE resultado o envio completa — necessário para simular o widget
/// sendo descartado durante o await.
class _FakeJuggleImService extends JuggleImService {
  final _messages = StreamController<ChatMessage>.broadcast();
  final _reactions =
      StreamController<({String messageId, String emoji, bool added})>.broadcast();

  Completer<SendResult>? sendCompleter;
  int sendCalls = 0;

  @override
  ChatSession? get session => const ChatSession(
        userId: 'wellness:person-1',
        token: 't',
        wsUrl: 'wss://x',
        apiUrl: 'https://x',
        navUrl: 'https://x',
      );

  @override
  JuggleConnectionState get state => JuggleConnectionState.connected;

  @override
  Stream<ChatMessage> get messageStream => _messages.stream;

  @override
  Stream<({String messageId, String emoji, bool added})> get reactionStream =>
      _reactions.stream;

  @override
  Future<void> initializeAndConnect(ChatSession session) async {}

  @override
  Future<void> markConversationRead(String conversationId, int conversationType) async {}

  @override
  Future<List<ChatMessage>> loadHistory(
    String conversationId,
    int conversationType, {
    int count = 30,
    DateTime? before,
  }) async =>
      [];

  @override
  ChatMessage mapMessage(Message m) => ChatMessage(
        id: m.messageId,
        conversationId: _groupId,
        conversationType: 2,
        senderId: 'wellness:person-1',
        senderName: 'Ana',
        type: ChatMessageType.text,
        text: 'oi',
        createdAt: DateTime.now(),
      );

  @override
  Future<SendResult> sendText(
    String conversationId,
    int conversationType,
    String text, {
    ChatReplyRef? replyTo,
  }) {
    sendCalls++;
    sendCompleter ??= Completer<SendResult>();
    return sendCompleter!.future;
  }

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
          cognitoPoolId: 'us-east-1_BFGyiLUlb',
          cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
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
        userId: 'wellness:person-1',
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
      CommunityMember(
        personUuid: 'other-1',
        displayName: 'Maria',
        role: 'member',
        status: 'active',
      ),
    ];

Widget _app(_FakeJuggleImService fake) {
  return ProviderScope(
    overrides: [
      juggleImServiceProvider.overrideWithValue(fake),
      chatSessionServiceProvider.overrideWithValue(_FakeChatSessionService()),
      communityMembersProvider.overrideWith((ref, uuid) async => _members()),
      currentWellnessPersonProvider.overrideWith(() => _FakePersonNotifier()),
      reactionCatalogProvider.overrideWith(
        (ref) async => const ReactionCatalog(
          reactions: [],
          quick: ['❤️', '👍', '🔥', '😂', '💪'],
        ),
      ),
    ],
    child: MaterialApp(
      home: CommunityChatScreen(
        communityName: 'Comunidade Teste',
        communityUuid: _communityUuid,
        groupId: _groupId,
      ),
    ),
  );
}

void main() {
  late _FakeJuggleImService fake;

  setUp(() {
    fake = _FakeJuggleImService();
  });

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('A) envio com sucesso com o widget montado → limpa o composer',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await typeAndSend(tester, 'oi');
    expect(fieldText(tester), 'oi', reason: 'pré-condição: texto no campo');

    fake.sendCompleter!.complete(SendResult(
      ok: true,
      messageId: 'sdk-1',
      errorCode: 0,
      message: Message(Conversation(2, _groupId))..messageId = 'sdk-1',
    ));
    await tester.pumpAndSettle();

    expect(fieldText(tester), isEmpty,
        reason: 'sucesso deve limpar o composer');
    expect(fake.sendCalls, 1, reason: 'envio exatamente uma vez');
    expect(tester.takeException(), isNull);
  });

  testWidgets('B) envio falho com o widget montado → texto preservado + retry',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await typeAndSend(tester, 'mensagem que falha');
    fake.sendCompleter!.complete(const SendResult(ok: false, errorCode: -1));
    await tester.pumpAndSettle();

    expect(fieldText(tester), 'mensagem que falha',
        reason: 'falha deve PRESERVAR o texto no composer');
    expect(find.text('Tentar'), findsOneWidget,
        reason: 'estado de falha visível para retry');
    expect(tester.takeException(), isNull);
  });

  testWidgets('C) widget descartado durante await de SUCESSO → sem exceção',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await typeAndSend(tester, 'oi');
    expect(fake.sendCompleter, isNotNull, reason: 'envio iniciado');

    // Usuário navega para trás enquanto o envio está pendente → dispose.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    fake.sendCompleter!.complete(SendResult(
      ok: true,
      messageId: 'sdk-1',
      errorCode: 0,
      message: Message(Conversation(2, _groupId))..messageId = 'sdk-1',
    ));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'completar o envio após o dispose NÃO pode tocar o controller');
  });

  testWidgets('D) widget descartado durante await de FALHA → sem exceção',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await typeAndSend(tester, 'oi');
    expect(fake.sendCompleter, isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    fake.sendCompleter!.complete(const SendResult(ok: false, errorCode: -1));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'falha após dispose também não pode estourar');
  });
}
