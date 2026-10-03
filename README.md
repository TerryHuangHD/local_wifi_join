# local_wifi_join

[English](README.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

[![pub package](https://img.shields.io/pub/v/local_wifi_join.svg)](https://pub.dev/packages/local_wifi_join)
[![CI](https://github.com/TerryHuangHD/local_wifi_join/actions/workflows/ci.yaml/badge.svg)](https://github.com/TerryHuangHD/local_wifi_join/actions/workflows/ci.yaml)

Join and leave a WPA2-Personal Wi-Fi access point from Flutter, typically an
IoT device's own hotspot, then talk to the device over the local network.

- **Works on iOS 26+.** iOS joins are judged by the
  `NEHotspotConfigurationManager.apply` error alone. The current SSID is never
  read back: iOS 26+ refuses `NEHotspotNetwork.fetchCurrent` even with the
  `wifi-info` entitlement, which makes plugins that verify that way report a
  successful join as a failure.
- **No "Unable to join the network".** A configuration left over from an
  earlier session (for example after a crash) is removed before joining.
- **Native timeouts that clean up.** A join that times out or is cancelled
  is torn down natively: no late process binding on Android, and on iOS a
  configuration that the system installs after the join ended is removed as
  soon as its `apply` completes.
- **Every call completes exactly once** with an explicit status (`joined`,
  `userDenied`, `unavailable`, `timeout`, `cancelled`, …) instead of a bare
  `bool`.
- **Swift Package Manager and CocoaPods**, UIScene-compatible, no
  `AppDelegate` changes.

| | Android | iOS |
|---|---|---|
| Minimum version | API 29 (Android 10) | 13.0 |
| Mechanism | `WifiNetworkSpecifier` + `ConnectivityManager.requestNetwork` + `bindProcessToNetwork` | `NEHotspotConfiguration` with `joinOnce = true` |

Requires Flutter 3.44 or newer. Simulators and emulators have no real Wi-Fi;
test joins on physical devices.

## Setup

```sh
flutter pub add local_wifi_join
```

### iOS

1. Add the **Hotspot Configuration** capability to the Runner target, which
   adds this entitlement (`Runner.entitlements`). Without it every join fails.

   ```xml
   <key>com.apple.developer.networking.HotspotConfiguration</key>
   <true/>
   ```

2. Talking to a device on the joined network needs Local Network access. Add a
   usage description and the Bonjour service type you pass to
   `requestLocalNetworkPermission` to `Info.plist`:

   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>Used to connect to your device over Wi-Fi.</string>
   <key>NSBonjourServices</key>
   <array>
     <string>_myapp-probe._tcp</string>
   </array>
   ```

The `wifi-info` entitlement and location permission are **not** needed.

### Android

- Set `minSdk` to 29 or higher.
- The plugin's manifest declares `CHANGE_NETWORK_STATE`,
  `ACCESS_NETWORK_STATE` (lets `bindProcessToNetwork` apply the joined
  network's proxy settings) and `ACCESS_WIFI_STATE`. All are normal
  (install-time) permissions and merge into your app automatically.
- Talking to the device with `dart:io` sockets or HTTP needs
  `android.permission.INTERNET` in your app's **main** manifest. Flutter only
  adds it to debug and profile builds.
- `NEARBY_WIFI_DEVICES` is neither declared nor requested. Android's
  [list of APIs that require it](https://developer.android.com/develop/connectivity/wifi/wifi-permissions#check-for-apis)
  does not include `WifiNetworkSpecifier` requests. If you decide your app
  needs it, declare it with `android:usesPermissionFlags="neverForLocation"`
  and request it at runtime yourself, for example with `permission_handler`.

## Usage

```dart
import 'dart:io';

import 'package:local_wifi_join/local_wifi_join.dart';

Future<void> downloadFromDevice(String passphrase) async {
  const ssid = 'MY-DEVICE-AP';

  if (!await LocalWifiJoin.isWifiEnabled()) {
    // Ask the user to turn Wi-Fi on (Android only; always true on iOS).
    return;
  }

  final permission = await LocalWifiJoin.requestLocalNetworkPermission(
    bonjourServiceType: '_myapp-probe._tcp', // must be in NSBonjourServices
  );
  if (permission != LocalNetworkPermission.granted) {
    // Explain why local network access is needed and link to Settings.
    return;
  }

  try {
    final result = await LocalWifiJoin.join(ssid: ssid, passphrase: passphrase);
    if (!result.isJoined) {
      // result.status tells you why: userDenied, unavailable, timeout, ...
      return;
    }

    // `joined` is not proof of connectivity (see below): retry until the
    // device answers, then use the socket.
    final socket = await connectWithRetry('192.168.4.1', 8080);
    // ...
    socket?.destroy();
  } finally {
    // Idempotent; safe even if the join never happened.
    await LocalWifiJoin.leave(ssid);
  }
}

Future<Socket?> connectWithRetry(String host, int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    try {
      return await Socket.connect(host, port, timeout: const Duration(seconds: 2));
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  return null;
}
```

A complete app is in [`example/`](example/lib/main.dart).

## API

| Method | Android | iOS |
|---|---|---|
| `join({ssid, passphrase, timeout = 30s, iosRemoveConfigurationDelay = 300ms})` | Requests the network, binds the process to it | Removes any old configuration, waits, applies a `joinOnce` configuration |
| `leave(ssid)` | Releases the request, restores the default network (`ssid` ignored) | Removes the configuration for `ssid` by name |
| `isWifiEnabled()` | `WifiManager.isWifiEnabled`; `true` if the platform cannot answer (fail-open) | Always `true` (no public API) |
| `requestLocalNetworkPermission({bonjourServiceType, timeout = 8s})` | Always `granted` | Bonjour probe, see below |

On other platforms every method completes with an `UnsupportedError`.

### Join statuses

| Status | Android | iOS |
|---|---|---|
| `joined` | Network available and process bound | `apply` succeeded, or `alreadyAssociated` (`platformCode: 'alreadyAssociated'`) |
| `userDenied` | — | User declined the system prompt |
| `unavailable` | `onUnavailable`: user cancelled the dialog **or** the network was not found (Android does not distinguish) | — |
| `timeout` | No result within `timeout`; request released | No result within `timeout`; configuration removed |
| `cancelled` | Superseded by another `join`, or ended by `leave` | Same |
| `notInForeground` | — | `applicationIsNotInForeground` |
| `invalidArguments` | Rejected input (see below) or rejected by `WifiNetworkSpecifier` | Rejected input, or `invalid*` errors from `apply` |
| `failed` | Anything else; see `platformCode` (exception class name) and `message` | Anything else; `platformCode` is the `NEHotspotConfigurationError` case name, e.g. `pending` |

`join` validates before calling the platform: `ssid` must be 1–32 bytes of
UTF-8, `passphrase` 8–63 printable ASCII characters (raw 64-hex PSKs are not
supported), `timeout` at least 1 ms and `iosRemoveConfigurationDelay` not
negative. Durations are sent with millisecond precision. `join` never throws
on Android or iOS: `PlatformException`s and a missing native plugin are
reported as `failed`. `leave` never throws on Android or iOS either.

## Behavior you should know about

### `joined` is not proof of connectivity (iOS)

On iOS, `joined` means the system accepted the configuration. It does not mean
the phone is associated with the access point; if the AP is out of range or the
passphrase is wrong, iOS may still report `joined`. Always verify reachability
yourself, for example by retrying a TCP connection to the device as shown
above.

### `joinOnce` limits (iOS)

Configurations are applied with
[`joinOnce = true`](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce),
so nothing persists in the user's Wi-Fi settings. The flip side: iOS
disconnects and removes the configuration when the app stays in the background
for more than about 15 seconds, the device sleeps, or the app exits. Keep
transfers in the foreground.

### Process binding (Android)

After `joined`, the **whole process** is bound to the joined network, so
sockets and host lookups created from then on, including `dart:io` `Socket`
and `HttpClient` connections, go through it. Sockets that were already open
keep their original network, so close pooled connections (for example an
`HttpClient` created before the join) across the switch. The access point
usually has no internet, so internet traffic fails until you call `leave`,
which restores the system default network for new sockets. If the network
drops while joined (for example the device powers off), the binding and the
request are released automatically and later `leave` calls are no-ops.

The network request stays registered while joined: Android disconnects a
`WifiNetworkSpecifier` network as soon as its request is released.

### System dialog and foreground rule (Android)

Each request shows Android's "connect to device" dialog, and Android only
accepts requests from the app in the foreground. While a dialog from an earlier
request is still on screen, that dialog is the foreground app, so a new `join`
completes with `unavailable` almost immediately. Let the user close the dialog
before retrying.

### Concurrency, timeouts and cleanup

- A `join` issued while another is pending completes the earlier one with
  `cancelled` first. The same happens on `leave`.
- `timeout` runs natively. When it fires, Android unregisters the network
  request (a later `onAvailable` can no longer bind the process) and iOS removes
  the configuration (also undoing an `apply` that succeeds after the timeout).
- On iOS, `removeConfiguration` has no completion handler, so `join` waits
  `iosRemoveConfigurationDelay` (default 300 ms) after removing a stale
  configuration before applying the new one.
- On iOS, only one `apply` runs at a time. If an earlier, already cancelled
  join's `apply` is still in flight (its system prompt may still be on
  screen), the new join waits for it within its own `timeout`; a configuration
  the earlier `apply` installs is removed before the new one is applied.
- When the Flutter engine is destroyed, a pending join is cancelled and
  everything the plugin joined is released: Android releases the request and
  binding, iOS removes the configurations.

### Local Network permission probe (iOS)

`requestLocalNetworkPermission` publishes a Bonjour service of
`bonjourServiceType` under a random name and browses for that type:

| Result | Meaning |
|---|---|
| `granted` | The browser saw a service, so local network access works |
| `denied` | The listener or browser failed or waits with `kDNSServiceErr_PolicyDenied` |
| `timedOut` | No answer within `timeout`; typically the prompt is still open or the type is missing from `NSBonjourServices`. Treat it as not granted |
| `failed` | Other listener or browser failure, or a platform channel error |

Other `waiting` states (for example no network yet) are transient, so the
probe keeps going until `timeout`. Concurrent calls use independent listeners
and browsers. An invalid `bonjourServiceType` (not `_name._tcp`) or a
`timeout` shorter than 1 ms throws an `ArgumentError`.

## Migrating from `plugin_wifi_connect`

| `plugin_wifi_connect` | `local_wifi_join` |
|---|---|
| `PluginWifiConnect.connectToSecureNetwork(ssid, password)` | `(await LocalWifiJoin.join(ssid: ssid, passphrase: password)).isJoined` |
| `PluginWifiConnect.disconnect()` | `LocalWifiJoin.leave(ssid)` |
| `.timeout(...)` around the call | `join(timeout: ...)` (enforced natively) |

## Testing your code

The method channel is exposed for tests:

```dart
TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(LocalWifiJoin.channel, (call) async {
  if (call.method == 'join') return {'status': 'joined'};
  return null;
});
```

## Development

```sh
# Dart unit tests
fvm flutter test

# Android state machine (JVM)
(cd example && fvm flutter build apk --config-only)
(cd example/android && ./gradlew :local_wifi_join:testDebugUnitTest)

# iOS state machine (XCTest)
(cd example && fvm flutter build ios --config-only --simulator)
(cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
  -only-testing:RunnerTests -destination 'platform=iOS Simulator,name=<simulator>')

# Native channel on a device or simulator
(cd example && fvm flutter test integration_test)

# iOS native channel (XCTest, same runner as CI)
(cd example && fvm flutter build ios --simulator --debug \
  --target integration_test/plugin_integration_test.dart)
(cd example/ios && xcodebuild test -workspace Runner.xcworkspace \
  -scheme RunnerIntegrationTests -only-testing:RunnerIntegrationTests \
  -parallel-testing-enabled NO \
  -destination 'platform=iOS Simulator,name=<simulator>')
```

The Flutter version used for development is pinned in `.fvmrc`.

CI runs the same Dart integration tests through Flutter's native XCTest adapter
in the dedicated `RunnerIntegrationTests` scheme, avoiding the Flutter tool's
[simulator log-reader race](https://github.com/flutter/flutter/issues/181771)
during VM Service discovery. The `Runner` scheme remains for state-machine tests.
Both test steps share one pre-booted iOS simulator, with parallel testing disabled.
Simulator preparation, unit tests and integration tests have 5-, 10- and 10-minute
limits respectively; the SwiftPM job has a 30-minute limit.

## License

[MIT](LICENSE)
