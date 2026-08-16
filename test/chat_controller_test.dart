/// Phase 6 chat controller + notification preference tests (spec §64–§65).
///
/// Uses a FakeJuggleImService — no real network/SDK in unit tests.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juggle_im/model/conversation.dart';
import 'package:juggle_im/model/message.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/chat_controller.dart';
import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/community_service.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';
import 'package:noana_wellness_app/shared/models/chat.dart';

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
        userId: 'wellness:me',
        token: 'tok',
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

class FakeJuggleImService extends JuggleImService {
  final _msgController = StreamController<ChatMessage>.broadcast();
  final _reactionController =
      StreamController<({String messageId, String emoji, bool added})>.broadcast();

  List<ChatMessage> historyPage = [];
  int historyCalls = 0;
  final sentTexts = <String>[];
  final sentReplyIds = <String?>[];
  bool failNextSend = false;
  int markedRead = 0;
  final reactions = <String, List<ChatReaction>>{};
  ChatMessage? _lastMapped;

  @override
  ChatSession? get session =>
      const ChatSession(
          userId: 'wellness:me',
          token: 't',
          wsUrl: 'wss://x',
          apiUrl: 'https://x',
          navUrl: 'https://x');

  @override
  JuggleConnectionState get state => JuggleConnectionState.connected;

  @override
  Stream<ChatMessage> get messageStream => _msgController.stream;

  @override
  Stream<({String messageId, String emoji, bool added})> get reactionStream =>
      _reactionController.stream;

  @override
  Future<void> initializeAndConnect(ChatSession session) async {}

  @override
  Future<void> markConversationRead(String conversationId, int conversationType) async {
    markedRead++;
  }

  @override
  Future<List<ChatMessage>> loadHistory(
    String conversationId,
    int conversationType, {
    int count = 30,
    DateTime? before,
  }) async {
    historyCalls++;
    return historyPage;
  }

  @override
  ChatMessage mapMessage(Message m) => _lastMapped!;

  Message _dummySdkMessage(String id) =>
      Message(Conversation(2, 'grp1'))..messageId = id;

  @override
  Future<SendResult> sendText(
    String conversationId,
    int conversationType,
    String text, {
    ChatReplyRef? replyTo,
  }) async {
    sentTexts.add(text);
    sentReplyIds.add(replyTo?.originalMessageId);
    if (failNextSend) {
      failNextSend = false;
      return const SendResult(ok: false, errorCode: 1);
    }
    final msg = _makeMessage('sdk-${sentTexts.length}', text, replyTo);
    _lastMapped = msg;
    _msgController.add(msg);
    return SendResult(ok: true, messageId: msg.id, message: _dummySdkMessage(msg.id));
  }

  @override
  Future<bool> addReaction(String messageId, String conversationId, String emoji) async {
    _reactionController.add((messageId: messageId, emoji: emoji, added: true));
    return true;
  }

  @override
  Future<bool> removeReaction(String messageId, String conversationId, String emoji) async {
    _reactionController.add((messageId: messageId, emoji: emoji, added: false));
    return true;
  }

  @override
  Future<Map<String, List<ChatReaction>>> getReactions(
    List<String> messageIds,
    String conversationId,
  ) async => reactions;

  ChatMessage _makeMessage(String id, String text, ChatReplyRef? replyTo) {
    return ChatMessage(
      id: id,
      conversationId: 'grp1',
      conversationType: 2,
      senderId: 'wellness:me',
      senderName: 'Você',
      type: ChatMessageType.text,
      text: text,
      replyTo: replyTo,
      createdAt: DateTime.now(),
    );
  }

  void emitIncoming(ChatMessage message) => _msgController.add(message);

  void emitReaction(String messageId, String emoji, {required bool added}) =>
      _reactionController.add((messageId: messageId, emoji: emoji, added: added));

  @override
  void dispose() {
    _msgController.close();
    _reactionController.close();
  }
}

ChatController _controller(FakeJuggleImService fake) => ChatController(
      juggle: fake,
      chatSession: _FakeChatSessionService(),
      conversationId: 'grp1',
      conversationType: 2,
    );

ChatMessage _msg(String id, String text) => ChatMessage(
      id: id,
      conversationId: 'grp1',
      conversationType: 2,
      senderId: 'wellness:x',
      senderName: 'Ana',
      type: ChatMessageType.text,
      text: text,
      createdAt: DateTime(2026, 8, 13, 10, 0),
    );

void main() {
  group('ChatController', () {
    test('loads initial history page', () async {
      final fake = FakeJuggleImService();
      fake.historyPage = [_msg('m1', 'Treino amanhã?')];
      final controller = _controller(fake);
      await controller.start();
      expect(controller.current.messages, hasLength(1));
      expect(controller.current.initialLoading, isFalse);
      expect(fake.historyCalls, 1);
      controller.dispose();
    });

    test('realtime incoming message is deduped (spec §51)', () async {
      final fake = FakeJuggleImService();
      final controller = _controller(fake);
      await controller.start();
      // history + realtime com o MESMO id → 1 cópia
      fake.emitIncoming(_msg('m1', 'hello'));
      fake.emitIncoming(_msg('m1', 'hello'));
      fake.emitIncoming(_msg('m2', 'world'));
      await pumpEventQueue();
      expect(
        controller.current.messages.where((m) => m.id == 'm1').length,
        1,
      );
      expect(controller.current.messages, hasLength(2));
      controller.dispose();
    });

    test('send text is optimistic then finalized (spec §49)', () async {
      final fake = FakeJuggleImService();
      final controller = _controller(fake);
      await controller.start();
      final future = controller.sendText('oi');
      // otimista: bubble local pendente aparece antes do ack
      expect(controller.current.messages.any((m) => m.localPending), isTrue);
      await future;
      final sent = controller.current.messages
          .where((m) => m.id.startsWith('sdk-'))
          .toList();
      expect(sent, hasLength(1));
      expect(sent.first.deliveryStatus, ChatMessageStatus.sent);
      expect(controller.current.messages.any((m) => m.localPending), isFalse);
      controller.dispose();
    });

    test('failed send keeps failed bubble + retry works', () async {
      final fake = FakeJuggleImService();
      final controller = _controller(fake);
      await controller.start();
      fake.failNextSend = true;
      await controller.sendText('vai falhar');
      final failed = controller.current.messages
          .where((m) => m.deliveryStatus == ChatMessageStatus.failed);
      expect(failed, hasLength(1));
      await controller.retryFailed(failed.first);
      expect(
        controller.current.messages
            .where((m) => m.deliveryStatus == ChatMessageStatus.sent),
        isNotEmpty,
      );
      controller.dispose();
    });

    test('send with reply sets reply reference + clears composer state', () async {
      final fake = FakeJuggleImService();
      final controller = _controller(fake);
      await controller.start();
      controller.setReplyTarget(ChatReplyRef(
        originalMessageId: 'm1',
        originalSenderId: 'wellness:x',
        originalSenderName: 'Ana',
        originalPreview: 'Treino amanhã?',
      ));
      expect(controller.current.replyTarget, isNotNull);
      await controller.sendText('Sim!');
      expect(fake.sentReplyIds, ['m1']);
      expect(controller.current.replyTarget, isNull); // spec §8: limpa após enviar
      controller.dispose();
    });

    test('reaction add/remove events update message state', () async {
      final fake = FakeJuggleImService();
      fake.historyPage = [_msg('m1', 'olá')];
      final controller = _controller(fake);
      await controller.start();
      fake.emitReaction('m1', '🔥', added: true);
      fake.emitReaction('m1', '🔥', added: true);
      fake.emitReaction('m1', '🔥', added: false);
      await pumpEventQueue();
      final m1 = controller.current.messages.firstWhere((m) => m.id == 'm1');
      final fire = m1.reactions.firstWhere((r) => r.emoji == '🔥');
      expect(fire.count, 1);
      controller.dispose();
    });

    test('mark read called when conversation opens (spec §23)', () async {
      final fake = FakeJuggleImService();
      final controller = _controller(fake);
      await controller.start();
      expect(fake.markedRead, greaterThanOrEqualTo(1));
      controller.dispose();
    });

    test('pagination loads older on demand (spec §50)', () async {
      final fake = FakeJuggleImService();
      // Página 1 com 30 msgs → hasMore=true; página 2 adiciona 1 mais antiga.
      fake.historyPage =
          List.generate(30, (i) => _msg('m$i', 'msg $i'));
      final controller = _controller(fake);
      await controller.start();
      expect(controller.current.hasMore, isTrue);
      fake.historyPage = [_msg('m-old', 'mais antiga')];
      await controller.loadOlder();
      await pumpEventQueue();
      expect(fake.historyCalls, 2);
      expect(controller.current.messages, hasLength(31));
      expect(controller.current.messages.first.id, 'm-old');
      controller.dispose();
    });
  });

  group('Notification preferences (spec §65)', () {
    test('loads preference from backend', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path,
            '/v1/wellness/communities/c1/notification-preferences/');
        return http.Response('{"mode":"mentions_only"}', 200,
            headers: {'content-type': 'application/json'});
      });
      final service = CommunityService(apiClient: _apiWith(mock));
      expect(await service.getNotificationPreference('c1'), 'mentions_only');
    });

    test('persists preference change', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path,
            '/v1/wellness/communities/c1/notification-preferences/');
        return http.Response('{"mode":"muted"}', 200,
            headers: {'content-type': 'application/json'});
      });
      final service = CommunityService(apiClient: _apiWith(mock));
      expect(await service.updateNotificationPreference('c1', 'muted'), 'muted');
    });

    test('error surfaces as ApiException', () async {
      final mock = MockClient(
          (request) async => http.Response('{"detail":"no"}', 403));
      final service = CommunityService(apiClient: _apiWith(mock));
      expect(
        service.updateNotificationPreference('c1', 'muted'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}

ApiClient _apiWith(MockClient mock) {
  return ApiClient(
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
    httpClient: mock,
  );
}
