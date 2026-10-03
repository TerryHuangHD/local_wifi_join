## 0.1.0

Initial release.

- `LocalWifiJoin.join` joins a WPA2-Personal network and reports a
  `WifiJoinResult` with an explicit `WifiJoinStatus`. It never throws on
  Android or iOS, also not when the native plugin is missing. Timeouts run
  natively and leave nothing behind; a newer `join` or a `leave` cancels a
  pending one.
- iOS: the result is judged by the `NEHotspotConfigurationManager.apply` error
  only (works on iOS 26+, no `wifi-info` entitlement needed); stale
  configurations are removed before applying a `joinOnce` configuration.
  Applies never overlap, a configuration installed by a cancelled join's late
  `apply` is removed, and engine teardown removes joined configurations.
- Android: `WifiNetworkSpecifier` request with process binding, released on
  `leave`, on engine teardown, or when the network is lost.
- `LocalWifiJoin.leave` is idempotent, never throws on Android or iOS, and
  removes the iOS configuration by SSID.
- `LocalWifiJoin.isWifiEnabled` (Android; fails open) and
  `LocalWifiJoin.requestLocalNetworkPermission` (iOS Bonjour probe; concurrent
  calls are independent; platform errors report `failed`).
- Swift Package Manager and CocoaPods support.
- iOS CI runs Dart native channel integration tests through Flutter's XCTest
  adapter instead of VM Service discovery. Unit and integration tests share a
  pre-booted simulator, with parallel testing disabled and bounded boot/test steps.
  Platform semantics are initialized before each integration test's handle baseline.
