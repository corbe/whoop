/// Regression: Community "Chat" tab must actually mount the chat UI.
///
/// Reproduces the real Android runtime failure: tapping the Chat tab in a
/// community did NOTHING (no chat UI, no loading, no error). Root cause:
/// CommunityDetailScreen created `TabController(length: 4)` while the TabBar
/// has FIVE tabs (Visão geral / Leaderboard / Desafios / Membros / Chat) —
/// the Chat tab sits at index 4, out of range for a length-4 controller, so
/// `TabController.animateTo(4)` hits `assert(value < length)` and the tap is
/// silently dropped (debug) or clamps to the last valid tab (release).
///
/// This test drives the SAME widget path as the app: CommunityDetailScreen →
/// Chat tab → CommunityChatScreen, with the community's deterministic group id
/// (`community:<uuid>`) propagated, and asserts no exception + real chat UI
/// (loading/empty/composer) is visible.
library;

import 'dart:async';

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
import 'package:noana_wellness_app/features/communities/community_detail_screen.dart';
import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/community_providers.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';
import 'package:noana_wellness_app/services/challenge_providers.dart';
import 'package:noana_wellness_app/services/score_providers.dart';
import 'package:noana_wellness_app/services/wellness_identity_providers.dart';
import 'package:noana_wellness_app/shared/models/challenge.dart';
import 'package:noana_wellness_app/shared/models/chat.dart';
import 'package:noana_wellness_app/shared/models/community.dart';
import 'package:noana_wellness_app/shared/models/score.dart';
import 'package:noana_wellness_app/shared/models/wellness_identity.dart';

/// Fake JuggleIM layer — connected, empty history, records what was called.
class _FakeJuggleImService extends JuggleImService {
  final _messages = StreamController<ChatMessage>.broadcast();
  final _reactions =
      StreamController<({String messageId, String emoji, bool added})>.broadcast();

  List<ChatMessage> history = [];
  int historyCalls = 0;
  int markReadCalls = 0;
  final sentTexts = <String>[];

  @override
  ChatSession? get session => const ChatSession(
        userId: 'wellness:me',
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
  Future<void> markConversationRead(String conversationId, int conversationType) async {
    markReadCalls++;
  }

  @override
  Future<List<ChatMessage>> loadHistory(
    String conversationId,
    int conversationType, {
    int count = 30,
    DateTime? before,
  }) async {
    historyCalls++;
    return history;
  }

  @override
  ChatMessage mapMessage(Message m) => throw UnimplementedError();

  @override
  Future<SendResult> sendText(
    String conversationId,
    int conversationType,
    String text, {
    ChatReplyRef? replyTo,
  }) async {
    sentTexts.add(text);
    return SendResult(ok: true, messageId: 'sdk-1');
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

const _communityUuid = 'c1';
const _expectedGroupId = 'community:c1';

Community _community() => Community(
      uuid: _communityUuid,
      name: 'Comunidade Teste',
      currentUserRole: 'member',
      currentUserStatus: 'active',
    );

List<CommunityMember> _members() => const [
      CommunityMember(
        personUuid: 'person-1',
        displayName: 'Ana',
        role: 'member',
        status: 'active',
      ),
    ];

CommunityRanking _ranking() => CommunityRanking(
      communityUuid: _communityUuid,
      metric: 'readiness',
      period: 'week',
      periodStart: '2026-08-10',
      periodEnd: '2026-08-16',
      totalMembers: 1,
      page: 1,
      pageSize: 10,
      entries: const [
        CommunityRankingEntry(
          position: 1,
          personUuid: 'person-1',
          displayName: 'Ana',
          avatarUrl: '',
          score: 91,
          daysCount: 7,
        ),
      ],
    );

Future<({List<Override> overrides, _FakeJuggleImService fake})> _overrides() async {
  final fake = _FakeJuggleImService();
  final overrides = <Override>[
    communityDetailProvider.overrideWith((ref, uuid) async => _community()),
    communityMembersProvider.overrideWith((ref, uuid) async => _members()),
    communityRankingProvider
        .overrideWith((ref, params) async => _ranking()),
    communityChallengesProvider.overrideWith((ref, uuid) async =>
        <Challenge>[]),
    currentWellnessPersonProvider
        .overrideWith(() => _FakePersonNotifier()),
    juggleImServiceProvider.overrideWithValue(fake),
    chatSessionServiceProvider.overrideWithValue(_FakeChatSessionService()),
  ];
  return (overrides: overrides, fake: fake);
}

void main() {
  testWidgets(
      'Chat tab (5th) mounts CommunityChatScreen with group id community:<uuid> '
      'and no exception', (tester) async {
    final setup = await _overrides();
    await tester.pumpWidget(
      ProviderScope(
        overrides: setup.overrides,
        child: const MaterialApp(
          home: CommunityDetailScreen(uuid: _communityUuid),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'TabBar/controller length mismatch must not throw');

    // The Chat tab must be present (5 tabs total).
    expect(find.text('Chat'), findsOneWidget);

    // Tap the Chat tab — this is the action that did nothing on Android.
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'tapping Chat must not throw (was: assert(value < length))');

    // Chat UI must be mounted and visible — NOT an empty tab.
    final chatScreen = tester.widget<CommunityChatScreen>(
      find.byType(CommunityChatScreen),
    );
    expect(chatScreen.groupId, _expectedGroupId,
        reason: 'group id must follow community:<uuid> convention');
    expect(chatScreen.communityName, 'Comunidade Teste');

    // Empty history -> explicit empty state + composer must be visible.
    expect(find.text('Nenhuma mensagem ainda. Envie a primeira!'),
        findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    // The chat controller must have started: history was requested.
    expect(setup.fake.historyCalls, greaterThanOrEqualTo(1),
        reason: 'opening the chat tab must trigger history load');
  });

  testWidgets('all five tabs switch and render their content',
      (tester) async {
    final setup = await _overrides();
    await tester.pumpWidget(
      ProviderScope(
        overrides: setup.overrides,
        child: const MaterialApp(
          home: CommunityDetailScreen(uuid: _communityUuid),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Ordem WHOOP-inspired: Chat é o destino primário (aba 0).
    final tabs = ['Chat', 'Ranking', 'Desafios', 'Membros', 'Visão geral'];
    for (final label in tabs) {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'tab "$label" must switch without exception');
    }
  });
}
