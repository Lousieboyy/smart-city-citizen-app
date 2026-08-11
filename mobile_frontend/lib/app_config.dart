import 'package:flutter/foundation.dart';

/// Application-wide constants and configuration.
///
/// WHY: The original code had the backend IP address hardcoded in api_service.dart
/// (F-1). Putting it here makes it trivial to change for different environments
/// (local dev, staging, production) without touching business logic files.
///
/// HOW TO USE: Pass --dart-define=BASE_URL=https://prod.example.com to override
/// the default at build time without modifying source code.
class AppConfig {
  static const String _envUrl = String.fromEnvironment('BASE_URL');

  // Base URL of the FastAPI backend.
  static String get baseUrl {
    if (_envUrl.isNotEmpty) return _envUrl;
    return 'https://smart-city-citizen-app-git-main-lousieboyys-projects.vercel.app';
  }
}

/// Canonical status string constants that EXACTLY match what the backend returns.
///
/// WHY: The original history_screen.dart used 'In Progress' and 'Forwarded' as
/// filter values (F-8), but the backend sends 'In Process', 'In Review', etc.
/// Using this class everywhere prevents that mismatch from silently returning
/// empty filter results.
class ReportStatus {
  static const String pending       = 'Pending';
  static const String inReview      = 'In Review';
  static const String inProcess     = 'In Process';
  static const String inMaintenance = 'In Maintenance';
  static const String resolved      = 'Resolved';
  static const String rejected      = 'Rejected';

  /// All statuses in workflow order.
  static const List<String> all = [
    pending,
    inReview,
    inProcess,
    inMaintenance,
    resolved,
    rejected,
  ];
}
