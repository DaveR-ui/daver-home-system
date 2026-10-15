import 'hub_client.dart';
import 'light_command.dart';

/// The app's port over the Home Assistant light-service write path.
///
/// Fake-able in tests; the production implementation is `HttpLightCommandClient`.
/// This is the app's only write path, and it targets Home Assistant alone
/// (ADR-0005). Implementations throw the shared typed exceptions —
/// [TokenRejectedException], [HubUnavailableException], and
/// [DeviceOfflineException] — so callers map failures without new types.
abstract class LightCommandClient {
  /// `POST /api/services/light/<segment>`. Completes when Home Assistant
  /// accepted the command; throws one of the shared typed exceptions otherwise.
  Future<void> sendLightCommand(LightCommand command);
}
