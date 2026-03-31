import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Handles all local persistence including SQLite data records and SharedPreferences config.
class BackgroundStorage {
  static const String _intervalKey = 'fbe_sampling_interval';
  static const String _handleKey = 'fbe_callback_handle';
  static const String _activeKey = 'fbe_is_active';

  static Database? _db;

  // MARK: - SharedPreferences Configuration

  static Future<int> getSavedInterval() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(_intervalKey) ?? 0;
  }

  static Future<void> saveInterval(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_intervalKey, minutes);
  }

  static Future<void> saveCallbackHandle(int handle) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_handleKey, handle);
  }

  static Future<int?> getCallbackHandle() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(_handleKey);
  }

  // MARK: - SQLite Database Management

  static Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDB('background_fetch_records.db');
    return _db!;
  }

  static Future<Database> _initDB(String fileName) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, fileName);

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            payload TEXT NOT NULL,
            is_synced INTEGER DEFAULT 0
          )
        ''');
      },
    );
  }

  /// Saves a new fetch payload to the local database and truncates old records to prevent bloat.
  static Future<void> insertRecord(Map<String, dynamic> payload) async {
    final db = await _database;
    final timestamp = DateTime.now().toIso8601String();

    await db.insert('records', {
      'timestamp': timestamp,
      'payload': jsonEncode(payload),
      'is_synced': 0,
    });

    debugPrint("💾 [BackgroundStorage] Payload saved at $timestamp.");

    // Auto-cleanup: Keep only the latest 50,000 records
    await db.execute('''
      DELETE FROM records 
      WHERE id NOT IN (SELECT id FROM records ORDER BY id DESC LIMIT 50000)
    ''');
  }

  /// Retrieves the most recent records, ordered from newest to oldest.
  static Future<List<Map<String, dynamic>>> getAllRecords({
    int limit = 1000,
  }) async {
    final db = await _database;
    final List<Map<String, dynamic>> maps = await db.query(
      'records',
      orderBy: 'id DESC',
      limit: limit,
    );
    return maps.map((row) => {...row, 'sqlite_id': row['id']}).toList();
  }

  /// Retrieves records that have not yet been marked as synced.
  static Future<List<Map<String, dynamic>>> getUnsyncedRecords({
    int limit = 500,
  }) async {
    final db = await _database;
    final List<Map<String, dynamic>> maps = await db.query(
      'records',
      where: 'is_synced = ?',
      whereArgs: [0],
      orderBy: 'id ASC', // Oldest first for syncing
      limit: limit,
    );
    return maps.map((row) => {...row, 'sqlite_id': row['id']}).toList();
  }

  /// Marks a specific list of SQLite IDs as successfully synced.
  static Future<void> markAsSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE records SET is_synced = 1 WHERE id IN ($placeholders)',
      ids,
    );
  }

  static Future<void> clearAllRecords() async {
    final db = await _database;
    await db.delete('records');
  }

  static Future<void> revertAllSyncedStatus() async {
    final db = await _database;
    await db.rawUpdate('UPDATE records SET is_synced = 0');
  }

  static Future<void> setServiceActive(bool isActive) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_activeKey, isActive);
  }

  static Future<bool> isServiceActive() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(_activeKey) ?? false;
  }
}
