# Noana Wellness

Aplicativo mobile **Flutter/Dart (Android + iOS)** de wellness social — experiência
social inspirada no WHOOP, com domínio e arquitetura próprios da Noana.

> **Status: FASE 1 — FOUNDATION** (autenticação Cognito, sessão segura, API client,
> roteamento, temas). Fases 2–9 em andamento conforme plano em
> `.hermes/plans/2026-08-13_noana-wellness-app.md`.

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
- **WELLNESS BACKEND = IDENTITY + BUSINESS RULES** — novo app Django `wellness`
  no backend Noana existente (fase 2+).
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

## Estrutura do projeto (spec §60)

```
lib/
├── main.dart / app.dart
├── core/
│   ├── auth/        AuthService + gateway Amplify
│   ├── config/      AppEnvironment (dev/hml/prod) via --dart-define
│   ├── network/     ApiClient (Bearer, 401→refresh→retry, timeouts)
│   ├── routing/     go_router + auth guard (refreshListenable)
│   ├── storage/     SecureStorage
│   ├── theme/       AppTheme
│   └── providers.dart
├── services/        (fases 2+)
├── features/
│   ├── auth/        LoginScreen
│   ├── home/        HomeScreen (placeholder)
│   └── ...          (fases 2+)
└── shared/          (fases 2+)
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
flutter test           # 23 testes (auth, api client, router guard, smoke)
```

Cobertura atual:
- `test/auth_service_test.dart` — login/logout/restoreSession/refresh/
  getAccessToken/getCurrentIdentity; identidade única (login→logout→login).
- `test/api_client_test.dart` — Bearer header, 401→refresh→retry (1x), erro de
  refresh → `ApiException` 401, timeouts, erros de rede, request sem auth.
- `test/router_guard_test.dart` — redirecionamento não-autenticado → `/login`,
  autenticado → home, logout → `/login`.
- `test/app_smoke_test.dart` — app renderiza e mostra login sem sessão.
- `test/helpers/fakes.dart` — `FakeCognitoGateway`, `FakeSecureStorage`.

## Troubleshooting

- **`SignedOutException` em testes**: gateway fake exige `initialSession: true`
  ou `refreshTokenUsable: true` para o caminho de restauração.
- **Redirecionamento não dispara**: o router usa `refreshListenable`
  (`RouterAuthStatus`) — não recrie o `GoRouter` em resposta ao stream.
- **Amplify não configurado**: `AuthService.initialize()` roda no
  `addPostFrameCallback` do `app.dart`; configure antes de chamar login.
- **`flutter_secure_storage` v11**: usa `AndroidOptions()` (encrypted
  shared prefs é o padrão).

## Não fazer (spec §81, vigente desde a fase 1)

- Não criar Cognito paralelo, login/senha JuggleIM, nem expor credenciais
  administrativas no Flutter.
- Não usar `Person` Clinical como `WellnessPerson`.
- Não criar `Contract` Wellness / `CareRecipient` self.
- Não colocar secrets no app.
