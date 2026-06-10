/// UserSession — lightweight singleton that holds the logged-in user's state.
///
/// WHY: The original code read user_id / username from SharedPreferences in
/// every screen individually (home, history, profile, report screens all
/// duplicated this logic). Worse, they all had `?? 1` as a fallback which
/// silently attributed actions to user #1 if the session was missing (F-4–F-7).
///
/// This singleton is populated once on login/signup and cleared on logout.
/// Any screen can read UserSession.instance.userId without async calls.
/// If userId is null, the user is not logged in.
class UserSession {
  UserSession._internal();
  static final UserSession instance = UserSession._internal();

  int?   userId;
  String username = 'Citizen';
  String role     = 'citizen';
  /// JWT Bearer token issued at login — attached to every protected API request.
  String? token;

  bool get isLoggedIn => userId != null;

  void populate({
    required int    id,
    required String name,
    required String userRole,
    String?         jwtToken,
  }) {
    userId   = id;
    username = name;
    role     = userRole;
    token    = jwtToken;
  }

  void clear() {
    userId   = null;
    username = 'Citizen';
    role     = 'citizen';
    token    = null;
  }
}
