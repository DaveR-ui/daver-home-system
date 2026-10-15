import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_store.dart';

/// Keystore entry name for the long-lived token.
const String kTokenStorageKey = 'ha_long_lived_token';

/// [TokenStore] backed by the platform keystore via `flutter_secure_storage`.
final class SecureTokenStore implements TokenStore {
  // Android: encrypted prefs keep the token out of plain shared preferences.
  // iOS keeps the plugin default (Keychain).
  const SecureTokenStore({
    this.storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  });

  final FlutterSecureStorage storage;

  @override
  Future<String?> readToken() => storage.read(key: kTokenStorageKey);

  @override
  Future<void> writeToken(String token) =>
      storage.write(key: kTokenStorageKey, value: token);

  @override
  Future<void> clearToken() => storage.delete(key: kTokenStorageKey);
}
