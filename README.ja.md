# local_wifi_join

[English](README.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

[![pub package](https://img.shields.io/pub/v/local_wifi_join.svg)](https://pub.dev/packages/local_wifi_join)
[![CI](https://github.com/TerryHuangHD/local_wifi_join/actions/workflows/ci.yaml/badge.svg)](https://github.com/TerryHuangHD/local_wifi_join/actions/workflows/ci.yaml)

Flutter から WPA2-Personal の Wi-Fi アクセスポイントに接続・切断し、
ローカルネットワーク経由でデバイスと通信するためのプラグインです。
IoT デバイス自身が提供するホットスポットなどで利用できます。

- **iOS 26 以降に対応。** iOS では
  `NEHotspotConfigurationManager.apply` のエラーだけで接続結果を判定し、
  現在の SSID を読み取りません。iOS 26 以降では、`wifi-info` entitlement があっても
  `NEHotspotNetwork.fetchCurrent` が拒否されるため、SSID を読み取って確認するプラグインは、
  接続が成功していても失敗と判定してしまいます。
- **「Unable to join the network」を回避。** クラッシュ後など、
  前のセッションで残った設定を接続前に削除します。
- **ネイティブのタイムアウトとクリーンアップ。** 接続がタイムアウトまたはキャンセルされた場合、
  ネイティブ側で後処理を行います。Android では後からプロセスがネットワークにバインドされることはなく、
  iOS では接続処理の終了後にシステムが設定をインストールしても、その `apply` が完了した時点で削除します。
- **各呼び出しは必ず一度だけ完了**し、単なる `bool` ではなく、明確なステータス
  （`joined`、`userDenied`、`unavailable`、`timeout`、`cancelled` など）を返します。
- **Swift Package Manager と CocoaPods に対応。** UIScene と互換性があり、
  `AppDelegate` の変更は不要です。

| | Android | iOS |
|---|---|---|
| 最低バージョン | API 29（Android 10） | 13.0 |
| 仕組み | `WifiNetworkSpecifier` + `ConnectivityManager.requestNetwork` + `bindProcessToNetwork` | `NEHotspotConfiguration`（`joinOnce = true`） |

Flutter 3.44 以降が必要です。シミュレーターやエミュレーターには実際の Wi-Fi 機能がないため、
ネットワークへの接続は実機でテストしてください。

## セットアップ

```sh
flutter pub add local_wifi_join
```

### iOS

1. Runner ターゲットに **Hotspot Configuration** capability を追加します。
   これにより、次の entitlement が `Runner.entitlements` に追加されます。
   この設定がないと、すべての接続が失敗します。

   ```xml
   <key>com.apple.developer.networking.HotspotConfiguration</key>
   <true/>
   ```

2. 接続したネットワーク上のデバイスと通信するには、ローカルネットワークへのアクセス権限が必要です。
   `Info.plist` に用途の説明と、`requestLocalNetworkPermission` に渡す
   Bonjour サービスタイプを追加してください。

   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>Wi-Fi 経由でデバイスに接続するために使用します。</string>
   <key>NSBonjourServices</key>
   <array>
     <string>_myapp-probe._tcp</string>
   </array>
   ```

`wifi-info` entitlement と位置情報の権限は**不要**です。

### Android

- `minSdk` を 29 以上に設定してください。
- プラグインの manifest には `CHANGE_NETWORK_STATE`、`ACCESS_NETWORK_STATE`
  （`bindProcessToNetwork` が接続先ネットワークのプロキシ設定を適用するために必要）、
  `ACCESS_WIFI_STATE` が宣言されています。いずれもインストール時に付与される通常の権限で、
  アプリの manifest に自動的にマージされます。
- `dart:io` のソケットや HTTP でデバイスと通信するには、アプリの **main** manifest に
  `android.permission.INTERNET` が必要です。Flutter がこの権限を追加するのは
  debug と profile ビルドのみです。
- `NEARBY_WIFI_DEVICES` は宣言も要求もしません。Android の
  [この権限が必要な API の一覧](https://developer.android.com/develop/connectivity/wifi/wifi-permissions#check-for-apis)
  に `WifiNetworkSpecifier` によるネットワーク要求は含まれていません。
  アプリでこの権限が必要な場合は、`android:usesPermissionFlags="neverForLocation"` を指定して宣言し、
  `permission_handler` などを使って実行時にアプリ側で要求してください。

## 使用方法

```dart
import 'dart:io';

import 'package:local_wifi_join/local_wifi_join.dart';

Future<void> downloadFromDevice(String passphrase) async {
  const ssid = 'MY-DEVICE-AP';

  if (!await LocalWifiJoin.isWifiEnabled()) {
    // Wi-Fi をオンにするよう案内します（Android のみ。iOS は常に true）。
    return;
  }

  final permission = await LocalWifiJoin.requestLocalNetworkPermission(
    bonjourServiceType: '_myapp-probe._tcp', // NSBonjourServices に登録が必要
  );
  if (permission != LocalNetworkPermission.granted) {
    // ローカルネットワークへのアクセスが必要な理由を説明し、「設定」へのリンクを表示します。
    return;
  }

  try {
    final result = await LocalWifiJoin.join(ssid: ssid, passphrase: passphrase);
    if (!result.isJoined) {
      // result.status で理由を確認できます：userDenied、unavailable、timeout など。
      return;
    }

    // `joined` は通信可能であることを保証しません（後述）。
    // デバイスが応答するまで再試行してから、ソケットを使用します。
    final socket = await connectWithRetry('192.168.4.1', 8080);
    // ...
    socket?.destroy();
  } finally {
    // 冪等な操作です。接続が成立していなくても安全に呼び出せます。
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

アプリ全体のサンプルは [`example/`](example/lib/main.dart) にあります。

## API

| メソッド | Android | iOS |
|---|---|---|
| `join({ssid, passphrase, timeout = 30s, iosRemoveConfigurationDelay = 300ms})` | ネットワークを要求し、プロセスをバインド | 古い設定を削除し、待機後に `joinOnce` 設定を適用 |
| `leave(ssid)` | 要求を解放し、既定のネットワークに戻す（`ssid` は無視） | 指定された `ssid` の設定を名前で削除 |
| `isWifiEnabled()` | `WifiManager.isWifiEnabled`。プラットフォームが応答できない場合は `true`（fail-open） | 常に `true`（公開 API なし） |
| `requestLocalNetworkPermission({bonjourServiceType, timeout = 8s})` | 常に `granted` | Bonjour による確認（後述） |

その他のプラットフォームでは、すべてのメソッドが `UnsupportedError` で終了します。

### 接続ステータス

| ステータス | Android | iOS |
|---|---|---|
| `joined` | ネットワークが利用可能で、プロセスのバインドが完了 | `apply` が成功、または `alreadyAssociated`（`platformCode: 'alreadyAssociated'`） |
| `userDenied` | — | ユーザーがシステムの確認ダイアログで拒否 |
| `unavailable` | `onUnavailable`：ユーザーがダイアログをキャンセルした、**または**ネットワークが見つからなかった（Android では区別不可） | — |
| `timeout` | `timeout` 内に結果が得られず、要求を解放 | `timeout` 内に結果が得られず、設定を削除 |
| `cancelled` | 別の `join` に置き換えられた、または `leave` で終了 | 同左 |
| `notInForeground` | — | `applicationIsNotInForeground` |
| `invalidArguments` | 入力の検証に失敗（後述）、または `WifiNetworkSpecifier` が拒否 | 入力の検証に失敗、または `apply` が `invalid*` エラーを返した |
| `failed` | その他。`platformCode`（例外クラス名）と `message` を参照 | その他。`platformCode` は `NEHotspotConfigurationError` のケース名（例：`pending`） |

`join` はプラットフォームを呼び出す前に引数を検証します。
`ssid` は UTF-8 で 1–32 バイト、`passphrase` は印字可能な ASCII 文字で 8–63 文字
（64 桁の 16 進数形式の生の PSK は非対応）、`timeout` は 1 ms 以上である必要があり、
`iosRemoveConfigurationDelay` に負の値は指定できません。時間はミリ秒単位の精度で送信されます。
Android と iOS では `join` は例外をスローせず、`PlatformException` やネイティブプラグインの欠落は
`failed` として報告されます。`leave` も Android と iOS では例外をスローしません。

## 知っておくべき動作

### `joined` は通信可能であることを保証しない（iOS）

iOS の `joined` は、システムが設定を受け入れたことを意味します。
端末がアクセスポイントに接続済みであることを意味するわけではありません。
AP が圏外だったりパスワードが間違っていたりしても、iOS は `joined` を返す場合があります。
上のサンプルのようにデバイスへの TCP 接続を再試行するなど、到達可能性を必ずアプリ側で確認してください。

### `joinOnce` の制限（iOS）

設定は
[`joinOnce = true`](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce)
で適用されるため、ユーザーの Wi-Fi 設定には永続的に保存されません。
一方で、アプリが約 15 秒以上バックグラウンドに留まった場合、デバイスがスリープした場合、
またはアプリが終了した場合、iOS は接続を切断して設定を削除します。
データ転送中はアプリをフォアグラウンドに保ってください。

### プロセスのバインド（Android）

`joined` の後は、**プロセス全体**が接続先のネットワークにバインドされます。
その後に作成されるソケットやホスト名の名前解決は、`dart:io` の `Socket` や `HttpClient` の接続も含め、
そのネットワークを使用します。すでに開かれているソケットは元のネットワークを使い続けるため、
ネットワークの切り替え時には、接続前に作成した `HttpClient` の接続など、プールされた接続を閉じてください。
アクセスポイントには通常インターネット接続がないため、`leave` を呼び出すまでは
インターネットへの通信が失敗します。`leave` を呼ぶと、新しいソケットはシステムの既定のネットワークを使います。
接続中にネットワークが失われた場合（デバイスの電源が切れた場合など）、バインドと要求は自動的に解放され、
その後の `leave` 呼び出しは何も行いません。

接続中はネットワーク要求を登録したまま保持します。
Android は `WifiNetworkSpecifier` の要求が解放されると、そのネットワークへの接続を切断します。

### システムダイアログとフォアグラウンドの制約（Android）

要求のたびに Android の「デバイスに接続」ダイアログが表示されます。
Android はフォアグラウンドのアプリからの要求のみ受け付けます。
前の要求のダイアログがまだ表示されている間は、そのダイアログがフォアグラウンドのアプリとなるため、
新しい `join` はほぼ即座に `unavailable` で完了します。
再試行する前に、ユーザーにダイアログを閉じてもらってください。

### 同時呼び出し、タイムアウト、クリーンアップ

- 別の `join` が処理中の状態で `join` を呼び出すと、先の呼び出しがまず `cancelled` で完了します。
  `leave` を呼び出した場合も同様です。
- `timeout` はネイティブ側で実行されます。タイムアウトすると Android はネットワーク要求の登録を解除し、
  後から `onAvailable` が呼ばれてもプロセスはバインドされません。
  iOS は設定を削除し、タイムアウト後に成功した `apply` がインストールした設定も削除します。
- iOS の `removeConfiguration` には完了コールバックがないため、`join` は古い設定を削除した後、
  `iosRemoveConfigurationDelay`（既定値 300 ms）だけ待ってから新しい設定を適用します。
- iOS では一度に一つの `apply` だけを実行します。すでにキャンセルされた接続の `apply` がまだ処理中の場合
  （システムの確認ダイアログが表示されたままの場合など）、新しい接続は自身の `timeout` の範囲内で待機します。
  前の `apply` がインストールした設定は、新しい設定を適用する前に削除されます。
- Flutter engine が破棄されると、処理中の接続はキャンセルされ、プラグインが接続したネットワークに関する
  リソースはすべて解放されます。Android は要求とバインドを解放し、iOS は設定を削除します。

### ローカルネットワーク権限の確認（iOS）

`requestLocalNetworkPermission` は、ランダムな名前で `bonjourServiceType` の
Bonjour サービスを公開し、そのタイプのサービスを検索します。

| 結果 | 意味 |
|---|---|
| `granted` | Browser がサービスを検出したため、ローカルネットワークへのアクセスが利用可能 |
| `denied` | Listener または browser が失敗、または待機状態になり、エラーが `kDNSServiceErr_PolicyDenied` |
| `timedOut` | `timeout` 内に応答なし。通常はダイアログが開いたまま、または `NSBonjourServices` にタイプが未登録。権限が付与されていないものとして扱う |
| `failed` | その他の listener・browser のエラー、またはプラットフォーム channel のエラー |

その他の `waiting` 状態（まだネットワークがない場合など）は一時的なものとして扱い、
確認を `timeout` まで続けます。同時呼び出しには、それぞれ独立した listener と browser を使用します。
無効な `bonjourServiceType`（`_name._tcp` 形式ではない場合）や 1 ms 未満の `timeout` は
`ArgumentError` をスローします。

## `plugin_wifi_connect` からの移行

| `plugin_wifi_connect` | `local_wifi_join` |
|---|---|
| `PluginWifiConnect.connectToSecureNetwork(ssid, password)` | `(await LocalWifiJoin.join(ssid: ssid, passphrase: password)).isJoined` |
| `PluginWifiConnect.disconnect()` | `LocalWifiJoin.leave(ssid)` |
| 呼び出しを囲む `.timeout(...)` | `join(timeout: ...)`（ネイティブ側で実行） |

## アプリのコードのテスト

テスト用に method channel を公開しています。

```dart
TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(LocalWifiJoin.channel, (call) async {
  if (call.method == 'join') return {'status': 'joined'};
  return null;
});
```

## 開発

```sh
# Dart のユニットテスト
fvm flutter test

# Android のステートマシン（JVM）
(cd example && fvm flutter build apk --config-only)
(cd example/android && ./gradlew :local_wifi_join:testDebugUnitTest)

# iOS のステートマシン（XCTest）
(cd example && fvm flutter build ios --config-only --simulator)
(cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
  -only-testing:RunnerTests -destination 'platform=iOS Simulator,name=<simulator>')

# 実機またはシミュレーター上のネイティブ channel
(cd example && fvm flutter test integration_test)
```

開発に使用する Flutter のバージョンは `.fvmrc` で固定しています。

CI では XCTest とネイティブ channel の統合テストが、起動済みの同じ iOS
シミュレーターを使用し、XCTest の並列テストを無効にしています。
シミュレーターの準備、XCTest、統合テストの上限はそれぞれ 5、10、10 分、
SwiftPM ジョブの上限は 30 分です。統合テストは詳細ログを出力します。

## ライセンス

[MIT](LICENSE)
