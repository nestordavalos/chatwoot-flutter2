import 'dart:convert';

import 'package:chatwoot/firebase_options.dart';
import 'package:chatwoot/models/notification.dart';
import 'package:chatwoot/services/notification_channels.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';

final _backgroundLogger = Logger();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on FirebaseException catch (error, stackTrace) {
    if (error.code != 'duplicate-app') {
      _backgroundLogger.e(
        'Failed to initialize Firebase in background isolate',
        error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  if (message.data.isEmpty) {
    _backgroundLogger.w('Received background message without data payload');
    return;
  }

  try {
    final info = NotificationInfo.fromJson(message.data);

    DartPluginRegistrant.ensureInitialized();

    final plugin = FlutterLocalNotificationsPlugin();

    await configureChatwootLocalNotifications(plugin);

    await plugin.show(
      info.id,
      info.push_message_title,
      info.notification_type.name,
      chatwootNotificationDetails,
      payload: jsonEncode(info.toJson()),
    );
  } catch (error, stackTrace) {
    _backgroundLogger.e(
      'Failed to process background notification',
      error,
      stackTrace: stackTrace,
    );
    _backgroundLogger.e(message.data);
  }
}
