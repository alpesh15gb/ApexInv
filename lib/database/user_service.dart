import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/utils/session_manager.dart';
import 'database_helper.dart';
import 'package:apexbooks/utils/app_logger.dart';
import 'package:apexbooks/utils/password_utils.dart';

const _tag = 'UserService';

class UserService {
  static final dbHelper = DatabaseHelper();

  // ─────────────────────────────────────────────
  // Login throttling (in-memory per username)
  static final Map<String, List<DateTime>> _failedAttempts = {};
  static const int _maxFailedAttempts = 5;
  static const Duration _attemptWindow = Duration(minutes: 15);

  static void _pruneAttempts(String username, DateTime now) {
    final attempts = _failedAttempts[username];
    if (attempts == null) return;
    attempts.removeWhere((t) => now.difference(t) > _attemptWindow);
    if (attempts.isEmpty) _failedAttempts.remove(username);
  }

  static void _recordFailure(String username, DateTime now) {
    final attempts = _failedAttempts.putIfAbsent(username, () => []);
    attempts.add(now);
  }

  static void _clearFailures(String username) {
    _failedAttempts.remove(username);
  }

  // ─────────────────────────────────────────────
  // CRUD for User

  /// Looks up a user by username and verifies the password.
  /// Supports legacy SHA-256 (salt == null), legacy HMAC-SHA256, and
  /// new PBKDF2-HMAC-SHA256 (`$pbkdf2$...`). On success with a legacy
  /// hash, transparently upgrades to the new KDF (keeping
  /// password_changed). Throws [StateError] after 5 failures in 15 min.
  static Future<User?> getUser(String username, String password) async {
    final now = DateTime.now();
    _pruneAttempts(username, now);
    final recent = _failedAttempts[username];
    if (recent != null && recent.length >= _maxFailedAttempts) {
      throw StateError('Too many attempts, try later');
    }

    final db = await dbHelper.database;
    final result = await db.query(
      'users',
      where: 'username = ?',
      whereArgs: [username],
    );

    if (result.isEmpty) {
      _recordFailure(username, now);
      return null;
    }

    final user = User.fromMap(result.first);
    if (PasswordUtils.verify(password, user.password, user.salt)) {
      _clearFailures(username);
      // Transparent upgrade: legacy hashes → new PBKDF2 KDF.
      if (PasswordUtils.needsUpgrade(user.password)) {
        try {
          final newSalt = PasswordUtils.generateSalt();
          final newHash = PasswordUtils.hashWithSalt(password, newSalt);
          await db.update(
            'users',
            {'password': newHash, 'salt': newSalt},
            where: 'id = ?',
            whereArgs: [user.id],
          );
          return User(
            id: user.id,
            username: user.username,
            password: newHash,
            userType: user.userType,
            salt: newSalt,
            passwordChanged: user.passwordChanged,
          );
        } catch (_) {
          return user;
        }
      }
      return user;
    }
    _recordFailure(username, DateTime.now());
    return null;
  }

  static Future<User?> getUserByUsername(String username) async {
    final db = await dbHelper.database;
    final result = await db.query(
      'users',
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );
    if (result.isNotEmpty) return User.fromMap(result.first);
    return null;
  }

  static Future<List<User>> getAllUsers() async {
    final db = await dbHelper.database;
    final maps = await db.query('users');
    return maps.map((map) => User.fromMap(map)).toList();
  }

  static Future<User?> getUserById(String id) async {
    final db = await dbHelper.database;
    final result =
        await db.query('users', where: 'id = ?', whereArgs: [id], limit: 1);
    if (result.isNotEmpty) return User.fromMap(result.first);
    return null;
  }

  /// Inserts a new user with a fresh salt + HMAC-SHA256 hash.
  static Future<void> insertUser(User user) async {
    final db = await dbHelper.database;
    final salt = PasswordUtils.generateSalt();
    final hashedPw = PasswordUtils.hashWithSalt(user.password, salt);
    final userToInsert = User(
      id: user.id,
      username: user.username,
      password: hashedPw,
      userType: user.userType,
      salt: salt,
      passwordChanged: user.passwordChanged,
    );
    await db.insert('users', userToInsert.toMap());
  }

  static Future<void> updateUser(User user) async {
    final db = await dbHelper.database;
    // Deliberately excludes 'password' — use updatePassword() to change passwords.
    await db.update(
      'users',
      {'username': user.username, 'user_type': user.userType},
      where: 'id = ?',
      whereArgs: [user.id],
    );
  }

  /// Updates the password for a user: generates a new salt, re-hashes, and
  /// sets password_changed = 1.
  static Future<void> updatePassword(String id, String newPassword) async {
    final db = await dbHelper.database;
    final salt = PasswordUtils.generateSalt();
    final hashedPw = PasswordUtils.hashWithSalt(newPassword, salt);
    await db.update(
      'users',
      {
        'password': hashedPw,
        'salt': salt,
        'password_changed': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Marks password_changed = 1 for the given user.
  static Future<void> markPasswordChanged(String id) async {
    final db = await dbHelper.database;
    await db.update(
      'users',
      {'password_changed': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<bool> userExists(String userId) async {
    final db = await dbHelper.database;
    try {
      final result = await db.query(
        'users',
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      return result.isNotEmpty;
    } catch (e) {
      AppLogger.e(_tag, 'Error checking if user exists', e);
      return false;
    }
  }

  static Future<int> _deleteUser(String userId) async {
    final db = await dbHelper.database;
    try {
      final result = await db.delete(
        'users',
        where: 'id = ?',
        whereArgs: [userId],
      );
      AppLogger.d(_tag, 'User deleted successfully. Rows affected: $result');
      return result;
    } catch (e) {
      AppLogger.e(_tag, 'Error deleting user', e);
      throw Exception('Failed to delete user: $e');
    }
  }

  static Future<bool> deleteUserSafely(String userId) async {
    try {
      final exists = await userExists(userId);
      if (!exists) {
        AppLogger.w(_tag, 'User with ID $userId does not exist');
        return false;
      }
      final result = await _deleteUser(userId);
      return result > 0;
    } catch (e) {
      AppLogger.e(_tag, 'Error in safe delete', e);
      return false;
    }
  }

  static Future<void> logoutAndSessionReset() async {
    SessionManager.dispose();
  }
}
