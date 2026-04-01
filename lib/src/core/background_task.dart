import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'background_storage.dart';

const int _androidAlarmId = 4242;
const MethodChannel _channel = MethodChannel('background_data_fetcher');

// --- Add this variable for iOS ---
Timer? _iosExactTimer;

/// Calculates the exact next trigger time, snapping to the minute interval.
DateTime _calculateNextExactTrigger(int intervalMinutes) {
  final now = DateTime.now();
  final int minutesToNext = intervalMinutes - (now.minute % intervalMinutes);

  DateTime targetTime = DateTime(
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

// --- Add this precise recursive scheduling function for iOS ---
void _scheduleIosExactTimer() async {
  _iosExactTimer?.cancel();

  final isActive = await BackgroundStorage.isServiceActive();
  if (!isActive) return;

  final interval = await BackgroundStorage.getSavedInterval();
  final targetTime = _calculateNextExactTrigger(interval);
  final duration = targetTime.difference(DateTime.now());

  // Cancel again AFTER the async gap to destroy duplicate race-condition timers!
  _iosExactTimer?.cancel();

  debugPrint("\n=================================================");
  debugPrint("📅 [Task Scheduler] EXACT ALARM SCHEDULED");
  debugPrint("📱 Platform: iOS (Foreground Heartbeat)");
  debugPrint("🎯 Target Execution: $targetTime (in ${duration.inSeconds}s)");
  debugPrint("=================================================\n");

  _iosExactTimer = Timer(duration, () async {
    await performBackgroundDataFetch();
    _scheduleIosExactTimer(); // Loop the timer precisely
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
      // 🚀 1. ACQUIRE WAKELOCK (We request 30 seconds max to cover the 20s sensor window)
      if (Platform.isAndroid) {
        debugPrint("🔒 [Wakelock] Acquiring CPU lock...");
        await _channel.invokeMethod('acquireWakelock', {'timeoutMs': 30000});
      }

      debugPrint("⚙️ [Background Isolate] Executing developer callback...");

      // Now the CPU is locked awake. This 20 second await will run flawlessly!
      final Map<String, dynamic> payload = await fetchFunction();

      await BackgroundStorage.insertRecord(payload);
      FlutterBackgroundService().invoke('recordUpdated');

      // 🚀 2. RELEASE WAKELOCK
      if (Platform.isAndroid) {
        debugPrint("🔓 [Wakelock] Releasing CPU lock...");
        await _channel.invokeMethod('releaseWakelock');
      }
    }

    if (Platform.isAndroid) {
      final interval = await BackgroundStorage.getSavedInterval();
      final nextTrigger = _calculateNextExactTrigger(interval);

      debugPrint("\n=================================================");
      debugPrint("📅 [Task Scheduler] EXACT ALARM SCHEDULED");
      debugPrint("📱 Platform: ANDROID (AlarmManager)");
      debugPrint("🎯 Target Execution: $nextTrigger");
      debugPrint("=================================================\n");

      await AndroidAlarmManager.oneShotAt(
        nextTrigger,
        _androidAlarmId, // Using the variable you already declared
        performBackgroundDataFetch,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: true,
        allowWhileIdle: true,
      );
    }
  } catch (err) {
    debugPrint("❌ [Background Isolate] Fatal task error: $err");
  } finally {
    // 🚀 3. SAFETY RELEASE: Ensure we don't drain the battery if Dart crashes
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('releaseWakelock');
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
    // 1. Start the precise recursive timer chain
    _scheduleIosExactTimer();

    // 2. Listen for 'updateInterval' events from the UI Isolate
    service.on('updateTimer').listen((event) {
      debugPrint("🍏 [iOS Engine] Interval changed! Recalculating schedule...");
      _scheduleIosExactTimer();
    });
  }
}
