import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'background_storage.dart';

const int backgroundAlarmId = 4242;
const MethodChannel backgroundChannel = MethodChannel(
  'background_data_fetcher',
);

Timer? _iosExactTimer;

/// Shared utility: Calculates the exact next trigger time using absolute UTC.
DateTime calculateNextExactTrigger(int intervalMinutes) {
  final now = DateTime.now().toUtc();
  final int minutesToNext = intervalMinutes - (now.minute % intervalMinutes);

  DateTime targetTime = DateTime.utc(
    now.year,
    now.month,
    now.day,
    now.hour,
    now.minute + minutesToNext,
    0,
    0,
  );

  if (targetTime.difference(now).inSeconds < 10) {
    targetTime = targetTime.add(Duration(minutes: intervalMinutes));
  }
  return targetTime;
}

/// Shared utility: Cancels the old alarm and schedules the next exact Android alarm.
Future<void> scheduleAndroidExactAlarm(int intervalMinutes) async {
  await AndroidAlarmManager.cancel(backgroundAlarmId);

  DateTime targetTime = calculateNextExactTrigger(intervalMinutes);

  debugPrint("\n=================================================");
  debugPrint("📅 [Task Scheduler] EXACT ALARM SCHEDULED");
  debugPrint("📱 Platform: ANDROID (AlarmManager)");
  debugPrint("🎯 Target Execution: ${targetTime.toLocal()}");
  debugPrint("=================================================\n");

  await AndroidAlarmManager.oneShotAt(
    targetTime,
    backgroundAlarmId,
    performBackgroundDataFetch,
    exact: true,
    wakeup: true,
    rescheduleOnReboot: true,
    allowWhileIdle: true,
  );
}

// Scheduling function for iOS
void _scheduleIosExactTimer() async {
  _iosExactTimer?.cancel();

  final isActive = await BackgroundStorage.isServiceActive();
  if (!isActive) return;

  final interval = await BackgroundStorage.getSavedInterval();
  final targetTime = calculateNextExactTrigger(interval);
  final duration = targetTime.difference(DateTime.now().toUtc());

  _iosExactTimer?.cancel();

  debugPrint("\n=================================================");
  debugPrint("📅 [Task Scheduler] EXACT ALARM SCHEDULED");
  debugPrint("📱 Platform: iOS (Foreground Heartbeat)");
  debugPrint(
    "🎯 Target Execution: ${targetTime.toLocal()} (in ${duration.inSeconds}s)",
  );
  debugPrint("=================================================\n");

  _iosExactTimer = Timer(duration, () async {
    await performBackgroundDataFetch();
    _scheduleIosExactTimer();
  });
}

/// The isolated entry point triggered by AndroidAlarmManager.
@pragma('vm:entry-point')
Future<void> performBackgroundDataFetch() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  debugPrint("\n=================================================");
  debugPrint("⚡ [Background Isolate] AWAKE AND RUNNING!");
  debugPrint("📱 Platform: ${Platform.operatingSystem.toUpperCase()}");
  debugPrint("⏰ Wake-Up Time: ${DateTime.now()}");
  debugPrint("=================================================\n");

  try {
    final handleRaw = await BackgroundStorage.getCallbackHandle();
    if (handleRaw == null) return;

    final callbackHandle = CallbackHandle.fromRawHandle(handleRaw);
    final fetchFunction =
        PluginUtilities.getCallbackFromHandle(callbackHandle)
            as Future<Map<String, dynamic>> Function()?;

    if (fetchFunction != null) {
      if (Platform.isAndroid) {
        debugPrint("🔒 [Wakelock] Acquiring CPU lock...");
        await backgroundChannel.invokeMethod('acquireWakelock', {
          'timeoutMs': 30000,
        });
      }

      debugPrint("⚙️ [Background Isolate] Executing developer callback...");

      final Map<String, dynamic> payload = await fetchFunction();

      await BackgroundStorage.insertRecord(payload);
      FlutterBackgroundService().invoke('recordUpdated');

      if (Platform.isAndroid) {
        debugPrint("🔓 [Wakelock] Releasing CPU lock...");
        await backgroundChannel.invokeMethod('releaseWakelock');
      }
    }

    if (Platform.isAndroid) {
      final interval = await BackgroundStorage.getSavedInterval();
      await scheduleAndroidExactAlarm(interval);
    }
  } catch (err) {
    debugPrint("❌ [Background Isolate] Fatal task error: $err");
  } finally {
    if (Platform.isAndroid) {
      try {
        await backgroundChannel.invokeMethod('releaseWakelock');
      } catch (_) {}
    }
  }
}

/// The isolated entry point triggered by iOS BGTaskScheduler.
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  debugPrint("🍏 [iOS Background] Triggered by BGTaskScheduler.");
  await performBackgroundDataFetch();
  return true;
}

/// Required entry point for the foreground service wrapper.
@pragma('vm:entry-point')
void onForegroundServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  debugPrint("🛡️ [Foreground Service] Started successfully.");

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: "System Sync",
      content: "Running optimization",
    );
  }

  service.on('stopService').listen((event) {
    debugPrint("🛑 [Foreground Service] Stop command received.");
    _iosExactTimer?.cancel(); // Kill the iOS timer on stop
    service.stopSelf();
  });

  // =========================================================
  // iOS FOREGROUND EXACT TIMING
  // =========================================================
  if (Platform.isIOS) {
    _scheduleIosExactTimer();

    service.on('updateTimer').listen((event) {
      debugPrint("🍏 [iOS Engine] Interval changed! Recalculating schedule...");
      _scheduleIosExactTimer();
    });
  }
}
