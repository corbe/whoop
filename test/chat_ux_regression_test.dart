/// Chat UX regression tests (Social Phase).
///
/// Cobre os comportamentos que a aceitação manual sinalizou como frágeis:
/// - LONG PRESS abre o menu Responder/Reagir/Copiar (bloqueador);
/// - Copiar → SnackBar "Mensagem copiada";
/// - Responder → barra de reply acima do composer com o nome do remetente;
/// - nome real do remetente quando conhecido; "Membro" apenas p/ desconhecido;
/// - botão de emoji no composer insere emoji no texto (NÃO é reação);
/// - tap no preview de reply não crasha (scroll-to-original é no-op seguro).
library;

import 'dart:async';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart'
    show EmojiPicker;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

ChatMessage _msg({
  required String id,
  required String senderId,
  String senderName = '',
  String text = '',
  ChatReplyRef? replyTo,
}) {
  return ChatMessage(
    id: id,
    conversationId: _groupId,
    conversationType: 2,
    senderId: senderId,
    senderName: senderName,
    type: ChatMessageType.text,
    text: text,
    replyTo: replyTo,
    createdAt: DateTime(2026, 8, 16, 10, 0),
  );
}

class _FakeJuggleImService extends JuggleImService {
  final _messages = StreamController<ChatMessage>.broadcast();
  final _reactions =
      StreamController<({String messageId, String emoji, bool added})>.broadcast();

  List<ChatMessage> history = [];

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
      history;

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
    fake.history = [
      _msg(id: 'm1', senderId: 'wellness:other-1', text: 'Olá pessoal!'),
      _msg(
        id: 'm2',
        senderId: 'wellness:other-1',
        text: 'Bora treinar hoje?',
        replyTo: const ChatReplyRef(
          originalMessageId: 'm1',
          originalSenderId: 'wellness:other-1',
          originalSenderName: 'Maria',
          originalPreview: 'Olá pessoal!',
        ),
      ),
      _msg(id: 'm3', senderId: 'wellness:ghost-9', text: 'Sou um fantasma'),
    ];
  });

  testWidgets('long press on a message opens Reply/React/Copy sheet',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Olá pessoal!').first);
    await tester.pumpAndSettle();

    expect(find.text('Responder'), findsOneWidget);
    expect(find.text('Reagir'), findsOneWidget);
    expect(find.text('Copiar'), findsOneWidget);
  });

  testWidgets('copy shows "Mensagem copiada" feedback', (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Olá pessoal!').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copiar'));
    await tester.pumpAndSettle();

    expect(find.text('Mensagem copiada'), findsOneWidget);
  });

  testWidgets('reply shows target bar above the composer', (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Bora treinar hoje?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Responder'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Respondendo a Maria'), findsOneWidget);
  });

  testWidgets('known sender shows real name; unknown falls back to Membro',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    expect(find.text('Maria'), findsWidgets);
    expect(find.text('Membro'), findsWidgets);
    // Nenhum ID bruto pode aparecer.
    expect(find.textContaining('wellness:'), findsNothing);
    expect(find.textContaining('other-1'), findsNothing);
    expect(find.textContaining('ghost-9'), findsNothing);
  });

  testWidgets('emoji composer button opens the picker (insert, not reaction)',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Emoji na mensagem'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(EmojiPicker), findsOneWidget);
  });

  testWidgets('tapping a reply preview does not crash (scroll no-op safe)',
      (tester) async {
    await tester.pumpWidget(_app(fake));
    await tester.pumpAndSettle();

    // O preview de reply (2ª ocorrência) deve ser tocável sem crash.
    await tester.tap(find.textContaining('Olá pessoal!').at(1),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    // A tela continua íntegra.
    expect(find.byType(CommunityChatScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
