import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'background_storage.dart';

const int _androidAlarmId = 4242;

/// Calculates the exact next trigger time, snapping to the minute interval.
/// Bases the math on the exact moment the payload FINISHED processing.
DateTime _calculateNextExactTrigger(int intervalMinutes) {
  final now = DateTime.now(); // Captured AFTER the async task completes

  final int minutesToNext = intervalMinutes - (now.minute % intervalMinutes);

  DateTime targetTime = DateTime(
    now.year,
    now.month,
    now.day,
    now.hour,
    now.minute + minutesToNext,
    0, // Force 0 seconds
    0, // Force 0 milliseconds
  );

  // EDGE CASE FAILSAFE:
  // If the OS fired slightly early (e.g., 11:59:58) and the task was super fast (1 sec),
  // targetTime (12:00:00) is only 1 second away. We don't want it to run again instantly.
  // If the target is less than 10 seconds away, bump it to the next full cycle.
  if (targetTime.difference(now).inSeconds < 10) {
    targetTime = targetTime.add(Duration(minutes: intervalMinutes));
  }

  return targetTime;
}

/// The isolated entry point triggered by AndroidAlarmManager.
@pragma('vm:entry-point')
Future<void> performBackgroundDataFetch() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  debugPrint("\n=================================================");
  debugPrint("⚡ [Background Isolate] AWAKE AND RUNNING!");
  debugPrint("⏰ Wake-Up Time: ${DateTime.now()}");
  debugPrint("=================================================");

  try {
    // 1. Retrieve the registered fetch function
    final handleRaw = await BackgroundStorage.getCallbackHandle();
    if (handleRaw == null) {
      debugPrint(
        "❌ [Background Isolate] No callback function registered! Aborting.",
      );
      return;
    }

    final callbackHandle = CallbackHandle.fromRawHandle(handleRaw);
    final fetchFunction =
        PluginUtilities.getCallbackFromHandle(callbackHandle)
            as Future<Map<String, dynamic>> Function()?;

    if (fetchFunction != null) {
      debugPrint("⚙️ [Background Isolate] Executing developer callback...");

      final Map<String, dynamic> payload = await fetchFunction();

      debugPrint("📦 [Background Isolate] Payload Fetched:");
      debugPrint(jsonEncode(payload));

      // 2. Save the result
      await BackgroundStorage.insertRecord(payload);
      FlutterBackgroundService().invoke('recordUpdated');
    }

    // 3. Reschedule precisely for Android
    if (Platform.isAndroid) {
      final interval = await BackgroundStorage.getSavedInterval();
      final nextTrigger = _calculateNextExactTrigger(interval);

      debugPrint("🔗 [Chaining] Next alarm snapped to clock: $nextTrigger");

      await AndroidAlarmManager.oneShotAt(
        nextTrigger,
        _androidAlarmId,
        performBackgroundDataFetch,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
      );
    }
  } catch (err) {
    debugPrint("❌ [Background Isolate] Fatal task error: $err");
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
      title: "Background Engine Active",
      content: "Running scheduled background tasks...",
    );
  }

  service.on('stopService').listen((event) {
    debugPrint("🛑 [Foreground Service] Stop command received.");
    service.stopSelf();
  });
}
