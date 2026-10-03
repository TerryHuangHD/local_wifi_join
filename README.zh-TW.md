# local_wifi_join

[English](README.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

[![pub package](https://img.shields.io/pub/v/local_wifi_join.svg)](https://pub.dev/packages/local_wifi_join)
[![CI](https://github.com/TerryHuangHD/local_wifi_join/actions/workflows/ci.yaml/badge.svg)](https://github.com/TerryHuangHD/local_wifi_join/actions/workflows/ci.yaml)

從 Flutter 加入或離開 WPA2-Personal Wi-Fi 存取點，例如 IoT 裝置自建的熱點，
再透過區域網路與裝置通訊。

- **支援 iOS 26 以上版本。** iOS 僅根據
  `NEHotspotConfigurationManager.apply` 的錯誤判定加入結果，不會讀回目前的 SSID。
  即使具有 `wifi-info` entitlement，iOS 26 以上版本仍會拒絕
  `NEHotspotNetwork.fetchCurrent`，導致使用這種驗證方式的 plugin 將成功加入誤判為失敗。
- **避免「Unable to join the network」。** 加入前會移除先前工作階段遺留的設定，
  例如 App 當機後留下的設定。
- **原生逾時與清理。** 加入逾時或取消時，由原生層清理：Android 不會在稍後才綁定
  process；iOS 若在加入流程結束後才由系統安裝設定，會在該次 `apply` 完成時立即移除。
- **每次呼叫恰好完成一次**，並回傳明確狀態（`joined`、`userDenied`、`unavailable`、
  `timeout`、`cancelled` 等），而不是只有 `bool`。
- **同時支援 Swift Package Manager 與 CocoaPods**，相容 UIScene，
  不需要修改 `AppDelegate`。

| | Android | iOS |
|---|---|---|
| 最低版本 | API 29（Android 10） | 13.0 |
| 實作機制 | `WifiNetworkSpecifier` + `ConnectivityManager.requestNetwork` + `bindProcessToNetwork` | `NEHotspotConfiguration`，使用 `joinOnce = true` |

需要 Flutter 3.44 或更新版本。模擬器沒有真正的 Wi-Fi，請使用實體裝置測試加入網路。

## 設定

```sh
flutter pub add local_wifi_join
```

### iOS

1. 在 Runner target 加入 **Hotspot Configuration** capability，
   將以下 entitlement 加入 `Runner.entitlements`。缺少此設定時，每次加入都會失敗。

   ```xml
   <key>com.apple.developer.networking.HotspotConfiguration</key>
   <true/>
   ```

2. 與已加入網路中的裝置通訊，需要區域網路（Local Network）存取權限。
   在 `Info.plist` 加入用途說明，以及傳給 `requestLocalNetworkPermission`
   的 Bonjour 服務類型：

   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>用於透過 Wi-Fi 連線至您的裝置。</string>
   <key>NSBonjourServices</key>
   <array>
     <string>_myapp-probe._tcp</string>
   </array>
   ```

**不需要** `wifi-info` entitlement 或定位權限。

### Android

- 將 `minSdk` 設為 29 或以上。
- Plugin 的 manifest 已宣告 `CHANGE_NETWORK_STATE`、`ACCESS_NETWORK_STATE`
  （讓 `bindProcessToNetwork` 套用已加入網路的 Proxy 設定）及 `ACCESS_WIFI_STATE`。
  這些都是一般權限，在安裝時授予，會自動合併到 App 的 manifest。
- 使用 `dart:io` socket 或 HTTP 與裝置通訊時，必須在 App 的 **main** manifest
  宣告 `android.permission.INTERNET`。Flutter 只會在 debug 與 profile 建置中加入此權限。
- 本套件不會宣告或請求 `NEARBY_WIFI_DEVICES`。Android 的
  [需要此權限的 API 清單](https://developer.android.com/develop/connectivity/wifi/wifi-permissions#check-for-apis)
  不包含 `WifiNetworkSpecifier` 網路請求。如果 App 的其他需求需要此權限，
  請自行以 `android:usesPermissionFlags="neverForLocation"` 宣告，並在執行時請求，
  例如使用 `permission_handler`。

## 使用方式

```dart
import 'dart:io';

import 'package:local_wifi_join/local_wifi_join.dart';

Future<void> downloadFromDevice(String passphrase) async {
  const ssid = 'MY-DEVICE-AP';

  if (!await LocalWifiJoin.isWifiEnabled()) {
    // 請使用者開啟 Wi-Fi（僅 Android；iOS 一律回傳 true）。
    return;
  }

  final permission = await LocalWifiJoin.requestLocalNetworkPermission(
    bonjourServiceType: '_myapp-probe._tcp', // 必須列於 NSBonjourServices
  );
  if (permission != LocalNetworkPermission.granted) {
    // 說明為何需要區域網路存取權限，並提供前往「設定」的連結。
    return;
  }

  try {
    final result = await LocalWifiJoin.join(ssid: ssid, passphrase: passphrase);
    if (!result.isJoined) {
      // result.status 說明原因：userDenied、unavailable、timeout 等。
      return;
    }

    // `joined` 不代表已可通訊（詳見下文）：重試直到裝置回應，再使用 socket。
    final socket = await connectWithRetry('192.168.4.1', 8080);
    // ...
    socket?.destroy();
  } finally {
    // 冪等操作；即使從未加入網路，也可以安全呼叫。
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

完整 App 範例位於 [`example/`](example/lib/main.dart)。

## API

| 方法 | Android | iOS |
|---|---|---|
| `join({ssid, passphrase, timeout = 30s, iosRemoveConfigurationDelay = 300ms})` | 請求網路，並將 process 綁定至該網路 | 移除舊設定，等待後套用 `joinOnce` 設定 |
| `leave(ssid)` | 釋放網路請求，恢復預設網路（忽略 `ssid`） | 依名稱移除 `ssid` 的設定 |
| `isWifiEnabled()` | `WifiManager.isWifiEnabled`；平台無法回應時回傳 `true`（fail-open） | 一律回傳 `true`（沒有公開 API） |
| `requestLocalNetworkPermission({bonjourServiceType, timeout = 8s})` | 一律回傳 `granted` | Bonjour 探測，詳見下文 |

在其他平台上，每個方法都會以 `UnsupportedError` 結束。

### 加入網路的狀態

| 狀態 | Android | iOS |
|---|---|---|
| `joined` | 網路可用，且 process 已綁定 | `apply` 成功，或回傳 `alreadyAssociated`（`platformCode: 'alreadyAssociated'`） |
| `userDenied` | — | 使用者拒絕系統提示 |
| `unavailable` | `onUnavailable`：使用者取消對話框**或**找不到網路（Android 無法區分） | — |
| `timeout` | 在 `timeout` 內沒有結果；已釋放請求 | 在 `timeout` 內沒有結果；已移除設定 |
| `cancelled` | 被新的 `join` 取代，或被 `leave` 結束 | 同左 |
| `notInForeground` | — | `applicationIsNotInForeground` |
| `invalidArguments` | 輸入驗證未通過（見下文），或遭 `WifiNetworkSpecifier` 拒絕 | 輸入驗證未通過，或 `apply` 回傳 `invalid*` 錯誤 |
| `failed` | 其他情況；詳見 `platformCode`（例外類別名稱）及 `message` | 其他情況；`platformCode` 是 `NEHotspotConfigurationError` 的 case 名稱，例如 `pending` |

`join` 會在呼叫平台前驗證參數：`ssid` 必須是 1–32 bytes 的 UTF-8，
`passphrase` 必須是 8–63 個可列印 ASCII 字元（不支援原始 64 位十六進位 PSK），
`timeout` 至少為 1 ms，且 `iosRemoveConfigurationDelay` 不得為負數。
時間長度以毫秒精度傳送。在 Android 或 iOS 上，`join` 不會拋出例外：
`PlatformException` 或缺少原生 plugin 都會回報為 `failed`。
`leave` 在 Android 或 iOS 上也不會拋出例外。

## 需要了解的行為

### `joined` 不代表已可通訊（iOS）

在 iOS 上，`joined` 代表系統接受了設定，不代表手機已經與存取點建立關聯。
即使 AP 不在範圍內或密碼錯誤，iOS 仍可能回報 `joined`。
請務必自行驗證可達性，例如像上方範例一樣重試與裝置建立 TCP 連線。

### `joinOnce` 的限制（iOS）

設定會以
[`joinOnce = true`](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce)
套用，因此不會永久保留在使用者的 Wi-Fi 設定中。
相對地，當 App 在背景停留超過約 15 秒、裝置進入休眠，或 App 結束時，
iOS 會中斷連線並移除設定。傳輸期間請讓 App 保持在前景。

### Process 綁定（Android）

回傳 `joined` 後，**整個 process** 都會綁定至已加入的網路。
之後建立的 socket 及主機名稱查詢，包括 `dart:io` 的 `Socket` 與 `HttpClient` 連線，
都會透過該網路。已開啟的 socket 仍使用原本的網路，因此切換網路時，
請關閉連線池中的連線，例如加入網路前建立的 `HttpClient` 連線。
存取點通常沒有網際網路，因此在呼叫 `leave` 前，對外的網際網路流量會失敗。
`leave` 會讓新建立的 socket 恢復使用系統預設網路。
如果加入後網路中斷，例如裝置斷電，綁定與請求會自動釋放；之後呼叫 `leave` 不會再執行任何操作。

已加入網路期間，網路請求會持續保持註冊。
Android 會在 `WifiNetworkSpecifier` 的請求被釋放時，立即中斷該網路連線。

### 系統對話框與前景限制（Android）

每次請求都會顯示 Android 的「連線至裝置」對話框，而且 Android 只接受前景 App 的請求。
如果前一次請求的對話框仍在畫面上，該對話框就是前景 App，
因此新的 `join` 幾乎會立即以 `unavailable` 結束。請讓使用者關閉對話框後再重試。

### 並行呼叫、逾時與清理

- 另一個 `join` 尚未完成時呼叫 `join`，會先讓前一個呼叫以 `cancelled` 結束。
  呼叫 `leave` 時也會如此。
- `timeout` 由原生層執行。逾時時，Android 會取消註冊網路請求，
  因此稍後的 `onAvailable` 不會再綁定 process；iOS 會移除設定，
  並清理逾時後才成功的 `apply` 所安裝的設定。
- 在 iOS 上，`removeConfiguration` 沒有完成回呼，因此 `join` 會在移除舊設定後，
  等待 `iosRemoveConfigurationDelay`（預設 300 ms），再套用新設定。
- 在 iOS 上，同一時間只會執行一個 `apply`。如果先前已取消的加入流程，其 `apply`
  仍在執行中（系統提示可能仍顯示），新的加入流程會在自己的 `timeout` 期限內等待。
  前一次 `apply` 安裝的設定會在套用新設定前移除。
- Flutter engine 被銷毀時，尚未完成的加入流程會取消，且 plugin 加入的所有網路資源
  都會被釋放：Android 釋放請求與綁定，iOS 移除設定。

### 區域網路權限探測（iOS）

`requestLocalNetworkPermission` 會以隨機名稱發布 `bonjourServiceType` 類型的
Bonjour 服務，並瀏覽該類型：

| 結果 | 意義 |
|---|---|
| `granted` | Browser 發現服務，表示區域網路存取可用 |
| `denied` | Listener 或 browser 失敗或進入等待狀態，且錯誤為 `kDNSServiceErr_PolicyDenied` |
| `timedOut` | 在 `timeout` 內沒有回應；通常是提示仍未關閉，或 `NSBonjourServices` 缺少該服務類型。應視為尚未取得權限 |
| `failed` | 其他 listener 或 browser 錯誤，或平台 channel 錯誤 |

其他 `waiting` 狀態，例如尚未有網路，屬於暫時狀態，因此探測會持續到 `timeout`。
並行呼叫各自使用獨立的 listener 與 browser。
無效的 `bonjourServiceType`（不是 `_name._tcp`），或小於 1 ms 的 `timeout`，
會拋出 `ArgumentError`。

## 從 `plugin_wifi_connect` 遷移

| `plugin_wifi_connect` | `local_wifi_join` |
|---|---|
| `PluginWifiConnect.connectToSecureNetwork(ssid, password)` | `(await LocalWifiJoin.join(ssid: ssid, passphrase: password)).isJoined` |
| `PluginWifiConnect.disconnect()` | `LocalWifiJoin.leave(ssid)` |
| 在呼叫外加上 `.timeout(...)` | `join(timeout: ...)`（由原生層執行） |

## 測試您的程式碼

Method channel 已公開供測試使用：

```dart
TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(LocalWifiJoin.channel, (call) async {
  if (call.method == 'join') return {'status': 'joined'};
  return null;
});
```

## 開發

```sh
# Dart 單元測試
fvm flutter test

# Android 狀態機（JVM）
(cd example && fvm flutter build apk --config-only)
(cd example/android && ./gradlew :local_wifi_join:testDebugUnitTest)

# iOS 狀態機（XCTest）
(cd example && fvm flutter build ios --config-only --simulator)
(cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
  -only-testing:RunnerTests -destination 'platform=iOS Simulator,name=<simulator>')

# 在實體裝置或模擬器上測試原生 channel
(cd example && fvm flutter test integration_test)
```

開發使用的 Flutter 版本固定於 `.fvmrc`。

## 授權

[MIT](LICENSE)
