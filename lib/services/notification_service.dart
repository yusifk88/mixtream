import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static const _channelId = 'recording_progress';
  static const _channelName = 'Recording Progress';
  static const _recordingNotificationId = 1001;
  static const _savedNotificationId = 1002;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(settings);

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: 'Shows recording progress and save status',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        ),
      );
    }
  }

  Future<void> showRecordingProgress() async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Shows recording progress and save status',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      indeterminate: true,
      playSound: false,
      enableVibration: false,
      onlyAlertOnce: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    await _plugin.show(
      _recordingNotificationId,
      'Recording in progress',
      'MixStream Pro is currently recording',
      details,
    );
  }

  Future<void> showRecordingSaved({String? path}) async {
    await _plugin.cancel(_recordingNotificationId);

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Shows recording progress and save status',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      showProgress: false,
      playSound: true,
      enableVibration: true,
      onlyAlertOnce: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final fileName = path?.split('/').last ?? '';
    final body = fileName.isNotEmpty
        ? 'Recording saved as $fileName'
        : 'Recording saved successfully';

    await _plugin.show(
      _savedNotificationId,
      'Recording saved',
      body,
      details,
    );
  }

  Future<void> showRecordingStopped() async {
    await _plugin.cancel(_recordingNotificationId);
  }

  Future<void> showRecordingError() async {
    await _plugin.cancel(_recordingNotificationId);

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Shows recording progress and save status',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      showProgress: false,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      _recordingNotificationId,
      'Recording failed',
      'An error occurred while recording',
      details,
    );
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
