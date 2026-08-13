/// Central Riverpod providers for core infrastructure.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/auth_service.dart';
import 'config/app_config.dart';
import 'network/api_client.dart';
import 'storage/secure_storage.dart';

/// Resolved app configuration (env-aware via dart-define).
final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.current);

/// Secure storage (Keychain/EncryptedSharedPreferences backed).
final secureStorageProvider = Provider<SecureStorage>((ref) => SecureStorage());

/// Auth service (Cognito via Amplify).
final authServiceProvider = Provider<AuthService>((ref) {
  final service = AuthService(
    gateway: AmplifyCognitoGateway(),
    storage: ref.watch(secureStorageProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Auth state stream for the routing guard.
final authStatusProvider = StreamProvider<AuthStatus>((ref) {
  return ref.watch(authServiceProvider).statusStream;
});

/// Central HTTP client (Bearer injection, 401 refresh-retry, timeouts).
final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    config: ref.watch(appConfigProvider),
    auth: ref.watch(authServiceProvider),
  );
});
