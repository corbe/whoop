# Noana Wellness

Aplicativo mobile **Flutter/Dart (Android + iOS)** de wellness social — experiência
social inspirada no WHOOP, com domínio e arquitetura próprios da Noana.

> **Status: FASE 5 — DAILY SCORES + PRIVACY + COMMUNITY SNAPSHOTS + RANKINGS**
> (DailyScore privado, share_scope por Community, CommunityScoreSnapshot,
> leaderboard day/week/month, real 2-user HML E2E 22/22). Fases 6–9 conforme
> plano em `.hermes/plans/2026-08-13_noana-wellness-app.md`.

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

## Estrutura do projeto (spec §60)

```
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
flutter test           # 52 testes
```

Cobertura atual (52 testes):
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
