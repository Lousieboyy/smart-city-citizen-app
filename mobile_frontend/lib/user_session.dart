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
  
  // Customizable profile state variables
  int?   avatarIndex;
  String fullName = '';
  String icNumber = '';
  String phoneNumber = '';
  String email = '';

  bool get isLoggedIn => userId != null;

  void populate({
    required int    id,
    required String name,
    required String userRole,
    String?         jwtToken,
    int?            customAvatarIndex,
    String?         userFullName,
    String?         userIcNumber,
    String?         userPhoneNumber,
    String?         userEmail,
  }) {
    userId      = id;
    username    = name;
    role        = userRole;
    token       = jwtToken;
    avatarIndex = customAvatarIndex;
    fullName    = userFullName    ?? name;
    icNumber    = userIcNumber    ?? '';
    phoneNumber = userPhoneNumber ?? '';
    email       = userEmail       ?? '';
  }

  void clear() {
    userId      = null;
    username    = 'Citizen';
    role        = 'citizen';
    token       = null;
    avatarIndex = null;
    fullName    = '';
    icNumber    = '';
    phoneNumber = '';
    email       = '';
  }
}

/// Helper to get a deterministic avatar path from a username or the user's custom selection.
String getAvatarPath(String username) {
  final customIndex = UserSession.instance.avatarIndex;
  if (customIndex != null) {
    return 'assets/avatars/avatar_$customIndex.png';
  }
  if (username.isEmpty) return 'assets/avatars/avatar_1.png';
  int hash = 0;
  for (int i = 0; i < username.length; i++) {
    hash = 31 * hash + username.codeUnitAt(i);
  }
  final index = (hash.abs() % 18) + 1;
  return 'assets/avatars/avatar_$index.png';
}
