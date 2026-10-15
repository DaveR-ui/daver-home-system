/// Port over the OS keystore that holds the long-lived Home Assistant token.
///
/// The token lives only here: never in a config file, never logged.
abstract class TokenStore {
  /// The stored token, or null when none has been saved yet.
  Future<String?> readToken();

  Future<void> writeToken(String token);

  Future<void> clearToken();
}
