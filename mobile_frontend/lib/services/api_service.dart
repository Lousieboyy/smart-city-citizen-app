import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../app_config.dart';
import '../user_session.dart';

/// Central API service for all backend communication.
///
/// CHANGES vs original:
///   F-1  baseUrl moved to AppConfig (no more hardcoded IP in this file).
///   F-2  getReports now accepts a `username` param so workers are filtered
///        server-side by their assigned_worker name, not just by status.
///   JWT  Every protected request includes 'Authorization: Bearer <token>'.
///   PAG  getReports supports optional limit / offset for pagination.
class ApiService {
  // FIX F-1: URL comes from AppConfig so it can be overridden at build time.
  static String get baseUrl => AppConfig.baseUrl;

  /// Build auth headers with the current session token.
  static Map<String, String> get _authHeaders {
    final token = UserSession.instance.token;
    if (token == null || token.isEmpty) return {};
    return {'Authorization': 'Bearer $token'};
  }

  // ── Auth ────────────────────────────────────────────────────────────────
  // Login & Signup are intentionally PUBLIC — no token needed.

  static Future<http.Response> login(String username, String password) {
    return http.post(
      Uri.parse('$baseUrl/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    ).timeout(const Duration(seconds: 10));
  }

  static Future<http.Response> signup(String username, String password) {
    return http.post(
      Uri.parse('$baseUrl/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    ).timeout(const Duration(seconds: 10));
  }

  // ── Reports ─────────────────────────────────────────────────────────────

  static Future<http.Response> getStats(int userId) {
    return http
        .get(
          Uri.parse('$baseUrl/reports/stats?user_id=$userId'),
          headers: _authHeaders,
        )
        .timeout(const Duration(seconds: 10));
  }

  /// Fetch reports, with optional server-side filtering and pagination.
  ///
  /// [userId]   – citizen's own reports; pass for role=citizen.
  /// [role]     – 'citizen', 'worker', or 'admin'.
  /// [username] – worker's login name; required when role='worker'.
  /// [limit]    – max number of results (default 50, server caps at 200).
  /// [offset]   – skip this many results for pagination.
  static Future<http.Response> getReports({
    int? userId,
    String? role,
    String? username,
    int limit = 50,
    int offset = 0,
  }) {
    final uri = Uri.parse('$baseUrl/reports/').replace(queryParameters: {
      if (userId   != null) 'user_id':  userId.toString(),
      if (role     != null) 'role':     role,
      if (username != null) 'username': username,
      'limit':  limit.toString(),
      'offset': offset.toString(),
    });
    return http.get(uri, headers: _authHeaders).timeout(const Duration(seconds: 10));
  }

  // ── AI Prediction ────────────────────────────────────────────────────────

  /// Predict using a file path (mobile only).
  static Future<http.StreamedResponse> predict(String imagePath) {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/predict'));
    req.headers.addAll(_authHeaders);
    return http.MultipartFile.fromPath('file', imagePath).then((f) {
      req.files.add(f);
      return req.send().timeout(const Duration(seconds: 10));
    });
  }

  /// Predict using raw bytes (works on both web and mobile).
  static Future<http.StreamedResponse> predictBytes(
      Uint8List bytes, String filename) {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/predict'));
    req.headers.addAll(_authHeaders);
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    return req.send().timeout(const Duration(seconds: 10));
  }

  // ── Duplicate Check & Upvoting ──────────────────────────────────────────

  /// Check if a duplicate report exists near coordinates matching the categories.
  static Future<http.Response> checkDuplicate(
      double latitude, double longitude, String categories) {
    final uri = Uri.parse('$baseUrl/reports/check-duplicate').replace(
      queryParameters: {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'categories': categories,
        'radius_meters': '50.0',
      },
    );
    return http.get(uri, headers: _authHeaders).timeout(const Duration(seconds: 10));
  }

  /// Record an upvote for a duplicate report.
  static Future<http.Response> upvoteReport(int reportId) {
    return http.post(
      Uri.parse('$baseUrl/reports/$reportId/upvote'),
      headers: _authHeaders,
    ).timeout(const Duration(seconds: 10));
  }

  // ── Report Submission ────────────────────────────────────────────────────

  /// Submit using a file path (mobile only).
  static Future<http.StreamedResponse> submitReport(
      Map<String, String> fields, String imagePath) {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/reports/'));
    req.headers.addAll(_authHeaders);
    req.fields.addAll(fields);
    return http.MultipartFile.fromPath('file', imagePath).then((f) {
      req.files.add(f);
      return req.send().timeout(const Duration(seconds: 15));
    });
  }

  /// Submit using raw bytes (works on both web and mobile).
  static Future<http.StreamedResponse> submitReportBytes(
      Map<String, String> fields, Uint8List bytes, String filename) {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/reports/'));
    req.headers.addAll(_authHeaders);
    req.fields.addAll(fields);
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    return req.send().timeout(const Duration(seconds: 15));
  }

  /// Start maintenance on a report (Worker accepts task).
  static Future<http.Response> startMaintenance(int reportId) {
    return http.post(
      Uri.parse('$baseUrl/reports/$reportId/start-maintenance'),
      headers: _authHeaders,
    ).timeout(const Duration(seconds: 10));
  }

  /// Complete task and submit proof (Worker completes task).
  static Future<http.StreamedResponse> completeTask(
      int reportId, String notes, String? imagePath) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('$baseUrl/reports/$reportId/complete-task'));
    req.headers.addAll(_authHeaders);
    req.fields['notes'] = notes;
    if (imagePath != null && imagePath.isNotEmpty) {
      final f = await http.MultipartFile.fromPath('file', imagePath);
      req.files.add(f);
    }
    return req.send().timeout(const Duration(seconds: 15));
  }
}

