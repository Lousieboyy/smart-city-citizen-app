import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import '../user_session.dart';

/// A status-change record emitted by NotificationService.
class StatusChange {
  final int    reportId;
  final String category;
  final String oldStatus;
  final String newStatus;

  const StatusChange({
    required this.reportId,
    required this.category,
    required this.oldStatus,
    required this.newStatus,
  });
}

/// NotificationService — lightweight polling-based in-app notification system.
///
/// WHY: FCM requires Firebase project setup, google-services.json and a push
/// notification server — too much overhead for a local PSM project. Instead
/// this service polls the backend every 60 seconds and emits a [StatusChange]
/// whenever a report's status has changed since the last poll.
///
/// HOW: Call [start] after login and [stop] on logout.
/// Subscribe to [changes] to receive real-time status updates in the UI.
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  /// Broadcast stream of status changes. Listen to this in your UI widgets.
  final _controller = StreamController<StatusChange>.broadcast();
  Stream<StatusChange> get changes => _controller.stream;

  Timer?              _timer;
  Map<int, String>    _lastKnownStatuses = {};

  /// Start polling every [intervalSeconds] seconds.
  void start({int intervalSeconds = 60}) {
    stop(); // cancel any previous timer first
    _fetchAndCompare(); // immediate first check
    _timer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _fetchAndCompare(),
    );
    debugPrint('[NotificationService] Started polling every ${intervalSeconds}s');
  }

  /// Stop polling (call on logout or app dispose).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastKnownStatuses.clear();
    debugPrint('[NotificationService] Stopped');
  }

  Future<void> _fetchAndCompare() async {
    final session = UserSession.instance;
    if (!session.isLoggedIn) return;

    try {
      final response = await ApiService.getReports(
        userId:   session.role == 'citizen' ? session.userId : null,
        role:     session.role,
        username: session.username,
      );
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as List;
      final Map<int, String> currentStatuses = {};

      for (final report in data) {
        final id     = (report['id'] as int?) ?? -1;
        final status = (report['status'] as String?) ?? 'Pending';
        currentStatuses[id] = status;

        // If we have a previous snapshot, compare
        if (_lastKnownStatuses.containsKey(id)) {
          final prev = _lastKnownStatuses[id]!;
          if (prev != status) {
            final cat = (report['categories'] as String?) ?? 'Report';
            _controller.add(StatusChange(
              reportId:  id,
              category:  cat,
              oldStatus: prev,
              newStatus: status,
            ));
            debugPrint('[NotificationService] Report #$id changed: $prev → $status');
          }
        }
      }

      // Update snapshot (only after first poll so we don't fire on startup)
      if (_lastKnownStatuses.isNotEmpty) {
        _lastKnownStatuses = currentStatuses;
      } else {
        // First poll — store baseline without firing notifications
        _lastKnownStatuses = currentStatuses;
      }
    } catch (e) {
      debugPrint('[NotificationService] Poll error: $e');
    }
  }
}
