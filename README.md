# Noana Wellness

Aplicativo mobile **Flutter/Dart (Android + iOS)** de wellness social — experiência
social inspirada no WHOOP, com domínio e arquitetura próprios da Noana.

> **Status: FASE 8 — GAMIFICATION + ACHIEVEMENTS + BADGES + STREAKS** (11
> achievements com regras em código, unlock imutável, streaks por score_date
> com reconstrução de score tardio, pontos/nível leves; E2E HML 18/18).
> Fase 9 em andamento conforme plano.

---

## Architecture (visão geral)

```
                    AWS COGNITO                     ← authentication
                         │
                         ▼
                  WellnessPerson                    ← identity (domínio Wellness)
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   WellnessProfile   Wearable      DailyScore
                                       │
                                       ▼
                                Score Snapshot
                                       │
                                       ▼
                                  Leaderboard
```

- **COGNITO = AUTHENTICATION** — pool compartilhado Noana (`us-east-1_lgjiHS5hH`).
- **WELLNESS BACKEND = IDENTITY + BUSINESS RULES** — app Django `wellness` no
  backend Noana existente (`noana-admin`).
- **FLUTTER = SCORE CALCULATION (fase 1) + UI + BLE + SDK JuggleIM**.
- **JUGGLEIM = MESSAGING PROJECTION** — apenas infraestrutura de chat em tempo real.
- **COMMUNITY SNAPSHOTS = SOCIAL SCORE VISIBILITY** — `share_scope` respeitado.

## Clinical vs Wellness

Clinical e Wellness são domínios separados. Wellness **não** reutiliza
`Contract`, `CareRecipient`, `CareTaker`, `MasterCareTaker`, `CorpAccess` ou
`CareMonitor`. Wellness é *self-first*. Identidade Wellness = `WellnessPerson`
(entidade própria, ligada ao mesmo `cognito_sub`).

## Cognito authentication

- Pool: `us-east-1_lgjiHS5hH` (compartilhado Clinical × Wellness).
- App client: `156qt3qr79mu4jsnr5t82hot15`.
- Fluxo: Flutter → AWS Cognito (Amplify `USER_SRP_AUTH`) → JWT → Wellness API
  → resolve/create `WellnessPerson` (fase 2).
- `AuthService` (`lib/core/auth/auth_service.dart`) expõe:
  `login`, `logout`, `restoreSession`, `refreshToken`, `getAccessToken`,
  `getIdToken`, `getCurrentIdentity`. Sessão restaurada após fechamento do app.
- Tokens persistidos apenas em **secure storage** (Keychain /
  EncryptedSharedPreferences) — nunca plaintext.

### IdToken vs AccessToken (importante)

O backend HML (`CognitoSessionMiddleware` + `django_cognito_jwt`) autentica com
o **IdToken** do Cognito. O AccessToken não carrega as claims `aud`/`email` que
o middleware valida — por isso o `ApiClient` envia `Authorization: Bearer
<IdToken>` (mesmo comportamento do app Clinical existente). `getAccessToken()`
continua disponível no `AuthService`, mas o header de API usa o IdToken.

## Wellness identity domain (Fase 2)

- **`WellnessPerson`** (spec §4): `uuid`, `cognito_sub` (**único** no banco),
  `user_uuid`, `display_name`, `avatar_url`, `height_cm`, `birth_date`, `gender`,
  timestamps. Entidade própria — NÃO herda de `person.models.Person` nem toca
  Contract/CareRecipient.
- **`WellnessProfile`** (spec §5): `OneToOneField` para `WellnessPerson`
  (`bed_time_min`, `sleep_target_min`, `goal_steps`, `timezone`,
  `formula_client_version`).
- **`services.py`**: `resolve_or_create_person(cognito_sub, user_uuid)` —
  idempotente; proteção contra corrida via unique constraint no banco +
  retry em `IntegrityError`. `update_person_profile` usa whitelist (identidade
  nunca é alterável via API).
- **`views.py`**: o backend deriva a identidade **exclusivamente do JWT**
  (`request.user.cognito_id` = `sub`) — nunca confia em `person_uuid` do cliente.

### Endpoints

| Endpoint | Descrição |
| :--- | :--- |
| `POST /v1/wellness/bootstrap/` | Resolve ou cria `WellnessPerson` + `WellnessProfile` (idempotente; retorna `person`, `profile`, `created`) |
| `GET /v1/wellness/me/` | Person + profile do usuário autenticado (404 se bootstrap pendente) |
| `PATCH /v1/wellness/me/` | Atualiza campos editáveis (whitelist) |

### Fluxo de identidade idempotente

```
Flutter (Cognito login)
   ↓ JWT
POST /v1/wellness/bootstrap/
   ↓
resolve_or_create_person(cognito_sub)
   ↓
1 WellnessPerson + 1 WellnessProfile (por cognito_sub)
```

Executar bootstrap N vezes (retry, double-tap, re-login, restart) produz
**sempre a mesma** WellnessPerson — nunca duplica.

## JuggleIM identity sync + ChatSession (Fase 3)

### Fluxo de identidade (spec §12)

```
Cognito (login/restore)
   ↓ IdToken
Wellness bootstrap (POST /v1/wellness/bootstrap/) → WellnessPerson (uuid)
   ↓
POST /v1/wellness/chat/session/
   ↓ (backend, server-side)
ensure_juggle_user(WellnessPerson)  →  JuggleIM User "wellness:<uuid>" (idempotente)
   ↓
ChatSession {user_id, token, ws_url, api_url, nav_url}  →  Flutter SDK
```

**1 Cognito identity → 1 WellnessPerson → 1 JuggleIM User → ChatSession → SDK.**
JuggleIM é apenas uma *projeção* de mensageria — a fonte de verdade é o
WellnessPerson (spec §8).

### Estratégia de ID determinística (spec §9)

- `JuggleImClient.deterministic_user_id(uuid)` → **`wellness:<uuid>`**.
- **Nunca** email, telefone ou username mutável como chave de identidade.
- O endpoint `/users/register` do servidor JuggleIM faz **upsert por user_id**:
  chamadas repetidas/concorrentes (retry, double-tap, login/logout, restart)
  nunca criam duplicatas; campos mutáveis (nickname/user_portrait) são
  sincronizados quando diferem; o servidor devolve sempre um token fresco.

### Fronteira de segredos (spec §13)

- `JUGGLE_APP_KEY` / `JUGGLE_APP_SECRET` existem **somente no backend**
  (env/settings; no HML via Secret `noana-secrets` + env vars do chart).
- O Flutter recebe apenas `{user_id, token, ws_url, api_url, nav_url}` —
  **nunca** credenciais admin, app secret ou acesso a APIs administrativas.
- O endpoint deriva a identidade **exclusivamente do JWT Cognito** — nunca de
  `person_uuid`/`juggle_user_id` enviados pelo cliente (verificado por teste).

### Endpoints HML

| Serviço | URL |
| :--- | :--- |
| Wellness API | `https://api.hml.noana.link/v1` |
| Chat session | `POST /v1/wellness/chat/session/` |
| JuggleIM API (apigateway) | `https://juggleim-api.hml.noana.link` |
| JuggleIM Navigator | `https://juggleim-nav.hml.noana.link` |
| JuggleIM WebSocket | `wss://juggleim-ws.hml.noana.link` |

### Erros estruturados (spec §65)

- Falha temporária do JuggleIM → `503` com mensagem clara; **identidade
  Wellness permanece válida** (nada é apagado/corrompido).
- Sem bootstrap → `404`; não autenticado → `401`.

### Flutter: serviços isolados (spec §14)

- `ChatSessionService` — única camada que chama `POST /wellness/chat/session/`.
- `JuggleImService` — única camada que conhece o SDK `juggle_im`
  (init/connect/disconnect/send). Widgets usam Riverpod, nunca o SDK direto.
- Estados de conexão (spec §15): `disconnected → connecting → connected →
  (reconnecting|disconnected) → connected` expostos via
  `juggleConnectionStateProvider`.
- **Queda de rede NÃO refaz login Cognito**: `reconnect()` reutiliza o token
  do ChatSession vigente; só uma falha de sessão re-obtém o ChatSession.

### Backend tests (noana-admin) — Fase 3

```bash
python -m pytest wellness/tests.py wellness/tests_juggle.py -q
# 36 passed: bootstrap/me (20) + JuggleIM (16):
#   - provisionamento 1º/repetido/concorrente (4 threads → mesmo id, 1 linha)
#   - sem duplicidade, sync de perfil mutável, ID determinístico
#   - chat session 200/401/404/503, identidade do cliente ignorada
#   - payload client-safe sem app_secret/app_key/admin
#   - isolamento Clinical (0 Contract/Person/CareRecipient)
```

## Communities + JuggleIM group sync (Fase 4)

### Domain rules (spec §2, §47)

```
Community        ← social domain entity (source of truth = Noana Wellness backend)
CommunityMember  ← membership source of truth
JuggleIM Group   ← realtime messaging projection of the Community (never the reverse)
```

- Deterministic group id (spec §5): **`community:<community_uuid>`** — never
  name/join code/owner/mutable slug.
- Visibility: `private` | `invite_only` | `public_code` (join via `join_code`).
- Roles: `owner`/`admin`/`member`. Statuses: `active`/`invited`/`left`/`banned`.
- Invariant (spec §19): `CommunityMember.status == active` ⇄ present in the
  JuggleIM group; `left`/`banned` ⇄ absent. The Wellness DB is authoritative.

### Backend endpoints (spec §8–§18)

| Endpoint | Description |
| :--- | :--- |
| `POST /v1/wellness/communities/` | Create Community — owner derived from the JWT, never from the client |
| `GET /v1/wellness/communities/?scope=my\|discoverable` | List (membership / public_code) |
| `GET /v1/wellness/communities/{uuid}/` | Detail: member_count, current_user_role/status, juggle_group_id |
| `POST /v1/wellness/communities/{uuid}/join/` | Join (idempotent; join_code for public_code, invite for invite_only) |
| `POST /v1/wellness/communities/{uuid}/leave/` | Leave → `left` + removed from group (sole owner cannot leave) |
| `GET /v1/wellness/communities/{uuid}/members/` | Safe social fields only (no cognito_sub/clinical/health) |
| `POST /v1/wellness/communities/{uuid}/members/{person_uuid}/ban/` | Ban → `banned` + removed from group (owner/admin) |
| `POST /v1/wellness/communities/{uuid}/members/{person_uuid}/unban/` | Unban → `active` + re-added to group |
| `PATCH /v1/wellness/communities/{uuid}/members/{person_uuid}/` | Role change (owner only, validated transitions) |

### JuggleIM failure behavior (spec §10, §22)

JuggleIM failure **never** corrupts Community/membership: the Community stays
authoritative, `chat_sync_status=error` (+ `chat_sync_error`), and the
reconciliation service fixes it later. No automatic Community deletion.

### Reconciliation (spec §20, §21)

```bash
python manage.py reconcile_wellness_community_chat              # all
python manage.py reconcile_wellness_community_chat --community <uuid>
python manage.py reconcile_wellness_community_chat --dry-run
```

Compares active `CommunityMember`s (DB) vs JuggleIM group members and corrects
divergence (DB active missing → add; DB left/banned present → remove).
Idempotent: repeated runs converge to a stable state.

### Flutter architecture (spec §26–§31)

- `lib/shared/models/community.dart` — `Community`, `CommunityMember`,
  `CommunityCreateRequest` mirroring the backend serializers.
- `lib/services/community_service.dart` — `CommunityService`:
  getMyCommunities/discoverCommunities/getCommunity/createCommunity/
  joinCommunity/leaveCommunity/getMembers/banMember/unbanMember/updateRole.
- `lib/services/community_providers.dart` — `myCommunitiesProvider`,
  `discoverCommunitiesProvider`, `communityDetailProvider(family)`,
  `communityMembersProvider(family)`, `communityActionControllerProvider`
  (mutations invalidate lists/detail so the UI auto-refreshes).
- UI (MVP): `CommunitiesScreen` (Minhas/Descobrir/Criar), `CommunityCard`,
  `CreateCommunityScreen` (navigates to detail after creation),
  `CommunityDetailScreen` (Visão geral/Membros/Chat tabs).
- Chat reuses the **same** Phase 3 `ChatSessionService` + `JuggleImService`
  (one WebSocket — no second abstraction, spec §32): `sendGroupText(groupId)`
  + `loadGroupHistory(groupId)` on `ConversationType.group`.

### Backend tests (noana-admin) — Fase 4

```bash
python -m pytest wellness/tests_community.py -q
# 52 passed (spec §35–§36):
#   create/owner-from-JWT/deterministic group id/ensure idempotency
#   repeat create-join safe, join/leave/ban/unban, role authorization
#   duplicate CommunityMember prevention (unique constraint)
#   JuggleIM unavailable during create/join (Community stays authoritative)
#   reconciliation: adds missing, removes banned/left, repeated → stable
#   unauthorized endpoints, Clinical isolation
#   concurrent double-join (TransactionTestCase + Barrier) → 1 row, active, no 500
```

## DailyScores + privacy + snapshots + ranking (Fase 5)

### Score audit (spec §1–§2) — see `SCORE_AUDIT.md`

- **Authoritative formula found:** Noana Health Score (noana-curator-server,
  production) — per-parameter "within target" scores (CI 90% ∩ target range,
  0–100) aggregated per interval-of-day; range **0–100** is the authoritative
  Noana convention (reused for validation).
- **NOT FOUND (spec §2 STOP CONDITION):** readiness/sleep/activity/strain/
  stress/physical_capacity formulas do NOT exist in any Noana repo.
  **Production calculation NOT implemented** — no invented health formulas.
  DailyScore fields are nullable; E2E uses deterministic test fixtures only.
  A formula specification is required before any production calculation ships.

### Data model (spec §4–§7)

- `DailyScore` — private score record; **1 per (person, score_date)**
  (unique constraint + idempotent upsert); score fields nullable 0–100;
  `formula_version` required; `computed_by` = `client` (hoje) | `server`
  (futuro, sem migração); `source_device_id` opcional.
- **score_date rule (spec §7):** the client sends the user's **wellness day**
  (`YYYY-MM-DD` local to the user, per `WellnessProfile.timezone`); the backend
  treats it as an opaque day label with 1-per-person uniqueness. Late syncs
  after midnight are assigned to the day they belong to by the client.
- `CommunityScoreSnapshot` — social projection; **1 per
  (community, person, score_date)**; only share-authorized fields populated.

### APIs (spec §8–§33)

| Endpoint | Description |
| :--- | :--- |
| `PUT /v1/wellness/scores/daily/{date}/` | Upsert (idempotente; identidade do JWT; valida 0–100; rejeita person_uuid/cognito_sub/user_uuid) |
| `GET /v1/wellness/scores/daily/latest/` | Último DailyScore do usuário |
| `GET /v1/wellness/scores/daily/?from=&to=` | Histórico do próprio usuário |
| `PATCH /v1/wellness/communities/{uuid}/privacy/` | share_scope do próprio membro (readiness/sleep/activity/strain) |
| `GET /v1/wellness/communities/{uuid}/ranking/?metric=&period=&date=` | Leaderboard (day/week/month; média dos dias válidos + days_count; ties determinísticos; paginação; current_user_position) |

### Privacy chain (spec §18, §72)

```
DailyScore (privado) → share_scope (CommunityMember.share_scope_json)
→ CommunityScoreSnapshot (projeção social) → Ranking
```

- Default privacy-safe: sem share_scope → nada é compartilhado (spec §14).
- Mudança de privacidade **propaga** para snapshots existentes (spec §20):
  desabilitar → NULL; reabilitar → rematerializa do histórico (spec §21).
- Mesmo usuário pode expor métricas diferentes por comunidade (spec §63, §73).
- Membro `left`/`banned` some do ranking e tem snapshots removidos (spec §22–§23).
- Ranking expõe **apenas** projeções sociais — nunca DailyScore/raw health
  (spec §36, §55): nenhum HR/HRV/SpO2/temperature/hypnogram/Contract.

### Rebuild (spec §57)

```bash
python manage.py rebuild_wellness_community_snapshots
python manage.py rebuild_wellness_community_snapshots --community <uuid> --person <uuid> --from 2026-08-01 --to 2026-08-13
```

### Flutter (spec §38–§50)

- `lib/shared/models/score.dart` — DailyScore, DailyScoreUpload,
  CommunityRanking(+Entry), CommunityShareScope.
- `lib/services/score_service.dart` — getLatest/getHistory/uploadDailyScore/
  updateShareScope/getRanking (spec §39). Fórmulas (quando existirem) ficam em
  `features/scores/domain/` — nunca em widgets.
- `lib/services/score_providers.dart` — latestDailyScoreProvider,
  scoreHistoryProvider, communityRankingProvider(family), shareScope/upload
  controllers com invalidação de cache (spec §50).
- UI: Home mostra o DailyScore real (spec §47); CommunityDetail ganhou a tab
  **Leaderboard** (Visão geral/Leaderboard/Membros/Chat) e o botão
  **Privacidade / Compartilhamento** (toggles por comunidade, spec §42–§43).

### Backend tests (noana-admin) — Fase 5

```bash
python -m pytest wellness/tests_score.py -q
# 48 passed (spec §51–§56):
#   upsert 10x/concorrente = 1 linha; identidade do JWT (rejeita client id)
#   range 0–100, formula_version obrigatória, computed_by inválido
#   privacy default-safe, enable/disable/reenable (rematerializa)
#   snapshots multi-community com scopes diferentes (spec §53/§73)
#   left/banned fora do ranking; ranking day/week/month; ties determinísticos
#   paginação + current_user_position; sem raw health na resposta (spec §55)
#   isolamento Clinical
```

### Verificação real no HML (Fase 5) — 22/22 PASS

- Backend HML: **`noana-backend:hml-r59`** (helm rev 25), migração
  `wellness.0003_...` aplicada; endpoints de score/privacy/ranking no ar.
- Usuários existentes: **A** `zetestadoszetestados`, **B** `rafaelteste`.
- Fixtures determinísticas (spec §61): A readiness=91, B readiness=84.

```
A upload DailyScore (readiness=91)      → 200; GET latest → 91
B upload DailyScore (readiness=84)      → 200; GET latest → 84
A 3x PUT mesmo dia                      → 1 linha (idempotente)
A cria Community X (public_code); B join
A e B compartilham readiness
leaderboard readiness day              → 1º A 91, 2º B 84; sem raw health
B desabilita readiness                 → some do ranking (redação)
B reabilita
multi-community: X readiness✓ sleep✗; Y readiness✗ sleep✓
  → B readiness visível em X; B sleep visível em Y; B readiness NÃO em Y
B leave em X                           → fora do ranking
A ban B em Y                           → fora do ranking (sleep)
```

**E2E REAL HML (Fase 5): 22/22 PASS** — scores, privacidade por comunidade,
redação imediata, leaderboard e exclusão por leave/ban verificados.

## Fase 6 — advanced chat + notifications (spec §84)

### Arquitetura

```text
Community Chat (Flutter)
├── ChatController (Riverpod, spec §48) — histórico paginado, dedupe por id,
│     envio otimista + retry, estado de reply, reações, mark read
├── JuggleImService (spec §4–§5) — ÚNICA camada que conhece o SDK; mapeia
│     Message → ChatMessage (domínio); reply via referredMsgId nativo;
│     jg:img/jg:file com progresso; reações; unread; mentions
├── ChatAttachmentService (spec §19) — pick + validação (mime allowlist,
│     tamanho), sem lógica de S3 em widgets
└── NotificationSettingsScreen (spec §55) — all/mentions_only/muted
        ↓
Backend Wellness (Noana)
├── CommunityNotificationPreference (spec §28–§30) — unique (community, person)
├── resolve_push_recipients (spec §38) — ACTIVE only, exclui sender,
│     all/mentions_only/muted; queries em lote (spec §80)
└── WellnessPushEvent (spec §45–§46) — UNIQUE(source_message_id, person):
      processamento idempotente de eventos de push
```

Cadeia de autorização preservada (spec §1–§2): Cognito → WellnessPerson →
CommunityMember → Community → JuggleIM Group → Realtime Chat. JuggleIM é
apenas infraestrutura de mensageria — nunca autoridade de associação.

### JuggleIM feature audit (spec §3 — v0.10.72 SDK / v1.8.14 server)

| Feature | SDK | Server API | Tipo de mensagem | Notas |
| :--- | :--- | :--- | :--- | :--- |
| Reply (quote) | ✅ `referredMsgId` | ✅ `refer_msg` | nativa | HTTP history NÃO serializa (limitação HisMsg) |
| Reactions | ✅ add/remove/get | ✅ (WS channel) | `onMessageReactionAdd/Remove` | sem endpoint HTTP |
| Image | ✅ `jg:img` | ✅ | `ImageMessage` | SDK faz upload |
| File | ✅ `jg:file` | ✅ | `FileMessage` | SDK faz upload |
| Read receipt | ✅ `sendReadReceipt`/`hasRead` | ✅ `messages/markread` | evento `onMessagesRead` | |
| Unread | ✅ `unreadCount`/`getTotalUnreadCount` | ⚠️ `convers/clearunread` | `onTotalUnreadMessageCountUpdate` | count é SDK-local; HTTP não expõe |
| Mentions | ✅ `MessageMentionInfo` | ✅ `mention_info` | nativa | sem parsing de texto |
| Recall | ✅ `recallMessage` | ✅ `hismsgs/recall` | `onMessageRecall` | não exposto na UI |
| Edit | ✅ `updateMessage` | ✅ `hismsgs/modify` | `onMessageUpdate` | não exposto na UI |
| Typing indicator | ❌ | ❌ | — | não suportado |
| Push offline | ⚠️ SDK registra token | ✅ `/apigateway/push` (tags) | — | providers (FCM etc.) NÃO configurados no HML |
| Webhook de mensagem | — | ❌ NÃO EXISTE no v1.8.14 | — | sem fonte de evento server-side |

### Reply (spec §7–§9)

`sendText` aceita `ChatReplyRef` → `SendMessageOption.referredMessageId`
(nativo). O composer mostra "Respondendo a {nome}" + preview + [X] para
cancelar (spec §8); o estado de reply é limpo após o envio. Bubbles com
referência renderizam preview com borda esquerda; original fora da página
não quebra (informação estável no ref). **Verificado:** unit tests (reply
set/clear/reference) + E2E HML (server aceita refer_msg nativo).

### Reactions (spec §10–§12)

Conjunto fixo: ❤️ 👍 🔥 😂 👏 💪. Add/remove via SDK nativo; eventos
realtime `onMessageReactionAdd/Remove` atualizam outros clientes sem reload
(spec §12); agregação por contagem (🔥 3). Identidade de usuários NÃO é
exposta na UI. **Verificado:** unit tests (add/remove/agg via fake);
realtime no HML exige device (canal WS) — documentado.

### Attachments (spec §13–§19)

Imagens (câmera/galeria) e arquivos (pdf, office, texto, imagens) via
ChatAttachmentService: validação de tipo (allowlist) + tamanho (10 MB img /
25 MB arquivo), preview, cancel. Upload é nativo do SDK
(`sendMediaMessage` → `jg:img`/`jg:file` armazenados no im-server) — sem S3,
sem credenciais AWS no app (spec §14). Falha de envio → bubble "falhou" +
retry (spec §16/§49), nunca descarte silencioso. **Verificado:** unit tests
(envio ok/falha/retry); upload real exige device (plugin MethodChannel).

### Read / unread (spec §21–§23)

`markConversationRead` (clearUnreadCount) chamado ao abrir a conversa —
nunca por chegada de push. Unread total via `getTotalUnreadCount` + eventos
realtime. **Limitação v1.8.14:** unread count é estado local do SDK (WS
events); o HTTP `convers/query` não expõe o campo — verificação de
"incremento" exige device. `messages/markread` + `convers/clearunread`
aceitos (E2E HML 25/25).

### Mentions (spec §24–§27)

Metadata nativa `MessageMentionInfo` (type + target_user_ids) — sem parsing
de texto; identidade = `wellness:<uuid>`/display_name, nunca email/phone/sub.
Composer com @ abre lista de membros ACTIVE (spec §26) — previsto; envio com
mention_info validado no E2E HML.

### Notification preferences (spec §28–§31, §55)

`CommunityNotificationPreference` (unique community+person; default **all**
— documentado, spec §29). API:
`GET/PATCH /v1/wellness/communities/{uuid}/notification-preferences/`
(`{"mode":"all|mentions_only|muted"}`). Apenas o próprio membro altera;
**left/banned → 403 (GET e PATCH)** — associação sempre vence (spec §31/§44).
UI: Notificações na Community detail (3 opções, persiste no backend).
**Verificado:** 21 testes backend (§61–§63) + E2E HML (default, mudanças,
mode inválido 400, left/banned 403).

### Push (spec §32–§47) — verificação em 3 níveis

1. **Server-side recipient logic — VERIFICADO (testes §62/§87):**
   `resolve_push_recipients` (ACTIVE only − sender; all/mentions_only/muted;
   lote) + `process_push_event` idempotente (UNIQUE source_message_id+person;
   retry não duplica — §45/§63). Logs estruturados spec §78.
2. **Integração de evento — BLOQUEADO POR INFRA:** o im-server v1.8.14 NÃO
   possui webhook/callback de mensagem (auditado no fonte: config_template
   sem webhook; apenas actor interno). Sem fonte de evento, Noana não vê
   mensagens SDK-direto → não dispara push (spec §36–§37: sem polling agressivo,
   sem webhook inventado).
3. **Entrega ao device — BLOQUEADO POR INFRA:** providers FCM/GeTui/APNs do
   pushmanager existem no código, mas o deployment HML não tem provider
   configurado; sem credenciais Firebase disponíveis (§57 — nada inventado).
   SNS (usado pelo Clinical) é a infra Noana existente (§34) — documentado
   como caminho de reuso futuro; DeviceFront é registro clínico de devices.

Conclusão honesta (spec §72/§91): preferências + destinatários + idempotência
provados; push device delivery NÃO reivindicado.

### Deep link / payload safety (spec §40–§43)

Payload de push conteria apenas type/community_uuid/message_id/sender
display name/preview seguro — nunca tokens, app_secret, dados de saúde ou
scores (spec §40–§41). Deep link: tap → restore auth → bootstrap →
ChatSession → conversa; sessão expirada → login → continuação (spec §43).
Implementação de push nativo (FCM) fica para quando a infra existir.

### Membership security (spec §44, §73)

left/banned: removidos do grupo JuggleIM, sem novas mensagens, sem elegibilidade
de push, prefs 403. **Verificado no E2E HML real** (25/25): B sai → group
members=1 + prefs 403; B banido → group members=1 + prefs 403.

### Limitações documentadas (spec §9, §37, §60, §72, §91)

- Typing indicator: não suportado pelo v1.8.14.
- Reply/mention relation: servida via WS/SDK (Message.referredMsg/
  mentionInfo); HTTP history a omite (serialization gap HisMsg).
- Unread count: SDK-local; não verificável por HTTP sem device.
- Reactions/attachments realtime: canal WS/plugin — exige device no host.
- Push device delivery: infrastructure-blocked (sem webhook + sem provider).
- iOS/macOS: compile não verificado neste host (spec §60).

### Real HML E2E — Fase 6 (25/25, 2026-08-13)

A/B reais (Cognito + chat/session): replies com refer_msg nativo, mentions
com mention_info, markread + clearunread aceitos, prefs (default all →
mentions_only → muted → all, inválido 400), leave → removido do grupo + 403,
rejoin + ban → removido do grupo + 403.

## Fase 7 — Challenges (spec §86)

### Domínio

```text
Community → Challenge → ChallengeParticipant → DailyScore → ChallengeRanking
```

- **Challenge** (spec §4–§14): nome/descrição, metric (allowlist:
  readiness/sleep/activity/strain — SÓ campos existentes de DailyScore, §6),
  aggregation (average/best/days_recorded, §8), período explícito
  (start<=end, máx. 90 dias, §12), status derivado de datas + ações admin
  (draft/upcoming/active/completed/cancelled, §5), created_by (owner/admin,
  §10), max_participants/min_days opcionais.
- **ChallengeParticipant** (spec §15–§21): UNIQUE(challenge, person), status
  active/left/removed, join idempotente (10x → 1 linha), leave preserva
  histórico, rejoin reativa. Apenas CommunityMember ACTIVE participa — membro
  left/banned da comunidade sai na hora (spec §21).
- **Privacidade** (spec §25–§26): participar exige
  `CommunityMember.share_scope_json[metric]==true`; join sem share → 403 com
  mensagem clara. Desligar o share depois → ineligible/fora do ranking na
  hora (dinâmico); religar → volta. NUNCA expõe métricas não relacionadas
  nem dados brutos (spec §24, §90).
- **Ranking dinâmico** (spec §22, §27–§33): calculado pelo BACKEND com
  agregação ORM (Avg/Max/Count — sem N+1, §73); dia faltante NÃO é zero
  (spec §28); ties determinísticos (score desc → days_count desc →
  joined_at asc, §32); min_days → not_qualified sem posição (§31);
  paginação + current_user_position.
- **Finalização** (spec §36–§40): `finalize_wellness_challenges
  [--challenge <uuid>]` — idempotente (10x → mesmo resultado); congela
  final_rank/final_score/final_days_count; DailyScore editado DEPOIS não
  altera o resultado histórico (spec §38). `inspect_wellness_challenge
  <uuid>` para debug (§41).

### NENHUMA fórmula de saúde nova (spec §1, §86)

Challenges usam APENAS valores já persistidos em DailyScore. A Fase 7 NÃO
implementa como readiness/sleep/activity/strain são calculados (formulas
NOT FOUND no audit da Fase 5). Fixtures determinísticas de E2E (A 90/92 → 91;
B 82/86 → 84) são dados de teste, NÃO saídas de fórmula clínica (spec §7,
§78). A existência do campo DailyScore não implica fórmula de produção.

### API (community-scoped, spec §60)

- `POST/GET /v1/wellness/communities/{uuid}/challenges/` (create owner/admin;
  list com filtro ?status=upcoming|active|completed)
- `GET/PATCH/POST /v1/wellness/communities/{uuid}/challenges/{uuid}/`
  (detalhe com progresso/posição do usuário; PATCH seguro — metric/
  aggregation/start_date imutáveis após início, §13; POST cancela, §14)
- `POST .../join/ | .../leave/` (idempotente; §18–§19)
- `POST .../participants/{person_uuid}/remove/` (owner/admin, §20)
- `GET .../ranking/` (§33)

### Flutter (spec §45–§57)

Aba **Desafios** na comunidade (Visão geral / Leaderboard / Desafios /
Membros / Chat): seções Ativos / Em breve / Concluídos, card com período,
agregação, participantes e posição. Criar (só owner/admin), detalhe com
progresso transparente ("Sua média 87.9 · 4 dias válidos · mínimo 3"),
join com requisito de privacidade explícito, ranking com highlight do
usuário, resultado congelado pós-finalização, empty states. Modelos
Challenge/ChallengeProgress/ChallengeRanking/Entry espelham a API (spec §45).

### E2E REAL HML — Fase 7 (22/22, 2026-08-13)

Create (owner 201, member 403) → join idempotente (2 ativos) → join sem
share 403 → fixtures 90/92 vs 82/86 → ranking [91.0, 84.0] days=2 → sem
dados brutos → B desliga share → sai na hora → religa → volta → B sai da
comunidade → excluído → reentra → volta → finalize (comando) → congelado
[91.0, 84.0] → DailyScore editado → resultado NÃO muda (spec §38).

## Fase 8 — Gamification (spec §85)

### Arquitetura

```text
DailyScore / Challenge / CommunityMember
        ↓ (eventos + reconciliação)
AchievementEngine (regras em código, spec §6)
        ↓
WellnessAchievement (UNIQUE person+achievement, unlocked_at IMUTÁVEL §9)
        ↓
Badges (icon_key estável — spec §10–§11)
        ↓
WellnessStreak (UNIQUE person+streak_type — §28)
        ↓
GamificationProfile (pontos/nível derivados — §34–§36)
        ↓
Flutter: GamificationScreen + Home "Seu progresso"
```

**A gamificação recompensa participação e consistência. Ela NÃO define novos
thresholds de saúde nem calcula novos scores (spec §1, §85).** Todos os
achievements derivam de dados JÁ persistidos; nenhuma fórmula de saúde foi
inventada (audit Fase 5 permanece).

### Catálogo inicial (11, seed por data migration idempotente — spec §3, §73)

| Code | Regra exata (em código) | Target |
| :--- | :--- | :--- |
| FIRST_SCORE | count distinct DailyScore.score_date | 1 |
| SCORE_7_DAYS | distinct score_date (7 dias registrados, NÃO consecutivos — §18) | 7 |
| SCORE_30_DAYS | distinct score_date | 30 |
| FIRST_COMMUNITY | qualquer CommunityMember já existiu (histórico preservado — §20) | 1 |
| COMMUNITY_3 | CommunityMember status=active (progresso pode diminuir pré-unlock; unlock imutável — §21) | 3 |
| FIRST_CHALLENGE | ChallengeParticipant existe (removed NÃO conta — §22) | 1 |
| CHALLENGE_COMPLETED | Challenge.finalized_at!=NULL E final_rank!=NULL (resultado congelado Fase 7 — §23) | 1 |
| CHALLENGE_3_COMPLETED | idem, count ≥ 3 (§24) | 3 |
| CHALLENGE_TOP_3 | final_rank IN (1,2,3) — usa final_rank, nunca recalcula (§25) | 1 |
| STREAK_7 / STREAK_30 | WellnessStreak.best_count ≥ 7 / 30 (consecutivos — §33) | 7/30 |

### Streaks (spec §27–§33)

- streak_type = `daily_score`: dias consecutivos com DailyScore registrado
  (consistência de REGISTRO, não saúde — §27, §50).
- Semântica determinística sobre `score_date` (dia wellness, fuso de
  WellnessProfile.timezone — §29): best = maior corrida; current = corrida
  terminando no dia mais recente gravado.
- **Score tardio reconstruído** (§31): 10, 12 gravados → 11 chega depois →
  rebuild → corrida 3. Fonte de verdade = DailyScore dates, nunca contador.
- `rebuild_wellness_streaks [--person]` idempotente (§32, §89).

### Engine + reconciliação (spec §13–§16, §57–§59)

- `AchievementEngine.evaluate_person/evaluate_achievement` — idempotente,
  determinístico, seguro de reexecutar.
- Triggers pós-evento COM ISOLAMENTO DE FALHA (§15, §57–§58): DailyScore
  upsert (scores+streak), Community join/leave (community), Challenge
  join/finalize (challenge) — uma falha de gamificação NUNCA quebra o
  request de origem.
- `reconcile_wellness_achievements [--person] [--achievement]` — safety net
  (§16, §89): reconstrói do banco; 10x → mesmo estado (§65).

### API (identidade só do JWT — §38, §67)

- `GET /v1/wellness/achievements/` — catálogo + estado (progress/target/
  unlocked/unlocked_at/pontos).
- `GET /v1/wellness/gamification/summary/` — unlocked_count, total_count,
  current/best streak, points, level, selected_badges (§39–§43).
- `GET /v1/wellness/streaks/` — streaks do usuário (§40).
- `POST /v1/wellness/gamification/select-badges/` — até 3 badges
  DESBLOQUEADOS (position 1..3, CheckConstraint; §43, §67).
- Sem person_uuid aceito; sem dados fisiológicos (testes §68, E2E §81).

### Flutter (spec §45–§54)

GamificationScreen (rota /gamification, app bar do Home): header Nível/
pontos/streak (wording "dias consecutivos com um wellness score registrado"
— §50), cards de conquista com progresso real (nunca fake — §49), celebração
leve de unlock deduplicada por sessão (spec §52). Home ganhou a seção "Seu
progresso" (§54). Modelos espelham a API (spec §45).

### E2E REAL HML — Fase 8 (18/18, 2026-08-14)

Catálogo 11 no HML → upload 1º score → FIRST_SCORE unlocked (trigger) →
7 dias distintos → SCORE_7_DAYS unlocked → streak current≥7 (dias
consecutivos) → summary (conquistas+pontos) → challenge finalizado com
A final_rank=1 → CHALLENGE_COMPLETED + CHALLENGE_TOP_3 unlocked →
reconcile 3x sem duplicar → streak rebuild idempotente → nenhuma resposta
com dados fisiológicos → anônimo 401.

### Limitações conhecidas

- Achievements de pontos/nível são config inicial de produto (spec §35),
  não cientificamente significativos.
- Badges são icon_keys (Material icons no app); arte final fica para depois
  (spec §11).
- Push de achievements não implementado (infra de push continua
  infrastructure-blocked da Fase 6; §53 — in-app UX é suficiente).

## Estrutura do projeto (spec §60)

lib/
├── main.dart / app.dart
├── core/
│   ├── auth/        AuthService + gateway Amplify
│   ├── config/      AppEnvironment (dev/hml/prod) via --dart-define
│   ├── network/     ApiClient (Bearer IdToken, 401→refresh→retry, timeouts)
│   ├── routing/     go_router + auth guard (refreshListenable)
│   ├── storage/     SecureStorage
│   ├── theme/       AppTheme
│   └── providers.dart
├── services/
│   ├── wellness_api_service.dart        bootstrap/getMe/updateMe
│   ├── wellness_identity_providers.dart currentWellnessPerson/wellnessProfile
│   ├── chat_session_service.dart        POST /wellness/chat/session/ (spec §12)
│   ├── juggle_im_service.dart           wrapper isolado do SDK juggle_im (spec §14)
│   ├── community_service.dart           Community CRUD/join/leave/ban/role (spec §26)
│   ├── community_providers.dart         myCommunities/detail/members/actions (spec §27)
│   ├── score_service.dart               DailyScore/privacy/ranking (spec §39)
│   └── score_providers.dart             latest/history/ranking/shareScope (spec §49)
├── features/
│   ├── auth/        LoginScreen (bootstrap pós-login)
│   ├── home/        HomeScreen (person + profile + DailyScore real — spec §47)
│   ├── chat/        ChatDiagnosticScreen (Fase 3, UI mínima de teste)
│   ├── communities/ CommunitiesScreen/Card, CreateCommunityScreen,
│   │                CommunityDetailScreen (Visão geral/Leaderboard/Membros/Chat),
│   │                LeaderboardTab, PrivacyScreen (Fase 4+5)
│   └── ...          (fases 6+)
└── shared/
    └── models/
        ├── wellness_identity.dart       WellnessPerson/WellnessProfile/
        │                                WellnessBootstrapResponse/WellnessMe
        ├── community.dart               Community/CommunityMember/
        │                                CommunityCreateRequest (Fase 4)
        └── score.dart                   DailyScore/CommunityRanking/
                                         CommunityShareScope (Fase 5)
```

## Environment variables

| Chave | dev | hml | prod |
| :--- | :--- | :--- | :--- |
| `WELLNESS_ENV` (dart-define) | `dev` | `hml` | `prod` |
| Wellness API base | `https://api.hml.noana.link/v1` | `https://api.hml.noana.link/v1` | `https://api.noana.link/v1` |
| JuggleIM API | `https://juggleim-api.hml.noana.link` | igual | `https://juggleim-api.noana.link` |
| JuggleIM Navigator | `https://juggleim-nav.hml.noana.link` | igual | `https://juggleim-nav.noana.link` |
| JuggleIM WebSocket | `wss://juggleim-ws.hml.noana.link` | igual | `wss://juggleim-ws.noana.link` |

Seleção: `--dart-define=WELLNESS_ENV=hml` > env var `WELLNESS_ENV` > debug=dev, release=prod.
Nenhum secret hardcoded no app (spec §13, §64).

## Local development

```bash
flutter pub get
flutter run --dart-define=WELLNESS_ENV=hml
```

## Android build

```bash
flutter build apk --debug
# APK: build/app/outputs/flutter-apk/app-debug.apk
flutter build appbundle --release   # produção
```

## Tests

```bash
flutter analyze        # 0 issues
flutter test           # 81 testes
```

Cobertura atual (81 testes):
- `test/auth_service_test.dart` (11) — login/logout/restoreSession/refresh/
  getAccessToken/getCurrentIdentity; identidade única (login→logout→login).
- `test/api_client_test.dart` (8) — Bearer **IdToken**, 401→refresh→retry (1x),
  erro de refresh → `ApiException` 401, timeouts, erros de rede, request sem auth.
- `test/wellness_api_service_test.dart` (8) — modelos (Person/Profile/
  BootstrapResponse/Me) + bootstrap/getMe/updateMe + falha → `ApiException`.
- `test/chat_session_service_test.dart` (4) — ChatSession parse + POST para
  `/wellness/chat/session/` + erro 503 → `ApiException` + estados de conexão.
- `test/community_service_test.dart` (9) — modelos Community/CommunityMember/
  deterministicGroupId + CommunityService (my/create/join/members/leave,
  IdToken, sem owner no payload, erro → `ApiException`).
- `test/score_service_test.dart` (8) — modelos DailyScore/Ranking/ShareScope +
  ScoreService (latest/404→null/upload/privacy/ranking; payload sem identidade).
- `test/router_guard_test.dart` (3) — redirecionamento não-autenticado →
  `/login`, autenticado → home, logout → `/login`.
- `test/app_smoke_test.dart` (1) — app renderiza e mostra login sem sessão.
- `test/helpers/fakes.dart` — `FakeCognitoGateway`, `FakeSecureStorage`.

## Backend tests (noana-admin)

```bash
cd backend && . ./.envhml && python -m pytest wellness/tests.py -q
# 20 passed — bootstrap (primeiro/repetido/10x), unicidade no banco,
# corrida concorrente (2 threads → mesmo uuid, 1 linha), /me, PATCH,
# campos de identidade imutáveis, 401, isolamento Clinical (0 Contract/Person)
python -m pytest wellness/tests_juggle.py -q     # 16 passed (Fase 3)
python -m pytest wellness/tests_community.py -q  # 52 passed (Fase 4)
python -m pytest wellness/tests_score.py -q      # 48 passed (Fase 5)
python -m pytest flespi/tests/test_models.py -q  # 3 passed (regressão)
```

### Fixes de infraestrutura de teste (pré-existentes, necessários p/ rodar pytest)

1. `contract/migrations/0031_fill_missing_service_types.py` fazia
   `Group.objects.get(name='CorpAccess'/'CareRecipient')` — falhava em banco
   novo/CI (grupos são criados em runtime). Alterado para `get_or_create`.
2. `accounts.User.save()` chamava AdminCreateUser real do Cognito — testes
   criam usuários com `cognito_provisioned_externally=True`.
3. `close_db_connections.py` fechava conexões 2x por request (double-close
   psycopg2) — `conftest.py` desconecta **somente** esse receiver de
   `request_finished` durante os testes (alvo por `__name__` no weakref), sem
   desabilitar signals globalmente.

### Verificação de migração em banco novo

`manage.py migrate` em um banco PostgreSQL criado do zero aplica toda a árvore
de migrações (incluindo `contract.0031` corrigida) e cria
`wellness_wellnessperson` + `wellness_wellnessprofile`. ✓

## Verificação real no HML (Fase 3)

- Backend HML: **`noana-backend:hml-r57`** (helm release `noana-hml` rev 23),
  migração `wellness.0001_initial` aplicada, `JUGGLE_*` no Secret/Chart.
- Usuários Cognito existentes (testes): **A** `zetestadoszetestados` e
  **B** `rafaelteste` (senha temporária via `admin_set_user_password`).
- Schema JuggleIM: colunas de ID (`user_id`, `target_id`, `sender_id`, ...)
  ampliadas de VARCHAR(32) → VARCHAR(64) no MySQL `jim_db` para acomodar os IDs
  determinísticos `wellness:<uuid>` (45 chars) — sem isso o servidor rejeitava
  o inbox com `Data too long for column 'user_id'`.

```
A session  → wellness:b1cb5be3-3343-4736-93fe-3034fbfe2ecd
B session  → wellness:4ceac009-a8a2-4e81-bcee-48fd439048b5

send A→B (jg:text)                     → 200
B history (realtime)                   → ['Ola B! Fase 3 E2E de A', ...]
send B→A (jg:text)                     → 200
A history (realtime)                   → ['Ola A! Recebi sua msg - B', ...]

6x logout/login + restart (A)          → mesmo WellnessPerson UUID + mesmo
                                         JuggleIM user_id (estável)
6x chat/session repetido (A e B)       → mesmos user_ids, sem duplicatas
users table (jim_db)                   → 1 linha por wellness:<uuid>
```

**E2E REAL HML: PASS** — A→B e B→A entregues em tempo real via JuggleIM,
identidade estável em logout/login/restart, zero duplicatas.

### Verificação real no HML (Fase 4)

- Backend HML: **`noana-backend:hml-r58`** (helm release `noana-hml` rev 24),
  migração `wellness.0002_community_...` aplicada; `/v1/wellness/communities/`
  → 401 (auth ativa, endpoint no ar).
- Mesmos usuários Cognito existentes: **A** `zetestadoszetestados` (owner) e
  **B** `rafaelteste` (member) — nenhum pool/usuário novo criado (spec §37).
- Comunidade E2E: `E2E Wellness Community <timestamp>` (public_code) → grupo
  JuggleIM `community:<uuid>` criado e sincronizado pelo backend.

```
A create Community X (public_code)        → 201, owner do JWT, juggle_group_id
                                            community:<uuid>, chat_synced
JuggleIM group info                       → group_name sincronizado
A no grupo, B join (join_code)            → active + B no grupo JuggleIM
members API                               → A=owner active, B=member active
A sends "hello community from A" (group)  → B recebe (history channel_type=2)
B sends "hello A" (group)                 → A recebe (history)
B leave                                   → status=left no DB + removido do grupo
B rejoin (public_code)                    → active + de volta no grupo
A ban B                                   → status=banned + removido do grupo;
                                            join de B → 403
A unban B                                 → status=active + re-adicionado
invariante (spec §19)                     → active DB == membros do grupo
reconcile_wellness_community_chat         → added=0 removed=0 (estável)
drift injetado (B removido do grupo)      → reconcile: added=1, corrigido
reconcile repetido                        → added=0 removed=0 (estável, sem duplicatas)
```

**E2E REAL HML (Fase 4): 30/30 PASS** — create/join/leave/rejoin/ban/unban +
chat em grupo bidirecional + reconciliação corrigindo divergência real.

*Limitação de mensageria*: sem dispositivo/emulador Android nesta máquina, o
fluxo de mensagens é dirigido pela **API oficial do servidor JuggleIM** (a
mesma infraestrutura que o SDK `juggle_im` usa via WebSocket) — envio via
`/apigateway/messages/group/send` e recebimento verificado via
`/apigateway/hismsgs/query?channel_type=2` (mesma prática documentada na Fase 3).

### Verificação real no HML (Fase 2)

- Backend HML atualizado para a imagem **`noana-backend:hml-r55`** (helm
  upgrade, release `noana-hml` rev 21) e migração `wellness.0001_initial`
  aplicada no RDS de HML.
- Usuário Cognito existente no pool (`zetestadoszetestados` /
  `ze@testador.com`) recebeu **temporariamente** uma senha conhecida via
  `admin_set_user_password` **apenas para a verificação E2E** — nenhum novo
  pool, usuário ou infraestrutura Cognito foi criado.
- Script `tool/hml_identity_verify.dart` contra `https://api.hml.noana.link/v1`:

```
[1] login #1 bootstrap   -> person=b1cb5be3-3343-4736-93fe-3034fbfe2ecd sub=043824f8-…
[2] /me                  -> mesma person
[3] login #2 (logout/login) -> mesma person
[4] login #3 (restart sim)  -> mesma person
[5] 10x bootstrap repetido  -> mesma person (idempotente, created=false)

PASS: 1 Cognito identity -> 1 WellnessPerson (b1cb5be3-3343-4736-93fe-3034fbfe2ecd)
across login / logout+login / restart / 10x   (spec §66)
```

## Troubleshooting

- **`SignedOutException` em testes**: gateway fake exige `initialSession: true`
  ou `refreshTokenUsable: true` para o caminho de restauração.
- **Redirecionamento não dispara**: o router usa `refreshListenable`
  (`RouterAuthStatus`) — não recrie o `GoRouter` em resposta ao stream.
- **Amplify não configurado**: `AuthService.initialize()` roda no
  `addPostFrameCallback` do `app.dart`; configure antes de chamar login.
- **`flutter_secure_storage` v11**: usa `AndroidOptions()` (encrypted
  shared prefs é o padrão).
- **401 no HML com AccessToken**: o backend HML valida o **IdToken** (claims
  `aud`/`email`). O `ApiClient` já envia o IdToken — não troque para AccessToken.
- **`height_cm` como string**: o serializer Django (DecimalField) devolve
  `"178.5"` — o model Flutter aceita `num` e `String`.
- **`tools:replace="android:label"`**: o SDK `juggle_im` puxa
  `qiniu-android-sdk`, que declara `android:label` — o manifest do app usa
  `tools:replace` para resolver o conflito de merge.

## Não fazer (spec §81, vigente desde a fase 1)

- Não criar Cognito paralelo, login/senha JuggleIM, nem expor credenciais
  administrativas no Flutter.
- Não usar `Person` Clinical como `WellnessPerson`.
- Não criar `Contract` Wellness / `CareRecipient` self.
- Não colocar secrets no app.
