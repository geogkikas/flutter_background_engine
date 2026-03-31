import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as import_fln;

import 'models/fetch_config.dart';
import 'models/fetch_record.dart';
import 'core/background_storage.dart';
import 'core/background_task.dart';

/// The core engine responsible for initializing, scheduling, and managing background data fetches.
class BackgroundDataFetcher {
  BackgroundDataFetcher._();

  /// Initializes the engine and schedules the first background fetch.
  ///
  /// [fetchCallback] MUST be a top-level or static function.
  /// NOTE: Ensure your host app has requested Notification and Exact Alarm permissions
  /// before calling this, otherwise the background service may fail to start.
  static Future<bool> initializeAndStart({
    required Future<Map<String, dynamic>> Function() fetchCallback,
    FetchConfig config = const FetchConfig(),
  }) async {
    // 1. Serialize the callback...
    final callbackHandle = PluginUtilities.getCallbackHandle(fetchCallback);
    if (callbackHandle == null) {
      throw Exception(
        "The fetchCallback MUST be a top-level or static function.",
      );
    }
    await BackgroundStorage.saveCallbackHandle(callbackHandle.toRawHandle());

    // 2. Initialize Core Services...
    final existingInterval = await BackgroundStorage.getSavedInterval();
    final intervalToUse = existingInterval > 0
        ? existingInterval
        : config.intervalMinutes;
    await BackgroundStorage.saveInterval(intervalToUse);

    if (Platform.isAndroid) await AndroidAlarmManager.initialize();

    final service = FlutterBackgroundService();

    // Create the Silent/Minimized Notification Channel
    if (Platform.isAndroid) {
      final flutterLocalNotificationsPlugin =
          import_fln.FlutterLocalNotificationsPlugin();

      const channel = import_fln.AndroidNotificationChannel(
        'silent_background_channel',
        'Background Sync',
        description: 'Used for silent data synchronization',
        importance: import_fln.Importance.min,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      );

      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
            import_fln.AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(channel);
    }

    // 3. Configure the Background Service Wrapper
    if (!(await service.isRunning())) {
      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onForegroundServiceStart,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: 'silent_background_channel',
          initialNotificationTitle: 'System Sync',
          initialNotificationContent: 'Running optimization',
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onForegroundServiceStart,
          onBackground: onIosBackground,
        ),
      );
      await service.startService();
    }

    // 4. Kick off the initial exact alarm
    await _scheduleNextExactAlarm(intervalToUse);

    // 5. Save the intended active state
    await BackgroundStorage.setServiceActive(true);

    return true;
  }

  /// Stops the background service and cancels all future alarms.
  static void stop() {
    if (Platform.isAndroid) AndroidAlarmManager.cancel(4242);
    FlutterBackgroundService().invoke('stopService');

    // Unset the active state
    BackgroundStorage.setServiceActive(false);
  }

  /// Updates the interval for future fetches and reschedules the immediate next alarm.
  static Future<void> updateInterval(int minutes) async {
    await BackgroundStorage.saveInterval(minutes);
    await _scheduleNextExactAlarm(minutes);
  }

  // MARK: - Data Retrieval & Sync Management

  /// Retrieves the complete history of saved fetch records.
  static Future<List<FetchRecord>> getHistory({int limit = 1000}) async {
    final rawLogs = await BackgroundStorage.getAllRecords(limit: limit);
    return rawLogs.map((log) => FetchRecord.fromJson(log)).toList();
  }

  /// Retrieves records that have not yet been marked as synced.
  static Future<List<FetchRecord>> getUnsyncedRecords({int limit = 500}) async {
    final rawLogs = await BackgroundStorage.getUnsyncedRecords(limit: limit);
    return rawLogs.map((log) => FetchRecord.fromJson(log)).toList();
  }

  /// Marks a specific list of SQLite IDs as successfully synced.
  static Future<void> markAsSynced(List<int> sqliteIds) {
    return BackgroundStorage.markAsSynced(sqliteIds);
  }

  /// Permanently deletes all records from local storage.
  static Future<void> clearHistory() {
    return BackgroundStorage.clearAllRecords();
  }

  /// Reverts all records back to an 'unsynced' state.
  static Future<void> revertAllSyncedStatus() {
    return BackgroundStorage.revertAllSyncedStatus();
  }

  /// Returns true if the background service is currently active.
  static Future<bool> isRunning() async {
    return await BackgroundStorage.isServiceActive();
  }

  // MARK: - Private Helpers

  static Future<void> _scheduleNextExactAlarm(int intervalMinutes) async {
    if (Platform.isAndroid) {
      await AndroidAlarmManager.cancel(4242);

      final now = DateTime.now();
      final int minutesToNext =
          intervalMinutes - (now.minute % intervalMinutes);

      DateTime targetTime = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute + minutesToNext,
        0,
        0,
      );

      if (targetTime.difference(now).inSeconds < 60) {
        targetTime = targetTime.add(Duration(minutes: intervalMinutes));
      }

      debugPrint("\n=================================================");
      debugPrint("📅 [Task Scheduler] EXACT ALARM SCHEDULED");
      debugPrint("📱 Platform: ANDROID (AlarmManager)");
      debugPrint("🎯 Target Execution: $targetTime");
      debugPrint("=================================================\n");

      await AndroidAlarmManager.oneShotAt(
        targetTime,
        4242,
        performBackgroundDataFetch,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
        allowWhileIdle: true,
      );
    } else if (Platform.isIOS) {
      // 🍏 Notify the active iOS isolate to recalculate its precise Timer
      FlutterBackgroundService().invoke('updateTimer');
    }
  }
}
