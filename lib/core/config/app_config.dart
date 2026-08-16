/// Environment configuration for the Noana Wellness app.
///
/// Supported environments: dev, hml, prod.
/// Selection order (highest priority first):
///   1. `--dart-define=WELLNESS_ENV=...` at build/run time
///   2. `WELLNESS_ENV` environment variable (tests/CI)
///   3. kDebugMode -> dev, otherwise prod
library;

import 'package:flutter/foundation.dart';

enum AppEnvironment { dev, hml, prod }

class AppConfig {
  const AppConfig({
    required this.environment,
    required this.wellnessApiBaseUrl,
    required this.juggleApiUrl,
    required this.juggleNavUrl,
    required this.juggleWsUrl,
    required this.cognitoPoolId,
    required this.cognitoClientId,
  });

  final AppEnvironment environment;

  /// Noana Wellness backend API base URL (the existing Django API, `/v1/wellness`).
  final String wellnessApiBaseUrl;

  /// JuggleIM server API base URL.
  final String juggleApiUrl;

  /// JuggleIM navigator URL.
  final String juggleNavUrl;

  /// JuggleIM WebSocket URL.
  final String juggleWsUrl;

  /// AWS Cognito user pool (env-scoped — wellness pools differ from the
  /// clinical SSO pool; the HML backend validates the IdToken `aud` claim
  /// against the pool's app client).
  final String cognitoPoolId;

  /// AWS Cognito app client id (must match the backend's COGNITO_CLIENT_ID /
  /// COGNITO_AUDIENCE for the target environment).
  final String cognitoClientId;

  bool get isProd => environment == AppEnvironment.prod;
  bool get isHml => environment == AppEnvironment.hml;

  static const String _envOverride = String.fromEnvironment('WELLNESS_ENV');

  static AppEnvironment resolveEnvironment() {
    const fromDefine = _envOverride;
    if (fromDefine.isNotEmpty) {
      return AppEnvironment.values.firstWhere(
        (e) => e.name == fromDefine,
        orElse: () => throw ArgumentError('Unknown WELLNESS_ENV: $fromDefine'),
      );
    }
    final fromVar = String.fromEnvironment('WELLNESS_ENV');
    if (fromVar.isNotEmpty) {
      return AppEnvironment.values.firstWhere(
        (e) => e.name == fromVar,
        orElse: () => throw ArgumentError('Unknown WELLNESS_ENV: $fromVar'),
      );
    }
    return kDebugMode ? AppEnvironment.dev : AppEnvironment.prod;
  }

  static const AppConfig _dev = AppConfig(
    environment: AppEnvironment.dev,
    wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
    juggleApiUrl: 'https://juggleim-api.hml.noana.link',
    juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
    juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
    cognitoPoolId: 'us-east-1_BFGyiLUlb',
    cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
  );

  static const AppConfig _hml = AppConfig(
    environment: AppEnvironment.hml,
    wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
    juggleApiUrl: 'https://juggleim-api.hml.noana.link',
    juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
    juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
    cognitoPoolId: 'us-east-1_BFGyiLUlb',
    cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
  );

  static const AppConfig _prod = AppConfig(
    environment: AppEnvironment.prod,
    wellnessApiBaseUrl: 'https://api.noana.link/v1',
    juggleApiUrl: 'https://juggleim-api.noana.link',
    juggleNavUrl: 'https://juggleim-nav.noana.link',
    juggleWsUrl: 'wss://juggleim-ws.noana.link',
    cognitoPoolId: 'us-east-1_YlgSPEfCc',
    cognitoClientId: '40h05k8dale4f4bdr14ccgms79',
  );

  static AppConfig forEnvironment(AppEnvironment env) {
    switch (env) {
      case AppEnvironment.dev:
        return _dev;
      case AppEnvironment.hml:
        return _hml;
      case AppEnvironment.prod:
        return _prod;
    }
  }

  /// Resolves the config for the current environment (dart-define aware).
  static AppConfig get current => forEnvironment(resolveEnvironment());
}
