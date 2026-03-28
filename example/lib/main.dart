import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:background_data_fetcher/background_data_fetcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_context/device_context.dart';

// =================================================================
// TOP-LEVEL CALLBACK FOR BACKGROUND ENGINE
// =================================================================
@pragma('vm:entry-point')
Future<Map<String, dynamic>> fetchDeviceDataCallback() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // 1. Fetch data using the elegant Configuration Objects
    final data = await DeviceContext.getSensorData(
      hardware: const HardwareConfig(
        deviceInfo: true,
        batteryStatus: true,
        instantElectricalDraw: true,
        thermalState: true,
        batteryHealth: true,
      ),
      instantSensors: const InstantSensorsConfig(
        ambientLight: true,
        location: true,
        motionAndPosture: true,
        aiActivityPrediction: true,
      ),
      continuousSampling: const ContinuousSamplingConfig(
        window: Duration(seconds: 15),
        samplingRateHz: 20,
        averageElectricalDraw: true,
        averageMotionState: true,
        averageAmbientLight: true,
      ),
    );

    return data.toMap();
  } catch (e) {
    debugPrint("Background Fetch Error: $e");
    return {'error': e.toString()};
  }
}
// =================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SensorKitExampleApp());
}

class SensorKitExampleApp extends StatelessWidget {
  const SensorKitExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Context Engine Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<FetchRecord> _records = [];
  bool _isLoading = false;
  bool _isServiceRunning = false;
  int _currentInterval = 15;

  Timer? _uiHeartbeat;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _checkServiceStatus();
    _fetchData();
    _startHeartbeat();
  }

  @override
  void dispose() {
    _uiHeartbeat?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkServiceStatus();
      _fetchData();
    }
  }

  void _startHeartbeat() {
    _uiHeartbeat = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_isServiceRunning && mounted) {
        _fetchData(silent: true);
      }
    });
  }

  Future<void> _checkServiceStatus() async {
    final isRunning = await BackgroundDataFetcher.isRunning();

    // Read the interval from SharedPreferences (matching our internal storage key)
    final prefs = await SharedPreferences.getInstance();
    final interval = prefs.getInt('fbe_sampling_interval') ?? 15;

    if (mounted) {
      setState(() {
        _isServiceRunning = isRunning;
        _currentInterval = interval;
      });
    }
  }

  Future<void> _fetchData({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() => _isLoading = true);

    await _checkServiceStatus();
    final records = await BackgroundDataFetcher.getUnsyncedRecords();

    if (mounted) {
      if (_records.length != records.length || !silent) {
        setState(() {
          _records = records.reversed.toList();
          _isLoading = false;
        });
      } else {
        if (!silent) setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _syncDataToServer() async {
    if (_records.isEmpty) return;
    setState(() => _isLoading = true);

    List<int> idsToSync = _records.map((record) => record.sqliteId!).toList();
    await BackgroundDataFetcher.markAsSynced(idsToSync);
    await _fetchData();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Data successfully synced!')),
      );
    }
  }

  Future<void> _revertSync() async {
    setState(() => _isLoading = true);
    await BackgroundDataFetcher.revertAllSyncedStatus();
    await _fetchData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⏪ Synced records reverted!')),
      );
    }
  }

  Future<void> _deleteHistory() async {
    setState(() => _isLoading = true);
    await BackgroundDataFetcher.clearHistory();
    await _fetchData();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('🗑️ All history deleted!')));
    }
  }

  Future<void> _showIntervalDialog() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Select Logging Interval'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [1, 5, 15, 30, 60].map((min) {
              return ListTile(
                title: Text('$min Minute${min > 1 ? 's' : ''}'),
                trailing: _currentInterval == min
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(context, min),
              );
            }).toList(),
          ),
        );
      },
    );

    if (selected != null && selected != _currentInterval) {
      setState(() => _isLoading = true);
      await BackgroundDataFetcher.updateInterval(selected);
      await _checkServiceStatus();
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⏱️ Interval updated to $selected minutes.')),
        );
      }
    }
  }

  // =================================================================
  // START SERVICE & HANDLE PERMISSIONS MANUALLY
  // =================================================================
  Future<void> _startService() async {
    setState(() => _isLoading = true);

    // --- 1. Request Engine Permissions ---
    var notifStatus = await Permission.notification.request();
    bool exactAlarmGranted = true;

    if (Platform.isAndroid) {
      var alarmStatus = await Permission.scheduleExactAlarm.request();
      exactAlarmGranted = alarmStatus.isGranted;
    }

    if (!notifStatus.isGranted || !exactAlarmGranted) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Cannot start: Core engine permissions denied!'),
          ),
        );
      }
      return;
    }

    // --- 2. Request Hardware Permissions (for device_context) ---
    var locStatus = await Permission.locationWhenInUse.request();
    if (locStatus.isGranted) {
      await Permission.locationAlways
          .request(); // Try to upgrade for background
    } else {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Cannot start: Location permission required!'),
          ),
        );
      }
      return;
    }

    await Permission.activityRecognition.request();
    if (Platform.isIOS) {
      await Permission.sensors.request();
    }

    // --- 3. Start the Engine ---
    bool started = await BackgroundDataFetcher.initializeAndStart(
      fetchCallback: fetchDeviceDataCallback,
      config: FetchConfig(intervalMinutes: _currentInterval),
    );

    setState(() {
      _isServiceRunning = started;
      _isLoading = false;
    });

    if (mounted && started) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('🚀 Engine Started.')));
    }
  }

  Future<void> _stopService() async {
    setState(() => _isLoading = true);
    BackgroundDataFetcher.stop();

    setState(() {
      _isServiceRunning = false;
      _isLoading = false;
    });

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('🛑 Engine Stopped.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Background Context'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Refresh Local Logs",
            onPressed: () => _fetchData(silent: false),
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            tooltip: "Simulate Server Sync",
            onPressed: _syncDataToServer,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'interval') _showIntervalDialog();
              if (value == 'revert') _revertSync();
              if (value == 'delete') _deleteHistory();
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(
                value: 'interval',
                child: Row(
                  children: [
                    Icon(Icons.timer, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Change Interval'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'revert',
                child: Row(
                  children: [
                    Icon(Icons.undo, color: Colors.blue),
                    SizedBox(width: 8),
                    Text('Revert Synced Records'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Delete All History'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: _isServiceRunning
                ? Colors.green.shade100
                : Colors.red.shade100,
            child: Text(
              _isServiceRunning
                  ? "🟢 Engine Active ($_currentInterval min interval)."
                  : "🔴 Engine is currently Stopped.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          // Log List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                ? const Center(
                    child: Text(
                      "No unsynced records.\nMinimize the app and wait for an interval.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      final record = _records[index];
                      final payload = record.payload;

                      // Extract nested maps safely
                      final identity = payload['identity'] ?? {};
                      final battery = payload['battery'] ?? {};
                      final thermal = payload['thermal'] ?? {};
                      final env = payload['environment'] ?? {};
                      final loc = payload['location'] ?? {};
                      final motion = payload['motion'] ?? {};
                      final activity = payload['activity'] ?? {};

                      final time = DateTime.parse(record.timestamp).toLocal();
                      final formattedTime =
                          "${time.hour}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}";

                      // Safely format means
                      final meanCurrent = battery['meanCurrentMA'] != null
                          ? (battery['meanCurrentMA'] as num).toStringAsFixed(2)
                          : 'N/A';
                      final meanLux = env['meanLightLux'] != null
                          ? (env['meanLightLux'] as num).toStringAsFixed(2)
                          : 'N/A';
                      final meanAccelX = motion['meanAccelX'] != null
                          ? (motion['meanAccelX'] as num).toStringAsFixed(2)
                          : 'N/A';
                      final meanAccelY = motion['meanAccelY'] != null
                          ? (motion['meanAccelY'] as num).toStringAsFixed(2)
                          : 'N/A';
                      final meanAccelZ = motion['meanAccelZ'] != null
                          ? (motion['meanAccelZ'] as num).toStringAsFixed(2)
                          : 'N/A';

                      return Card(
                        elevation: 2,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // --- HEADER ---
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "Record at $formattedTime",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  CircleAvatar(
                                    radius: 18,
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer,
                                    child: Text(
                                      "${battery['level'] ?? '?'}%",
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "📱 ${identity['manufacturer']} ${identity['model']}  •  🔑 ${identity['deviceId']}",
                                style: const TextStyle(fontSize: 12),
                              ),
                              const Divider(height: 24),

                              // --- POWER & HEALTH ---
                              _buildSectionHeader("Battery & Power"),
                              _buildInfoRow(
                                "🔋 Status",
                                "State: ${battery['status']} • Plug: ${battery['pluggedStatus']}",
                              ),
                              _buildInfoRow(
                                "⚡ Draw",
                                "Instant: ${battery['currentNowMA']} mA • Mean: $meanCurrent mA",
                              ),
                              _buildInfoRow(
                                "🔌 Voltage",
                                "${battery['voltage']} mV",
                              ),
                              _buildInfoRow(
                                "❤️ Health",
                                "Code: ${battery['health']} • Cyc: ${battery['cycleCount']} • Cap: ${battery['chargeCounterMAh']} mAh",
                              ),

                              // --- ENVIRONMENT & LOCATION ---
                              _buildSectionHeader("Environment & Location"),
                              _buildInfoRow(
                                "🌡️ Temp",
                                "Bat: ${thermal['batteryTemp']}°C • CPU: ${thermal['cpuTemp']}°C (Thrml: ${thermal['thermalStatus']})",
                              ),
                              _buildInfoRow(
                                "☀️ Light",
                                "Instant: ${env['lightLux']} lux • Mean: $meanLux lux",
                              ),
                              _buildInfoRow(
                                "📍 GPS",
                                "${loc['latitude']}, ${loc['longitude']} (Alt: ${loc['altitude']}m)",
                              ),

                              // --- MOTION & AI ---
                              _buildSectionHeader("Motion & AI"),
                              _buildInfoRow(
                                "🧠 AI",
                                "${activity['activityType']} (${activity['activityConfidence']})",
                              ),
                              _buildInfoRow(
                                "🏃 Motion",
                                "Instant: ${motion['motionState']} • Mean: ${motion['meanMotionState']}",
                              ),
                              _buildInfoRow(
                                "📐 Posture",
                                "${motion['posture']}",
                              ),
                              _buildInfoRow(
                                "🙈 Proximity",
                                "${motion['proximityCm']} cm (Covered: ${motion['isCovered']})",
                              ),
                              _buildInfoRow(
                                "X Accel",
                                "Instant: ${motion['accelX']} • Mean: $meanAccelX",
                              ),
                              _buildInfoRow(
                                "Y Accel",
                                "Instant: ${motion['accelY']} • Mean: $meanAccelY",
                              ),
                              _buildInfoRow(
                                "Z Accel",
                                "Instant: ${motion['accelZ']} • Mean: $meanAccelZ",
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: _isServiceRunning
          ? FloatingActionButton.extended(
              onPressed: _stopService,
              backgroundColor: Colors.red.shade300,
              icon: const Icon(Icons.stop),
              label: const Text("Stop Engine"),
            )
          : FloatingActionButton.extended(
              onPressed: _startService,
              backgroundColor: Colors.green.shade400,
              icon: const Icon(Icons.play_arrow),
              label: const Text("Start Engine"),
            ),
    );
  }

  // --- UI Helpers for the Log Cards ---
  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0, top: 8.0),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
