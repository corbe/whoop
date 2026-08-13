# Noana Wellness

Aplicativo mobile **Flutter/Dart (Android + iOS)** de wellness social — experiência
social inspirada no WHOOP, com domínio e arquitetura próprios da Noana.

> **Status: FASE 2 — WELLNESS IDENTITY** (WellnessPerson/WellnessProfile via
> bootstrap + /me, integrado com Cognito real no HML). Fases 3–9 em andamento
> conforme plano em `.hermes/plans/2026-08-13_noana-wellness-app.md`.

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

### Backend (`noana-admin/backend/wellness/`)

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
│   └── wellness_identity_providers.dart currentWellnessPerson/wellnessProfile
├── features/
│   ├── auth/        LoginScreen (bootstrap pós-login)
│   ├── home/        HomeScreen (person + profile)
│   └── ...          (fases 3+)
└── shared/
    └── models/
        └── wellness_identity.dart       WellnessPerson/WellnessProfile/
                                         WellnessBootstrapResponse/WellnessMe
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
flutter test           # 31 testes
```

Cobertura atual (31 testes):
- `test/auth_service_test.dart` (11) — login/logout/restoreSession/refresh/
  getAccessToken/getCurrentIdentity; identidade única (login→logout→login).
- `test/api_client_test.dart` (8) — Bearer **IdToken**, 401→refresh→retry (1x),
  erro de refresh → `ApiException` 401, timeouts, erros de rede, request sem auth.
- `test/wellness_api_service_test.dart` (8) — modelos (Person/Profile/
  BootstrapResponse/Me) + bootstrap/getMe/updateMe + falha → `ApiException`.
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
python -m pytest flespi/tests/test_models.py -q   # 3 passed (regressão)
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

## Verificação real no HML (Fase 2)

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

## Não fazer (spec §81, vigente desde a fase 1)

- Não criar Cognito paralelo, login/senha JuggleIM, nem expor credenciais
  administrativas no Flutter.
- Não usar `Person` Clinical como `WellnessPerson`.
- Não criar `Contract` Wellness / `CareRecipient` self.
- Não colocar secrets no app.
