import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications: a partner's touch or message arriving while the app is in the
/// background.
class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> show(
    int id,
    String title,
    String body, {
    String channel = 'touches',
  }) => _plugin.show(
    id,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        channel,
        channel == 'touches' ? 'Touches' : 'Messages',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: const DarwinNotificationDetails(),
    ),
  );
}
