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

  debugPrint("🛰️ [ENGINE] 📅 Android Alarm scheduled for: ${targetTime.toLocal()}");

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

  debugPrint("🛰️ [ENGINE] 📅 iOS Heartbeat timer set for: ${targetTime.toLocal()} (in ${duration.inSeconds}s)");

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

  debugPrint("⚡ [WAKE] ⏰ Background isolate active at ${DateTime.now().toLocal()}");

  try {
    final handleRaw = await BackgroundStorage.getCallbackHandle();
    if (handleRaw == null) return;

    final callbackHandle = CallbackHandle.fromRawHandle(handleRaw);
    final fetchFunction =
        PluginUtilities.getCallbackFromHandle(callbackHandle)
            as Future<Map<String, dynamic>> Function()?;

    if (fetchFunction != null) {
      if (Platform.isAndroid) {
        debugPrint("⚡ [WAKE] 🔒 CPU Wakelock acquired.");
        await backgroundChannel.invokeMethod('acquireWakelock', {
          'timeoutMs': 60000,
        });
      }

      debugPrint("⚡ [WAKE] ⚙️ Executing developer callback...");

      final Map<String, dynamic> payload = await fetchFunction();

      await BackgroundStorage.insertRecord(payload);
      FlutterBackgroundService().invoke('recordUpdated');

      if (Platform.isAndroid) {
        debugPrint("⚡ [WAKE] 🔓 CPU Wakelock released.");
        await backgroundChannel.invokeMethod('releaseWakelock');
      }
    }
  } catch (err) {
    debugPrint("⚡ [WAKE] ❌ Isolate Task Error: $err");
  } finally {
    if (Platform.isAndroid) {
      try {
        final interval = await BackgroundStorage.getSavedInterval();
        await scheduleAndroidExactAlarm(interval);
      } catch (e) {
        debugPrint("⚡ [WAKE] ⚠️ Failed to reschedule: $e");
      }
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
  debugPrint("🍏 [WAKE] 📦 iOS BGTask triggered.");
  await performBackgroundDataFetch();
  return true;
}

/// Required entry point for the foreground service wrapper.
@pragma('vm:entry-point')
void onForegroundServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  debugPrint("🛰️ [ENGINE] 🛡️ Foreground Service wrapper active.");

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: "System Sync",
      content: "Running optimization",
    );
  }

  service.on('stopService').listen((event) {
    debugPrint("🛰️ [ENGINE] 🛑 Foreground Service stop requested.");
    _iosExactTimer?.cancel(); // Kill the iOS timer on stop
    service.stopSelf();
  });

  // =========================================================
  // iOS FOREGROUND EXACT TIMING
  // =========================================================
  if (Platform.isIOS) {
    _scheduleIosExactTimer();

    service.on('updateTimer').listen((event) {
      debugPrint("🛰️ [ENGINE] 🍏 iOS timing interval updated.");
      _scheduleIosExactTimer();
    });
  }
}
