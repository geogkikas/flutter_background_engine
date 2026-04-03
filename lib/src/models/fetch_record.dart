import 'dart:convert';

/// Represents a single snapshot of data retrieved during a background fetch.
class FetchRecord {
  /// The local SQLite database ID. Null if the record is not yet persisted.
  final int? sqliteId;

  /// Epoch timestamp (milliseconds since 1970) representing the exact absolute moment.
  final int timestamp;

  /// The dynamic JSON payload returned by your custom fetch callback.
  final Map<String, dynamic> payload;

  /// Indicates whether this record has been successfully synced to a remote server.
  final bool isSynced;

  const FetchRecord({
    this.sqliteId,
    required this.timestamp,
    required this.payload,
    this.isSynced = false,
  });

  factory FetchRecord.fromJson(Map<String, dynamic> json) {
    final payloadString = json['payload'] as String?;
    final Map<String, dynamic> parsedPayload = payloadString != null
        ? jsonDecode(payloadString)
        : {};

    return FetchRecord(
      sqliteId: json['sqlite_id'],
      timestamp: json['timestamp'] as int? ?? 0, // Extracted as integer
      payload: parsedPayload,
      isSynced: json['is_synced'] == 1 || json['is_synced'] == true,
    );
  }
}
