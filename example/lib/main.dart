import 'dart:async';
import 'dart:io' show Platform, File;
import 'package:flutter/material.dart';
import 'package:background_data_fetcher/background_data_fetcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_context/device_context.dart';

// =================================================================
// 1. TOP-LEVEL CALLBACK FOR BACKGROUND ENGINE
// =================================================================
@pragma('vm:entry-point')
Future<Map<String, dynamic>> fetchDeviceDataCallback() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
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
// 2. MAIN APP
// =================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Background Engine',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
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
      if (_isServiceRunning && mounted) _fetchData(silent: true);
    });
  }

  Future<void> _checkServiceStatus() async {
    final isRunning = await BackgroundDataFetcher.isRunning();
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

  // =================================================================
  // 3. DATA EXPORT & SYNC LOGIC
  // =================================================================
  Future<void> _shareData() async {
    if (_records.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('⚠️ No data to share!')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      List<Map<String, dynamic>> flattenedRecords = [];
      Set<String> allKeys = {'timestamp'};

      for (var record in _records) {
        Map<String, dynamic> flatMap = {};
        _flattenMap(record.payload, '', flatMap);
        flatMap['timestamp'] = record.timestamp;
        allKeys.addAll(flatMap.keys);
        flattenedRecords.add(flatMap);
      }

      List<String> columns = allKeys.toList();
      StringBuffer csvBuffer = StringBuffer();
      csvBuffer.writeln(columns.join(','));

      for (var flatRecord in flattenedRecords) {
        List<String> rowValues = columns.map((col) {
          var value = flatRecord[col];
          if (value == null) return '';
          String strValue = value.toString();
          if (strValue.contains(',') ||
              strValue.contains('"') ||
              strValue.contains('\n')) {
            strValue = '"${strValue.replaceAll('"', '""')}"';
          }
          return strValue;
        }).toList();
        csvBuffer.writeln(rowValues.join(','));
      }

      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/sensor_data_export.csv');
      await file.writeAsString(csvBuffer.toString());

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Background Sensor Data Export',
        text: 'Attached is the CSV export.',
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('❌ Export failed: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _flattenMap(
    Map<String, dynamic> map,
    String prefix,
    Map<String, dynamic> result,
  ) {
    map.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        _flattenMap(value, '$prefix$key.', result);
      } else {
        result['$prefix$key'] = value;
      }
    });
  }

  Future<void> _syncDataToServer() async {
    if (_records.isEmpty) return;
    setState(() => _isLoading = true);
    List<int> idsToSync = _records.map((record) => record.sqliteId!).toList();
    await BackgroundDataFetcher.markAsSynced(idsToSync);
    await _fetchData();
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('✅ Data synced!')));
  }

  Future<void> _deleteHistory() async {
    setState(() => _isLoading = true);
    await BackgroundDataFetcher.clearHistory();
    await _fetchData();
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('🗑️ History deleted!')));
  }

  // =================================================================
  // 4. ENGINE CONTROLS & PERMISSIONS
  // =================================================================
  Future<void> _startService() async {
    setState(() => _isLoading = true);

    var notifStatus = await Permission.notification.request();
    bool exactAlarmGranted = true;

    if (Platform.isAndroid) {
      var alarmStatus = await Permission.scheduleExactAlarm.request();
      exactAlarmGranted = alarmStatus.isGranted;
    }

    if (!notifStatus.isGranted || !exactAlarmGranted) {
      setState(() => _isLoading = false);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Core engine permissions denied!')),
        );
      return;
    }

    var locStatus = await Permission.locationWhenInUse.request();
    if (locStatus.isGranted) {
      await Permission.locationAlways.request();
    } else {
      setState(() => _isLoading = false);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Location permission required!')),
        );
      return;
    }

    await Permission.activityRecognition.request();
    if (Platform.isIOS) await Permission.sensors.request();

    bool started = await BackgroundDataFetcher.initializeAndStart(
      fetchCallback: fetchDeviceDataCallback,
      config: FetchConfig(intervalMinutes: _currentInterval),
    );

    setState(() {
      _isServiceRunning = started;
      _isLoading = false;
    });

    if (mounted && started)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('🚀 Engine Started.')));
  }

  Future<void> _stopService() async {
    setState(() => _isLoading = true);
    BackgroundDataFetcher.stop();
    setState(() {
      _isServiceRunning = false;
      _isLoading = false;
    });
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('🛑 Engine Stopped.')));
  }

  Future<void> _showIntervalDialog() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Select Interval'),
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

    if (selected != null) {
      setState(() => _isLoading = true);
      try {
        await BackgroundDataFetcher.updateInterval(selected);
        await _checkServiceStatus();
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('⏱️ Interval updated.')));
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
          );
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Background Context'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(icon: const Icon(Icons.share), onPressed: _shareData),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _fetchData(silent: false),
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            onPressed: _syncDataToServer,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'interval') _showIntervalDialog();
              if (value == 'delete') _deleteHistory();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'interval',
                child: Text('Change Interval'),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete History'),
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
                  ? "🟢 Engine Active ($_currentInterval min)."
                  : "🔴 Engine Stopped.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
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
              label: const Text("Stop"),
            )
          : FloatingActionButton.extended(
              onPressed: _startService,
              backgroundColor: Colors.green.shade400,
              icon: const Icon(Icons.play_arrow),
              label: const Text("Start"),
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
