import 'package:http/http.dart' as http;
import 'dart:convert';

class ApiService {
  static const String baseUrl = 'http://10.0.2.2:8000';

  static Future<http.Response> login(String username, String password) async {
    return await http.post(
      Uri.parse('$baseUrl/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
      }),
    );
  }

  static Future<http.Response> signup(String username, String password) async {
    return await http.post(
      Uri.parse('$baseUrl/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
      }),
    );
  }

  static Future<http.Response> getStats(int userId) async {
    return await http.get(Uri.parse('$baseUrl/reports/stats?user_id=$userId')).timeout(const Duration(seconds: 10));
  }

  static Future<http.Response> getReports({int? userId}) async {
    String url = '$baseUrl/reports/';
    if (userId != null) {
      url += '?user_id=$userId';
    }
    return await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
  }

  static Future<http.StreamedResponse> predict(String imagePath) async {
    var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/predict'));
    request.files.add(await http.MultipartFile.fromPath('file', imagePath));
    return await request.send().timeout(const Duration(seconds: 10));
  }

  static Future<http.StreamedResponse> submitReport(Map<String, String> fields, String imagePath) async {
    var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/reports/'));
    request.fields.addAll(fields);
    request.files.add(await http.MultipartFile.fromPath('file', imagePath));
    return await request.send().timeout(const Duration(seconds: 15));
  }
}
