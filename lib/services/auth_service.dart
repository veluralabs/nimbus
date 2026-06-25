import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// The signed-in user.
class NimbusUser {
  NimbusUser({required this.uid, required this.email, required this.idToken, required this.refreshToken});
  final String uid;
  final String email;
  String idToken;
  String refreshToken;

  Map<String, dynamic> toJson() =>
      {'uid': uid, 'email': email, 'idToken': idToken, 'refreshToken': refreshToken};

  factory NimbusUser.fromJson(Map<String, dynamic> j) => NimbusUser(
        uid: j['uid'], email: j['email'],
        idToken: j['idToken'], refreshToken: j['refreshToken'],
      );
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Email/password auth via Firebase Identity Toolkit REST. Holds the current
/// user and persists the session so the app stays logged in across launches.
class AuthService extends ChangeNotifier {
  static const _prefsKey = 'nimbus_session';
  static const _base = 'https://identitytoolkit.googleapis.com/v1';
  static const _secureBase = 'https://securetoken.googleapis.com/v1';

  NimbusUser? _user;
  NimbusUser? get user => _user;
  bool get isSignedIn => _user != null;

  /// Loads any saved session on startup.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        _user = NimbusUser.fromJson(jsonDecode(raw));
        notifyListeners();
      } catch (_) {/* corrupt session -> ignore */}
    }
  }

  Future<void> signUp(String email, String password) =>
      _emailAuth('accounts:signUp', email, password);

  Future<void> signIn(String email, String password) =>
      _emailAuth('accounts:signInWithPassword', email, password);

  Future<void> _emailAuth(String endpoint, String email, String password) async {
    final res = await http.post(
      Uri.parse('$_base/$endpoint?key=${FirebaseConfig.apiKey}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        'returnSecureToken': true,
      }),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw AuthException(_friendly(body['error']?['message'] ?? 'AUTH_FAILED'));
    }
    _user = NimbusUser(
      uid: body['localId'],
      email: body['email'],
      idToken: body['idToken'],
      refreshToken: body['refreshToken'],
    );
    await _persist();
    notifyListeners();
  }

  /// Exchanges the refresh token for a fresh idToken (tokens expire hourly).
  Future<String?> freshToken() async {
    if (_user == null) return null;
    final res = await http.post(
      Uri.parse('$_secureBase/token?key=${FirebaseConfig.apiKey}'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'grant_type': 'refresh_token', 'refresh_token': _user!.refreshToken},
    );
    if (res.statusCode != 200) return _user!.idToken;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    _user!.idToken = body['id_token'];
    _user!.refreshToken = body['refresh_token'];
    await _persist();
    return _user!.idToken;
  }

  Future<void> signOut() async {
    _user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_user!.toJson()));
  }

  String _friendly(String code) {
    switch (code) {
      case 'EMAIL_EXISTS':
        return 'That email is already registered. Try signing in.';
      case 'INVALID_LOGIN_CREDENTIALS':
      case 'INVALID_PASSWORD':
      case 'EMAIL_NOT_FOUND':
        return 'Incorrect email or password.';
      case 'WEAK_PASSWORD : Password should be at least 6 characters':
        return 'Password must be at least 6 characters.';
      case 'MISSING_PASSWORD':
        return 'Please enter a password.';
      case 'INVALID_EMAIL':
        return 'That email address looks invalid.';
      default:
        return code.replaceAll('_', ' ').toLowerCase();
    }
  }
}
