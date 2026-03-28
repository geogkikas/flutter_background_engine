# background_data_fetcher 🛰️

A robust, plug-and-play Flutter library for executing background tasks and storing the results in a local SQLite database.

Designed to survive aggressive Android background limitations (OEM-specific RAM cleaners) and handle the complexities of cross-isolate communication. By decoupling the background engine from the data payload, this kit acts as a blank canvas—you provide the data-fetching function, and this library guarantees it runs exactly on time, every time.




## ✨ Features

* **Permission Agnostic:** The library focuses purely on execution and storage. You handle the UX of requesting permissions (Notifications, Alarms, Location) in your main app, and this engine handles the rest.

* **Generic Payload Execution:** Pass any top-level Dart function. The engine executes it in the background and saves whatever Map<String, dynamic> it returns.

* **Clock-Aligned Logging:** Data collection triggers at exact clock intervals (e.g., exactly at 12:00, 12:15, 12:30) using precise OS-level alarms rather than random offsets.

* **Isolate-Safe Storage:** Background tasks log data directly to local SQLite storage with built-in synchronization tracking.

* **Platform Native Support:** Android 14 Ready (foregroundServiceType: dataSync) and integrated with iOS BGTaskScheduler.




## 📦 Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  background_data_fetcher:
    git:
      url: https://github.com/geogkikas/background_data_fetcher.git
      ref: main
```





## 🛠️ Native Setup (Required)

Because this library operates while the screen is off, you must configure your native OS files. **If you intend to fetch Location data inside your background callback, you must follow the specific "Location" steps below to avoid app crashes.**

### 🍎 iOS Setup

#### 1. Register the Task (`ios/Runner/AppDelegate.swift`)
```swift
import UIKit
import Flutter
import flutter_background_service_ios // <--- 1. Add this import

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // 2. Register the background task (Must match the Info.plist below)
        SwiftFlutterBackgroundServicePlugin.taskIdentifier = "dev.flutter.background.refresh"

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
```

#### 2. Configure Core Background Modes (`ios/Runner/Info.plist`)

Add the standard background execution privileges:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
<string>dev.flutter.background.refresh</string>
</array>
<key>UIBackgroundModes</key>
<array>
<string>fetch</string>
<string>processing</string>
</array>
```


#### 3. If Fetching Location in the Background (Optional)

If the callback function you pass to this engine fetches GPS data (e.g., using [device_context](https://github.com/geogkikas/device_context)), you must add the `location` background mode to the array above:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
<string>dev.flutter.background.refresh</string>
</array>
<key>UIBackgroundModes</key>
<array>
<string>fetch</string>
<string>processing</string>
<string>location</string>
</array>
```


#### 4. The Xcode Step (Crucial)

Modifying the `Info.plist` manually is sometimes overridden by Xcode. To ensure it works:

1. Open `ios/Runner.xcworkspace` in Xcode.

2. Select your `Runner` target on the left.

3. Go to the **Signing & Capabilities** tab.

4. Click + Capability (top left) and double-click **Background Modes**.

5. Check the boxes for **Background fetch** and **Background processing** (and **Location updates** if applicable).




### 🤖 Android Setup

Good news! The core library automatically merges all required scheduling permissions (`WAKE_LOCK`, `SCHEDULE_EXACT_ALARM`, etc.) into your app. However, if you are fetching Location data in the background, you must explicitly upgrade your app's Foreground Service type.

**Overriding the Service Type** (`android/app/src/main/AndroidManifest.xml`)
If you are using location in your background callback, add the tools namespace to your <manifest> tag, and override the default dataSync service to include location:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <application>
        <service
            android:name="id.flutter.flutter_background_service.BackgroundService"
            android:foregroundServiceType="location|dataSync"
            tools:replace="android:foregroundServiceType"
            android:exported="true" />

    </application>
</manifest>
```



> **🔐 Runtime Permissions Note:** Starting in Android 13/14, you must explicitly request `Permission.notification` and `Permission.scheduleExactAlarm` in your host app's UI *before* starting this engine, otherwise the foreground service will fail to launch.
---

> **⚠️ Google Play Note:** If you declare `foregroundServiceType="location"`, Google Play requires you to submit a "Location Permissions Declaration" video during your app review demonstrating why continuous background location is critical to your app's core functionality.




## 🚀 Quick Start

We built this kit so you can focus on your app's logic, not the background engine.

### 1. Define Your Background Task

Create a top-level function (outside of any class) that returns a `Map<String, dynamic>`. This function will run in an isolated memory space when the screen is off.

```dart
// Must be top-level and use @pragma('vm:entry-point')
@pragma('vm:entry-point')
Future<Map<String, dynamic>> myBackgroundFetch() async {
  // Fetch your data here (e.g., using device_context or an API)
  return {
    'battery': 85,
    'status': 'Healthy',
    'custom_metric': 42.5,
  };
}
```





### 2. Initialize and Start

Call `initAndStart()` in your `main.dart`. It automatically handles the background isolate and schedules the exact alarms.

```dart
import 'package:flutter/material.dart';
import 'package:background_data_fetcher/background_data_fetcher.dart';
import 'package:permission_handler/permission_handler.dart'; // Handled by host app

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Request OS execution permissions in your app's UI
  await Permission.notification.request();
  // Android 12+ requires explicit permission for exact alarms
  await Permission.scheduleExactAlarm.request();

  // 2. Setup and start the engine, passing your callback
  bool started = await BackgroundDataFetcher.initializeAndStart(
    fetchCallback: myBackgroundFetch,
    config: const FetchConfig(
      intervalMinutes: 15, // Logs exactly on the 15-minute marks
    ),
  );

  runApp(const MyApp());
}
```



### 3. Retrieve the Data

Whenever your UI wakes up, simply pull the unsynced logs.

```dart
void syncDataToServer() async {
  List<FetchRecord> records = await BackgroundDataFetcher.getUnsyncedRecords();

  for (var record in records) {
    print("Time: ${record.timestamp}");

    // Access your custom JSON payload directly!
    print("Battery: ${record.payload['battery']}%");
    print("Status: ${record.payload['status']}");
  }

  // Once sent to your API, mark them as synced so they aren't pulled again:
  List<int> syncedIds = records.map((e) => e.sqliteId!).toList();
  await BackgroundDataFetcher.markAsSynced(syncedIds);
}
```





## ⚙️ Configuration (`FetchConfig`)

You can deeply customize the battery impact of your background isolate by toggling specific hardware features.

| Property          | Type   | Default | Description                                                       |
|:------------------|:-------|:--------|:------------------------------------------------------------------|
| `intervalMinutes` | `int`  | `15`    | The frequency of data collection. Hardware-aligned to the minute. |






## 📊 The Data Model (FetchRecord)

No more guessing map keys. The library returns a strongly typed model for absolute safety:

```dart
class FetchRecord {
  final int? sqliteId;                // The local database row ID
  final String timestamp;             // ISO-8601 string of collection time
  final Map<String, dynamic> payload; // Your custom data returned from the callback
  final bool isSynced;                // Whether this has been marked as synced
}
```




## 🛠️ Advanced API Usage

If you need manual control over the service lifecycle, `BackgroundDataFetcher` exposes the following methods:

- **`BackgroundDataFetcher.updateInterval(int minutes)`**: Change the hardware alarm frequency on the fly.

- **`BackgroundDataFetcher.stop()`**: Kills the foreground service and cancels all future hardware alarms.

- **`BackgroundDataFetcher.getHistory()`**: Returns all records ever recorded on the device.

- **`BackgroundDataFetcher.getUnsyncedRecords()`**: Returns only records that haven't been marked as synced.

- **`BackgroundDataFetcher.markAsSynced(List<int> ids)`**: Flags specific records as synced.

- **`BackgroundDataFetcher.revertAllSyncedStatus()`**: Un-flags all previously synced records (useful for testing/recovery).

- **`BackgroundDataFetcher.clearHistory()`**: Wipes the local SQLite database to free up device space.

- **`BackgroundDataFetcher.isRunning()`**: Returns a boolean indicating if the background isolate is currently alive.

    
---

> **💡 Tip:** Combine this library with the [device_context](https://github.com/geogkikas/device_context) plugin to effortlessly fetch Deep Hardware Diagnostics, OS AI Activity, and Thermal data inside your background callback!
