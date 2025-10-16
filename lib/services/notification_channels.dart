import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String chatwootNotificationChannelId = 'chatwoot_notifications';
const String chatwootNotificationChannelName = 'Chatwoot notifications';
const String chatwootNotificationChannelDescription =
    'Real-time updates for your Chatwoot conversations.';

const AndroidNotificationChannel chatwootAndroidChannel =
    AndroidNotificationChannel(
  chatwootNotificationChannelId,
  chatwootNotificationChannelName,
  description: chatwootNotificationChannelDescription,
  importance: Importance.max,
);

final NotificationDetails chatwootNotificationDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    chatwootNotificationChannelId,
    chatwootNotificationChannelName,
    channelDescription: chatwootNotificationChannelDescription,
    importance: Importance.max,
    priority: Priority.high,
    icon: '@mipmap/ic_launcher',
  ),
  iOS: const DarwinNotificationDetails(
    presentAlert: true,
    presentSound: true,
  ),
);

Future<void> configureChatwootLocalNotifications(
  FlutterLocalNotificationsPlugin plugin, {
  NotificationResponseCallback? onDidReceiveNotificationResponse,
}) async {
  await plugin.initialize(
    InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: const DarwinInitializationSettings(),
    ),
    onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
  );

  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(chatwootAndroidChannel);
}
