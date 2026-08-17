/// Testes do report app-side de mensagem enviada (push §19).
///
/// O backend só sabe de mensagens se o app reportar
/// (POST /wellness/chat/messages/sent/) — sem webhook no im-server.
/// Cobertura:
/// - sendText OK → POST com community_uuid + message_id + text;
/// - reply → POST com reply_to_message_id + reply_to_sender_id;
/// - send falho → NENHUM POST;
/// - report falho (500) → resultado do envio NÃO é afetado (fire-and-forget);
/// - conversa NÃO-grupo → nenhum POST;
/// - fromSend extrai o community_uuid do id "community:&lt;uuid&gt;".
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juggle_im/juggle_im.dart' show JuggleIm;
import 'package:juggle_im/model/conversation.dart' show Conversation, ConversationType;
import 'package:juggle_im/model/message.dart' show Message;

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/chat_controller.dart';
import 'package:noana_wellness_app/services/chat_push_reporter.dart';
import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';
import 'package:noana_wellness_app/shared/models/chat.dart';

class _FakeAuthService implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token-1';
  @override
  Future<String> getAccessToken() async => 'access-token-1';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatSessionService extends ChatSessionService {
  _FakeChatSessionService() : super(apiClient: _dummyApi());
  static ApiClient _dummyApi() => ApiClient(
        config: _config,
        auth: _FakeAuthService(),
        httpClient: MockClient((r) async => http.Response('{}', 200)),
      );

  @override
  Future<ChatSession> obtainSession() async => const ChatSession(
        userId: 'wellness:me',
        token: 'tok',
        wsUrl: 'wss://x',
        apiUrl: 'https://x',
        navUrl: 'https://x',
      );
}

const _config = AppConfig(
  environment: AppEnvironment.hml,
  cognitoPoolId: 'us-east-1_BFGyiLUlb',
  cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
  wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
  juggleApiUrl: 'https://juggleim-api.hml.noana.link',
  juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
  juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
);

class _FakeJuggle extends JuggleImService {
  _FakeJuggle() : super(sdk: _FakeSdk());
  bool failNextSend = false;

  @override
  ChatSession? get session =>
      const ChatSession(userId: 'wellness:me', token: 't', wsUrl: 'wss://x', apiUrl: 'https://x', navUrl: 'https://x');

  @override
  JuggleConnectionState get state => JuggleConnectionState.connected;

  @override
  Future<void> markConversationRead(String conversationId, int conversationType) async {}

  @override
  Future<SendResult> sendText(
    String conversationId,
    int conversationType,
    String text, {
    ChatReplyRef? replyTo,
  }) async {
    if (failNextSend) {
      failNextSend = false;
      return const SendResult(ok: false, errorCode: 13002);
    }
    final msg = Message(Conversation(conversationType, conversationId))
      ..messageId = 'final-1'
      ..senderUserId = 'wellness:me';
    return SendResult(ok: true, messageId: 'final-1', message: msg);
  }

  @override
  Future<List<ChatMessage>> loadHistory(
    String conversationId,
    int conversationType, {
    int count = 30,
    DateTime? before,
  }) async {
    return [];
  }

  @override
  ChatMessage mapMessage(Message m) => ChatMessage(
        id: m.messageId,
        conversationId: m.conversation.conversationId,
        conversationType: m.conversation.conversationType,
        type: ChatMessageType.text,
        text: 'mapped',
        senderId: 'wellness:me',
        createdAt: DateTime.now(),
      );

  @override
  Stream<ChatMessage> get messageStream => const Stream.empty();
  @override
  Stream<({String messageId, String emoji, bool added})> get reactionStream =>
      const Stream.empty();
}

class _FakeSdk implements JuggleIm {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final captured = <http.Request>[];

  ApiClient api({int status = 200}) => ApiClient(
        config: _config,
        auth: _FakeAuthService(),
        httpClient: MockClient((req) async {
          captured.add(req);
          return http.Response('{}', status);
        }),
      );

  setUp(captured.clear);

  ChatController makeController({
    required String conversationId,
    int conversationType = ConversationType.group,
    ApiClient? apiClient,
    _FakeJuggle? juggle,
  }) {
    return ChatController(
      juggle: juggle ?? _FakeJuggle(),
      chatSession: _FakeChatSessionService(),
      conversationId: conversationId,
      conversationType: conversationType,
      pushReporter: ChatPushReporter(apiClient: apiClient ?? api()),
    );
  }

  test('sendText OK → POST /wellness/chat/messages/sent/ com comunidade',
      () async {
    final controller =
        makeController(conversationId: 'community:abc-123');
    final result = await controller.sendText('mensagem A');
    await pumpEventQueue(); // report é fire-and-forget — deixa o POST sair
    expect(result.ok, isTrue);
    expect(captured, hasLength(1));
    final req = captured.single;
    expect(req.url.path, '/v1/wellness/chat/messages/sent/');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['community_uuid'], 'abc-123');
    expect(body['message_id'], 'final-1');
    expect(body['text'], 'mensagem A');
    expect(body.containsKey('reply_to_message_id'), isFalse);
    expect(body.containsKey('reply_to_sender_id'), isFalse);
  });

  test('reply → POST inclui reply_to_message_id + reply_to_sender_id',
      () async {
    final controller =
        makeController(conversationId: 'community:abc-123');
    controller.setReplyTarget(const ChatReplyRef(
      originalMessageId: 'orig-77',
      originalSenderId: 'wellness:9a1cbd7f',
      originalSenderName: 'Marcos',
      originalPreview: 'mensagem A',
    ));
    final result = await controller.sendText('resposta B');
    await pumpEventQueue();
    expect(result.ok, isTrue);
    final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
    expect(body['reply_to_message_id'], 'orig-77');
    expect(body['reply_to_sender_id'], 'wellness:9a1cbd7f');
  });

  test('send falho → NENHUM POST', () async {
    final juggle = _FakeJuggle()..failNextSend = true;
    final controller =
        makeController(conversationId: 'community:abc-123', juggle: juggle);
    final result = await controller.sendText('falha');
    expect(result.ok, isFalse);
    expect(captured, isEmpty);
  });

  test('report falho (500) NÃO afeta o resultado do envio', () async {
    final controller = makeController(
      conversationId: 'community:abc-123',
      apiClient: api(status: 500),
    );
    final result = await controller.sendText('mensagem A');
    await pumpEventQueue();
    expect(result.ok, isTrue);
    expect(result.messageId, 'final-1');
    expect(captured, hasLength(1)); // o POST foi tentado; falha engolida
  });

  test('conversa NÃO-grupo (1:1) → nenhum POST', () async {
    final controller = makeController(
      conversationId: 'user-x',
      conversationType: ConversationType.private,
    );
    final result = await controller.sendText('oi');
    expect(result.ok, isTrue);
    expect(captured, isEmpty);
  });

  test('fromSend extrai community_uuid do id community:<uuid>', () {
    final report = ChatMessageSentReport.fromSend(
      communityConversationId: 'community:7e973c05-43f0-450e-aafa-c5c3a15a3eae',
      finalMessageId: 'final-9',
      text: 'resposta B',
      replyTo: const ChatReplyRef(
        originalMessageId: 'orig-77',
        originalSenderId: 'wellness:9a1cbd7f',
        originalSenderName: 'Marcos',
        originalPreview: 'mensagem A',
      ),
    );
    expect(report.communityUuid, '7e973c05-43f0-450e-aafa-c5c3a15a3eae');
    expect(report.messageId, 'final-9');
    expect(report.replyToMessageId, 'orig-77');
    expect(report.replyToSenderId, 'wellness:9a1cbd7f');
  });
}
