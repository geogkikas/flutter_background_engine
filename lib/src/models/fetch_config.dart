/// Configuration model for the background fetch scheduler.
class FetchConfig {
  /// The exact interval in minutes at which the background task should run.
  /// Minimum recommended is 15 minutes due to OS battery optimizations.
  final int intervalMinutes;

  const FetchConfig({this.intervalMinutes = 15});

  Map<String, dynamic> toJson() => {'intervalMinutes': intervalMinutes};

  factory FetchConfig.fromJson(Map<String, dynamic> json) =>
      FetchConfig(intervalMinutes: json['intervalMinutes'] ?? 15);
}
