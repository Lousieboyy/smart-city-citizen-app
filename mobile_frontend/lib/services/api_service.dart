import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
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

  static Future<http.Response> signup({
    required String username,
    required String password,
    required String fullName,
    required String icNumber,
    required String phoneNumber,
  }) {
    return http.post(
      Uri.parse('$baseUrl/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'fullName': fullName,
        'icNumber': icNumber,
        'phoneNumber': phoneNumber,
      }),
    ).timeout(const Duration(seconds: 10));
  }

  // ── Reports ─────────────────────────────────────────────────────────────

  static Future<http.Response> getStats([int? userId]) {
    final queryParam = userId != null ? '?user_id=$userId' : '';
    return http
        .get(
          Uri.parse('$baseUrl/reports/stats$queryParam'),
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
  /// [scope]    – worker only: 'mine' (claimed by me), 'pool' (unclaimed team
  ///              pool) or 'team' (both, the default).
  static Future<http.Response> getReports({
    int? userId,
    String? role,
    String? username,
    String? scope,
    int limit = 50,
    int offset = 0,
  }) {
    final uri = Uri.parse('$baseUrl/reports/').replace(queryParameters: {
      if (userId   != null) 'user_id':  userId.toString(),
      if (role     != null) 'role':     role,
      if (username != null) 'username': username,
      if (scope    != null) 'scope':    scope,
      'limit':  limit.toString(),
      'offset': offset.toString(),
    });
    return http.get(uri, headers: _authHeaders).timeout(const Duration(seconds: 10));
  }

  // ── Team pool ───────────────────────────────────────────────────────────
  // Work is dispatched to a team, sits in that team's shared pool, and the
  // first worker to claim it owns it.

  /// Unclaimed jobs in the caller's team pool.
  static Future<http.Response> getTeamPool({int limit = 50}) {
    return getReports(role: 'worker', scope: 'pool', limit: limit);
  }

  /// Jobs a teammate (same agency, same crew if any) claimed recently — the
  /// signal that turns "it silently vanished from my pool" into "Ali took it".
  static Future<http.Response> getRecentTeamClaims({int limit = 20}) {
    return getReports(role: 'worker', scope: 'recent_claims', limit: limit);
  }

  /// Claim a job from the team pool.
  ///
  /// A **409** means another worker claimed it first — callers should refresh
  /// the pool and tell the user, not retry.
  static Future<http.Response> claimTask(int reportId) {
    return http.post(
      Uri.parse('$baseUrl/reports/$reportId/claim'),
      headers: _authHeaders,
    ).timeout(const Duration(seconds: 10));
  }

  /// Hand a claimed job back to the team pool.
  static Future<http.Response> releaseTask(int reportId, {String reason = ''}) {
    return http.post(
      Uri.parse('$baseUrl/reports/$reportId/release'),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({'reason': reason}),
    ).timeout(const Duration(seconds: 10));
  }

  /// Ask an authority to move this job to another team.
  static Future<http.Response> requestTransfer(int reportId, {String reason = ''}) {
    return http.post(
      Uri.parse('$baseUrl/reports/$reportId/transfer-request'),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({'to_agency_id': null, 'reason': reason}),
    ).timeout(const Duration(seconds: 10));
  }

  /// Pull the server's error text so the UI can explain a refusal precisely.
  static String errorDetail(http.Response res, String fallback) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['detail'] is String) return body['detail'] as String;
    } catch (_) {
      // Non-JSON error body — fall through.
    }
    return fallback;
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
  ///
  /// [metadataBlob] is the leading slice of the *original* camera file. The
  /// image we upload for classification is downscaled, and re-encoding destroys
  /// the EXIF/XMP/C2PA blocks the backend uses to tell a real photo from a
  /// generated one. Those blocks all sit at the front of the file, so a partial
  /// copy is enough to preserve them.
  static Future<http.StreamedResponse> predictBytes(
      Uint8List bytes, String filename, {Uint8List? metadataBlob}) {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/predict'));
    req.headers.addAll(_authHeaders);
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    if (metadataBlob != null && metadataBlob.isNotEmpty) {
      req.files.add(http.MultipartFile.fromBytes(
          'metadata_blob', metadataBlob, filename: 'metadata.bin'));
    }
    return req.send().timeout(const Duration(seconds: 20));
  }

  // ── Profile ──────────────────────────────────────────────────────────────

  /// Persist profile edits for the signed-in user.
  ///
  /// Only the fields supplied are changed. The server scopes the update to the
  /// caller's own record from the token, and returns a refreshed token because
  /// a username change invalidates the claims in the old one.
  static Future<http.Response> updateProfile({
    String? username,
    String? fullName,
    String? icNumber,
    String? phoneNumber,
    String? email,
  }) {
    return http.put(
      Uri.parse('$baseUrl/profile'),
      // _authHeaders carries the bearer token only — it deliberately omits
      // Content-Type so multipart uploads can set their own boundary. A JSON
      // body needs the header added explicitly, or the server rejects it as
      // unprocessable.
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({
        if (username    != null) 'username':    username,
        if (fullName    != null) 'fullName':    fullName,
        if (icNumber    != null) 'icNumber':    icNumber,
        if (phoneNumber != null) 'phoneNumber': phoneNumber,
        if (email       != null) 'email':       email,
      }),
    ).timeout(const Duration(seconds: 15));
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
  ///
  /// See [predictBytes] for why [metadataBlob] is sent alongside the image.
  static Future<http.StreamedResponse> submitReportBytes(
      Map<String, String> fields, Uint8List bytes, String filename,
      {Uint8List? metadataBlob}) {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/reports/'));
    req.headers.addAll(_authHeaders);
    req.fields.addAll(fields);
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    if (metadataBlob != null && metadataBlob.isNotEmpty) {
      req.files.add(http.MultipartFile.fromBytes(
          'metadata_blob', metadataBlob, filename: 'metadata.bin'));
    }
    return req.send().timeout(const Duration(seconds: 25));
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

  /// Complete task and submit proof using raw bytes (works on both web and mobile).
  ///
  /// Proof photos matter most for authenticity checking: this is the upload a
  /// worker could fake to claim a job was finished.
  static Future<http.StreamedResponse> completeTaskBytes(
      int reportId, String notes, Uint8List? bytes, String? filename,
      {Uint8List? metadataBlob}) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('$baseUrl/reports/$reportId/complete-task'));
    req.headers.addAll(_authHeaders);
    req.fields['notes'] = notes;
    if (bytes != null && filename != null) {
      req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    }
    if (metadataBlob != null && metadataBlob.isNotEmpty) {
      req.files.add(http.MultipartFile.fromBytes(
          'metadata_blob', metadataBlob, filename: 'metadata.bin'));
    }
    return req.send().timeout(const Duration(seconds: 25));
  }
}

