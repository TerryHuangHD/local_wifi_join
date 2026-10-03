// Runs against the real native implementation:
//   cd example && flutter test integration_test
// Works on simulators/emulators; joining a real network needs a device and an
// access point, see the README's manual test matrix.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_wifi_join/local_wifi_join.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
