# local_wifi_join example

Joins an access point, checks that a TCP peer behind it is reachable, and
leaves again. Run it on a physical device; simulators and emulators have no
real Wi-Fi.

- iOS: `ios/Runner/Runner.entitlements` enables Hotspot Configuration, and
  `Info.plist` declares `NSLocalNetworkUsageDescription` plus the
  `_lwj-probe._tcp` Bonjour service used by the permission probe. Select your
  own development team in Xcode before running on a device.
- Android: `minSdk` is 29.

```sh
flutter run
```
