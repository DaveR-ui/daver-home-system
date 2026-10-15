import 'package:daver_home/hub/secure_token_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads, overwrites, and clears the stored token', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'ha_long_lived_token': 'abc',
    });
    const SecureTokenStore store = SecureTokenStore();

    expect(await store.readToken(), 'abc');

    await store.writeToken('z');
    expect(await store.readToken(), 'z');

    await store.clearToken();
    expect(await store.readToken(), isNull);
  });
}
