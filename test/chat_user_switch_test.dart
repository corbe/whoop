/// User-switch ownership regression (BUG 1): trocar de conta NUNCA pode
/// reutilizar o userId da sessão Juggle anterior. A sessão é verificada
/// contra o usuário autenticado (obtainSession) a cada start().
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juggle_im/model/conversation.dart';
import 'package:juggle_im/model/message.dart';

import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/chat_controller.dart';
import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';
import 'package:noana_wellness_app/shared/models/chat.dart';

class _SwitchFakeJuggle extends JuggleImService {
  String? connectedUserId;
  int initializeCalls = 0;
  int resetCalls = 0;
  final _messages = StreamController<ChatMessage>.broadcast();

  @override
  ChatSession? get session => connectedUserId == null
      ? null
      : ChatSession(
          userId: connectedUserId!,
          token: 't-$connectedUserId',
          wsUrl: 'wss://x',
          apiUrl: 'https://x',
          navUrl: 'https://x',
        );

  @override
  JuggleConnectionState get state => connectedUserId == null
      ? JuggleConnectionState.disconnected
      : JuggleConnectionState.connected;

  @override
  Stream<ChatMessage> get messageStream => _messages.stream;

  @override
  Future<void> initializeAndConnect(ChatSession session) async {
    initializeCalls++;
    connectedUserId = session.userId;
  }

  @override
  Future<void> resetSession() async {
    resetCalls++;
    connectedUserId = null;
  }

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
  ChatMessage mapMessage(Message m) => throw UnimplementedError();

  @override
  Future<SendResult> sendText(
    String conversationId,
    int conversationType,
    String text, {
    ChatReplyRef? replyTo,
  }) async =>
      SendResult(ok: true, messageId: 'sdk-1');

  @override
  void dispose() {
    _messages.close();
  }
}

class _SwitchFakeSessionService extends ChatSessionService {
  _SwitchFakeSessionService() : super(apiClient: _dummyApi());

  /// Simula o backend: devolve a sessão do usuário DONO do token atual.
  String currentUserId = 'userA';

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
        auth: _SwitchFakeAuth(),
        httpClient: MockClient((r) async => http.Response('{}', 200)),
      );

  @override
  Future<ChatSession> obtainSession() async => ChatSession(
        userId: currentUserId,
        token: 't-$currentUserId',
        wsUrl: 'wss://x',
        apiUrl: 'https://x',
        navUrl: 'https://x',
      );
}

class _SwitchFakeAuth implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token';
  @override
  Future<String> getAccessToken() async => 'access-token';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatMessage _msg(String senderId, String id) => ChatMessage(
      id: id,
      conversationId: 'community:1',
      conversationType: ConversationType.group,
      senderId: senderId,
      type: ChatMessageType.text,
      text: 'msg-$id',
    );

void main() {
  late _SwitchFakeSessionService sessionService;
  late ProviderContainer container;

  _SwitchFakeJuggle juggle() =>
      container.read(juggleImServiceProvider) as _SwitchFakeJuggle;

  setUp(() {
    sessionService = _SwitchFakeSessionService();
    container = ProviderContainer(overrides: [
      // Factory (não value): invalidação cria uma instância NOVA, como no app.
      juggleImServiceProvider.overrideWith((ref) => _SwitchFakeJuggle()),
      chatSessionServiceProvider.overrideWithValue(sessionService),
    ]);
    addTearDown(container.dispose);
  });

  ChatController controllerFor() =>
      container.read(chatControllerProvider((
        conversationId: 'community:1',
        conversationType: ConversationType.group,
      )));

  test('A logado: sessão A, mensagens de A são MINE', () async {
    sessionService.currentUserId = 'userA';
    final controller = controllerFor();
    await controller.start();

    expect(controller.sessionUserId, 'userA');
    expect(juggle().connectedUserId, 'userA');

    final mine = _msg('userA', 'a1');
    expect(mine.senderId == controller.sessionUserId, isTrue);
    final other = _msg('userB', 'b1');
    expect(other.senderId == controller.sessionUserId, isFalse);
  });

  test('Troca A→B: sessão NOVA de B; mensagens de A viram OTHER', () async {
    sessionService.currentUserId = 'userA';
    final controller = controllerFor();
    await controller.start();
    expect(controller.sessionUserId, 'userA');

    // logout A + login B (mesmo processo): o start() seguinte deve
    // DETECTAR a divergência (userId A != B) e reobter a sessão de B.
    sessionService.currentUserId = 'userB';
    await controller.start();

    expect(juggle().resetCalls, greaterThanOrEqualTo(1),
        reason: 'sessão do usuário anterior deve ser descartada');
    expect(controller.sessionUserId, 'userB');
    expect(juggle().connectedUserId, 'userB');

    final aMsg = _msg('userA', 'a1');
    expect(aMsg.senderId == controller.sessionUserId, isFalse,
        reason: 'mensagem de A NÃO é mine para B');
    final bMsg = _msg('userB', 'b1');
    expect(bMsg.senderId == controller.sessionUserId, isTrue);
  });

  test('Troca B→A (volta): sessão de A novamente, B vira OTHER', () async {
    sessionService.currentUserId = 'userA';
    final controller = controllerFor();
    await controller.start();

    sessionService.currentUserId = 'userB';
    await controller.start();

    sessionService.currentUserId = 'userA';
    await controller.start();

    expect(controller.sessionUserId, 'userA');
    expect(juggle().connectedUserId, 'userA');
    expect(_msg('userA', 'a1').senderId == controller.sessionUserId, isTrue);
    expect(_msg('userB', 'b1').senderId == controller.sessionUserId, isFalse);
  });

  test('Mesmo usuário: start() NÃO reconecta nem reseta (streams preservados)',
      () async {
    sessionService.currentUserId = 'userA';
    final controller = controllerFor();
    await controller.start();
    final connects = juggle().initializeCalls;

    // Reabrir o chat com o MESMO usuário: mantém a conexão existente.
    await controller.start();
    expect(juggle().initializeCalls, connects);
    expect(juggle().resetCalls, 0);
  });

  test('Invalidar chatControllerProvider descarta o estado antigo da conta',
      () async {
    sessionService.currentUserId = 'userA';
    final controller = controllerFor();
    await controller.start();
    await controller.sendText('ola');
    expect(controller.current.messages, isNotEmpty);

    // Logout: invalidação dos providers keepAlive (o app faz isso no
    // statusStream unauthenticated — chat E juggle).
    container.invalidate(chatControllerProvider);
    container.invalidate(juggleImServiceProvider);

    final fresh = controllerFor();
    expect(fresh.current.messages, isEmpty,
        reason: 'novo controller não herda mensagens da conta anterior');
    expect(fresh.sessionUserId, isNull,
        reason: 'sessão anterior não deve sobreviver à invalidação');
  });
}
