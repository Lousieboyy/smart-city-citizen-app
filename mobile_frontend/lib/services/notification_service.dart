import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

/// NotificationService — lightweight polling-based in-app & system notification system.
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  /// Broadcast stream of status changes. Listen to this in your UI widgets.
  final _controller = StreamController<StatusChange>.broadcast();
  Stream<StatusChange> get changes => _controller.stream;

  Timer?              _timer;
  Map<int, String>    _lastKnownStatuses = {};

  // Team-pool awareness (workers only): who's watching the same crew/agency
  // pool. _poolInitialized guards the first poll after start/login so a
  // worker isn't told every pre-existing pool job is "new".
  Set<int> _lastKnownPoolIds = {};
  bool     _poolInitialized  = false;
  // Claims already announced to this worker, so a still-visible recent claim
  // isn't re-notified every poll; entries fall out once the server's
  // recent_claims window (and thus their presence here) expires.
  Set<int> _notifiedClaimIds = {};

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  bool _localNotifInitialized = false;

  /// Initialize local system notifications safely
  Future<void> initializeLocalNotifications() async {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux) return; // Skip native notifications on Web and Desktop to prevent platform setup errors
    if (_localNotifInitialized) return;

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );

    try {
      await _localNotifications.initialize(settings: initializationSettings);
      
      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();

      _localNotifInitialized = true;
      debugPrint('[NotificationService] System notifications initialized successfully.');
    } catch (e) {
      debugPrint('[NotificationService] System notifications init error: $e');
    }
  }

  /// Show a system-level alert with sound and vibration
  Future<void> showLocalNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return; // Skip native notifications on Web
    await initializeLocalNotifications();

    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
      'smart_city_reports_channel',
      'Smart City Reports Alerts',
      channelDescription: 'Status updates and proximity alerts for smart city reports.',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
      playSound: true,
      enableVibration: true,
    );

    const DarwinNotificationDetails darwinNotificationDetails =
        DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: darwinNotificationDetails,
    );

    try {
      await _localNotifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
      );
    } catch (e) {
      debugPrint('[NotificationService] System notification show error: $e');
    }
  }

  /// Fire a proximity alert system notification
  Future<void> fireProximityAlert({
    required int reportId,
    required String title,
    required String body,
  }) async {
    await showLocalNotification(
      id: 100000 + reportId,
      title: title,
      body: body,
    );
  }

  /// Start polling every [intervalSeconds] seconds.
  void start({int intervalSeconds = 60}) {
    stop(); // cancel any previous timer first
    initializeLocalNotifications(); // Ensure system notifications are set up
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
    _lastKnownPoolIds.clear();
    _notifiedClaimIds.clear();
    _poolInitialized = false;
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
            
            showLocalNotification(
              id: id,
              title: "Report Status Updated",
              body: "Your report for '$cat' is now $status (was $prev).",
            );
            
            debugPrint('[NotificationService] Report #$id changed: $prev → $status');
          }
        }
      }

      if (_lastKnownStatuses.isNotEmpty) {
        _lastKnownStatuses = currentStatuses;
      } else {
        _lastKnownStatuses = currentStatuses;
      }

      // Team pool awareness: only relevant to workers, and separate from the
      // per-report diff above because a brand-new pool job is not a "status
      // change" on anything this worker already knew about.
      if (session.role.toLowerCase().contains('worker')) {
        await _checkTeamPool();
        await _checkRecentClaims();
      }
    } catch (e) {
      debugPrint('[NotificationService] Poll error: $e');
    }
  }

  /// Notify once per job when it first appears in this worker's team/crew
  /// pool — this is "Ali and Abu get notified when Team A gets a job".
  Future<void> _checkTeamPool() async {
    try {
      final response = await ApiService.getTeamPool();
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as List;
      final currentIds = <int>{};

      for (final report in data) {
        final id = (report['id'] as int?) ?? -1;
        currentIds.add(id);

        if (_poolInitialized && !_lastKnownPoolIds.contains(id)) {
          final cat = (report['categories'] as String?) ?? 'Report';
          showLocalNotification(
            id: 200000 + id,
            title: "New Job in Your Team Pool",
            body: "A '$cat' job is available — first to accept gets it.",
          );
          debugPrint('[NotificationService] New pool job #$id ($cat)');
        }
      }

      _lastKnownPoolIds = currentIds;
      _poolInitialized = true;
    } catch (e) {
      debugPrint('[NotificationService] Pool poll error: $e');
    }
  }

  /// Notify the rest of the crew when a teammate claims a job, so it doesn't
  /// just silently vanish from their pool with no explanation.
  Future<void> _checkRecentClaims() async {
    try {
      final response = await ApiService.getRecentTeamClaims();
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as List;
      final currentIds = <int>{};

      for (final report in data) {
        final id = (report['id'] as int?) ?? -1;
        currentIds.add(id);

        if (!_notifiedClaimIds.contains(id)) {
          final cat    = (report['categories']      as String?) ?? 'Report';
          final worker = (report['assigned_worker']  as String?) ?? 'A teammate';
          showLocalNotification(
            id: 300000 + id,
            title: "Job Claimed",
            body: "$worker accepted the '$cat' job.",
          );
          debugPrint('[NotificationService] Teammate claim #$id by $worker');
        }
      }

      // Replacing rather than merging keeps this bounded: an id that ages out
      // of the server's recent-claims window drops out here too, so if it
      // were ever claimed again later it would correctly notify again.
      _notifiedClaimIds = currentIds;
    } catch (e) {
      debugPrint('[NotificationService] Recent-claims poll error: $e');
    }
  }
}
