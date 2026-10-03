// Runs against the real native implementation:
//   cd example && flutter test integration_test
// Works on simulators/emulators; joining a real network needs a device and an
// access point. See README.md for platform setup.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_wifi_join/local_wifi_join.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Initialize the platform-owned handle before testWidgets records its
    // baseline; XCTest can otherwise request semantics during the first test.
    binding.platformDispatcher.semanticsEnabledTestValue = true;
    addTearDown(binding.platformDispatcher.clearSemanticsEnabledTestValue);
  });

  testWidgets('leave without a join, twice, completes normally', (_) async {
    await LocalWifiJoin.leave('LOCAL-WIFI-JOIN-TEST');
    await LocalWifiJoin.leave('LOCAL-WIFI-JOIN-TEST');
  });

  testWidgets('native join rejects malformed arguments without crashing', (
    _,
  ) async {
    final reply = await LocalWifiJoin.channel.invokeMapMethod<String, Object?>(
      'join',
      {'ssid': 42, 'passphrase': null, 'timeoutMillis': 'soon'},
    );

    expect(reply?['status'], 'invalidArguments');
  });
}
