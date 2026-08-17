import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// Handler de mensagens em BACKGROUND (app em segundo plano/terminado).
/// Roda em isolate próprio — NUNCA navega nem toca BuildContext.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // degradado: sem Firebase, sem push — o handler só loga.
  }
  final type = message.data['type'] ?? 'unknown';
  debugPrint('[push] background type=$type');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[boot] binding ready');

  // Firebase é NÃO-CRÍTICO (spec push §6/§22): se o init falhar (plist
  // ausente, config errada, rede), o app DEVE renderizar — push degradado.
  // O runApp NUNCA pode ficar preso atrás do Firebase.
  try {
    await Firebase.initializeApp();
    debugPrint('[boot] firebase ready');
  } catch (e) {
    debugPrint('[boot] firebase unavailable: ${e.runtimeType}');
  }

  try {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (_) {
    // handler de background não pode impedir o boot
  }

  runApp(const ProviderScope(child: NoanaWellnessApp()));
  debugPrint('[boot] runApp');
}
