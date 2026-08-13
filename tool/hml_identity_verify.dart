// Integration smoke for Phase 2 against real HML: login → bootstrap → me →
// logout/login → bootstrap → restart-simulation → bootstrap must all resolve
// the SAME WellnessPerson uuid (spec §66).
//
// Run: dart run tool/hml_identity_verify.dart
//
// Env:
//   WELLNESS_API_BASE  (default https://api.hml.noana.link/v1)
//   COGNITO_USERNAME   (default zetestadoszetestados)
//   COGNITO_PASSWORD   (required; test password set via admin_set_user_password)
//
// This uses the same Cognito InitiateAuth flow the app uses (USER_PASSWORD_AUTH
// against the shared Noana pool) and the same /wellness/bootstrap/ endpoint the
// Flutter app calls after login. It does NOT exercise Amplify's native SRP —
// that part is covered by widget tests with fakes; this verifies the server
// side of the identity contract (1 WellnessPerson per cognito_sub, idempotent).
import 'dart:convert';
import 'dart:io';

const _apiBase = String.fromEnvironment(
  'WELLNESS_API_BASE',
  defaultValue: 'https://api.hml.noana.link/v1',
);
const _cognitoUsername = String.fromEnvironment(
  'COGNITO_USERNAME',
  defaultValue: 'zetestadoszetestados',
);

Future<Map<String, String>> _cognitoLogin(String password) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$_apiBase/auth/'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'username': _cognitoUsername, 'password': password}));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('login HTTP ${res.statusCode}: $body');
    }
    final data = jsonDecode(body) as Map<String, dynamic>;
    final auth = data['AuthenticationResult'] as Map<String, dynamic>;
    // HML backend (CognitoSessionMiddleware + DRF) autentica com o IdToken —
    // AccessToken não carrega aud/email claims (mesmo comportamento do app clinical).
    return {
      'id_token': auth['IdToken'] as String,
      'access_token': auth['AccessToken'] as String,
      'refresh_token': (auth['RefreshToken'] as String?) ?? '',
    };
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> _bootstrap(String accessToken) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$_apiBase/wellness/bootstrap/'));
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    req.write('{}');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('bootstrap HTTP ${res.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> _me(String accessToken) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('$_apiBase/wellness/me/'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('me HTTP ${res.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<void> main() async {
  final password = Platform.environment['COGNITO_PASSWORD'];
  if (password == null || password.isEmpty) {
    stderr.writeln('COGNITO_PASSWORD env required');
    exit(2);
  }

  stdout.writeln('== Phase 2 HML identity verification ==');
  stdout.writeln('user: $_cognitoUsername  api: $_apiBase');
  stdout.writeln();

  // 1) First login (fresh session) → bootstrap.
  final login1 = await _cognitoLogin(password);
  final b1 = await _bootstrap(login1['id_token']!);
  final person1 = b1['person'] as Map<String, dynamic>;
  final uuid1 = person1['uuid'] as String;
  final sub1 = person1['cognito_sub'] as String;
  stdout.writeln('[1] login #1 bootstrap -> person=$uuid1 sub=$sub1 created=${b1['created']}');

  // 2) /me with the same token returns the same person.
  final me1 = await _me(login1['id_token']!);
  final uuidMe = (me1['person'] as Map<String, dynamic>)['uuid'] as String;
  stdout.writeln('[2] /me               -> person=$uuidMe');
  if (uuidMe != uuid1) {
    stderr.writeln('FAIL: /me returned different uuid');
    exit(1);
  }

  // 3) Logout/login simulation: fresh Cognito login (new tokens) → bootstrap.
  final login2 = await _cognitoLogin(password);
  final b2 = await _bootstrap(login2['id_token']!);
  final uuid2 = (b2['person'] as Map<String, dynamic>)['uuid'] as String;
  stdout.writeln('[3] login #2 bootstrap -> person=$uuid2 created=${b2['created']}');
  if (uuid2 != uuid1) {
    stderr.writeln('FAIL: logout/login resolved different uuid');
    exit(1);
  }

  // 4) App-restart simulation: fresh process state, fresh login → bootstrap.
  final login3 = await _cognitoLogin(password);
  final b3 = await _bootstrap(login3['id_token']!);
  final uuid3 = (b3['person'] as Map<String, dynamic>)['uuid'] as String;
  stdout.writeln('[4] login #3 bootstrap -> person=$uuid3 created=${b3['created']}');
  if (uuid3 != uuid1) {
    stderr.writeln('FAIL: app restart resolved different uuid');
    exit(1);
  }

  // 5) Repeated bootstrap (10x) never duplicates (spec §10).
  for (var i = 0; i < 10; i++) {
    final bx = await _bootstrap(login3['id_token']!);
    if ((bx['person'] as Map<String, dynamic>)['uuid'] != uuid1) {
      stderr.writeln('FAIL: bootstrap #$i diverged');
      exit(1);
    }
  }
  stdout.writeln('[5] 10x repeated bootstrap -> same uuid (idempotent)');

  stdout.writeln();
  stdout.writeln('PASS: 1 Cognito identity -> 1 WellnessPerson ($uuid1) across '
      'login / logout+login / restart / 10x');
}
