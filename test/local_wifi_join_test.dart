import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_join/local_wifi_join.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  void mockNative(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalWifiJoin.channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  /// Leaves the channel without a handler, as when the plugin is not registered.
  void removeNative() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalWifiJoin.channel, null);
  }

  void onPlatform(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  setUp(() {
    calls.clear();
    mockNative((_) => null);
  });

  tearDown(removeNative);

  group('join', () {
    Future<WifiJoinResult> join({
      String ssid = 'DEVICE-AP',
      String passphrase = '12345678',
      Duration timeout = const Duration(seconds: 30),
      Duration iosRemoveConfigurationDelay = const Duration(milliseconds: 300),
    }) => LocalWifiJoin.join(
      ssid: ssid,
      passphrase: passphrase,
      timeout: timeout,
      iosRemoveConfigurationDelay: iosRemoveConfigurationDelay,
    );

    for (final status in WifiJoinStatus.values) {
      test('maps native status "${status.name}"', () async {
        mockNative(
          (_) => {
            'status': status.name,
            'platformCode': 'code',
            'message': 'details',
          },
        );

        final result = await join();

        expect(
          result,
          WifiJoinResult(status, platformCode: 'code', message: 'details'),
        );
        expect(result.isJoined, status == WifiJoinStatus.joined);
      });
    }

    test('reports an unrecognized native status as failed', () async {
      mockNative((_) => {'status': 'somethingNew', 'platformCode': 'x'});

      final result = await join();

      expect(result.status, WifiJoinStatus.failed);
      expect(result.platformCode, 'x');
      expect(result.message, contains('somethingNew'));
    });

    test('reports a null native reply as failed', () async {
      mockNative((_) => null);

      expect((await join()).status, WifiJoinStatus.failed);
    });

    test('reports a PlatformException as failed instead of throwing', () async {
      mockNative(
        (_) => throw PlatformException(code: 'boom', message: 'native error'),
      );

      expect(
        await join(),
        const WifiJoinResult(
          WifiJoinStatus.failed,
          platformCode: 'boom',
          message: 'native error',
        ),
      );
    });

    test(
      'reports a missing native plugin as failed instead of throwing',
      () async {
        removeNative();

        final result = await join();

        expect(result.status, WifiJoinStatus.failed);
        expect(result.platformCode, 'MissingPluginException');
      },
    );

    test('ignores malformed native diagnostics instead of throwing', () async {
      mockNative((_) => {'status': 'joined', 'platformCode': 42, 'message': 7});

      expect(await join(), const WifiJoinResult(WifiJoinStatus.joined));
    });

    group('validation', () {
      Future<void> expectInvalid(Future<WifiJoinResult> result) async {
        expect((await result).status, WifiJoinStatus.invalidArguments);
        expect(calls, isEmpty, reason: 'invalid input must not reach native');
      }

      Future<void> expectAccepted(Future<WifiJoinResult> result) async {
        await result;
        expect(calls.map((c) => c.method), ['join']);
      }

      test('rejects an empty SSID', () => expectInvalid(join(ssid: '')));

      test('accepts a 32-byte UTF-8 SSID', () {
        // 10 × 3-byte characters + 2 ASCII characters = 32 bytes.
        return expectAccepted(join(ssid: '${'無' * 10}ab'));
      });

      test('rejects a 33-byte UTF-8 SSID', () {
        return expectInvalid(join(ssid: '無' * 11));
      });

      test('accepts 8 and 63 character passphrases', () async {
        await expectAccepted(join(passphrase: 'a' * 8));
        calls.clear();
        await expectAccepted(join(passphrase: '~' * 63));
      });

      test('rejects a 7 character passphrase', () {
        return expectInvalid(join(passphrase: 'a' * 7));
      });

      test('rejects a 64 character passphrase', () {
        return expectInvalid(join(passphrase: 'a' * 64));
      });

      test('rejects non-ASCII and control characters in the passphrase', () {
        return Future.wait([
          expectInvalid(join(passphrase: 'pässword')),
          expectInvalid(join(passphrase: 'pass\tword')),
        ]);
      });

      test('rejects a non-positive timeout', () {
        return expectInvalid(join(timeout: Duration.zero));
      });

      test('rejects a sub-millisecond timeout', () {
        return expectInvalid(join(timeout: const Duration(microseconds: 999)));
      });

      test('accepts a 1 ms timeout', () {
        return expectAccepted(join(timeout: const Duration(milliseconds: 1)));
      });

      test('rejects a negative iOS remove-configuration delay', () {
        return expectInvalid(
          join(iosRemoveConfigurationDelay: const Duration(milliseconds: -1)),
        );
      });

      test('accepts a zero iOS remove-configuration delay', () {
        return expectAccepted(join(iosRemoveConfigurationDelay: Duration.zero));
      });
    });
  });

  group('leave', () {
    test('swallows a PlatformException', () async {
      mockNative((_) => throw PlatformException(code: 'invalidArguments'));

      await LocalWifiJoin.leave('DEVICE-AP');
      expect(calls.map((c) => c.method), ['leave']);
    });

    test('completes normally without a native plugin', () async {
      removeNative();

      await LocalWifiJoin.leave('DEVICE-AP');
    });
  });

  group('isWifiEnabled', () {
    test('is always true on iOS without asking native', () async {
      onPlatform(TargetPlatform.iOS);
      mockNative((_) => false);

      expect(await LocalWifiJoin.isWifiEnabled(), isTrue);
      expect(calls, isEmpty);
    });

    test('reports the native state on Android', () async {
      onPlatform(TargetPlatform.android);
      mockNative((_) => false);

      expect(await LocalWifiJoin.isWifiEnabled(), isFalse);
    });

    test(
      'fails open on a null reply, a PlatformException or no plugin',
      () async {
        onPlatform(TargetPlatform.android);

        mockNative((_) => null);
        expect(await LocalWifiJoin.isWifiEnabled(), isTrue);

        mockNative((_) => throw PlatformException(code: 'boom'));
        expect(await LocalWifiJoin.isWifiEnabled(), isTrue);

        removeNative();
        expect(await LocalWifiJoin.isWifiEnabled(), isTrue);
      },
    );
  });

  group('requestLocalNetworkPermission', () {
    test('is always granted on Android without asking native', () async {
      onPlatform(TargetPlatform.android);
      mockNative((_) => 'denied');

      expect(
        await LocalWifiJoin.requestLocalNetworkPermission(
          bonjourServiceType: '_probe._tcp',
        ),
        LocalNetworkPermission.granted,
      );
      expect(calls, isEmpty);
    });

    const nativeStatuses = {
      'granted': LocalNetworkPermission.granted,
      'denied': LocalNetworkPermission.denied,
      'timedOut': LocalNetworkPermission.timedOut,
      'failed': LocalNetworkPermission.failed,
      'somethingNew': LocalNetworkPermission.failed,
    };
    nativeStatuses.forEach((native, expected) {
      test('maps native "$native" to ${expected.name} on iOS', () async {
        onPlatform(TargetPlatform.iOS);
        mockNative((_) => native);

        expect(
          await LocalWifiJoin.requestLocalNetworkPermission(
            bonjourServiceType: '_preflight_check._tcp.',
          ),
          expected,
        );
      });
    });

    test(
      'reports native errors and a missing plugin as failed on iOS',
      () async {
        onPlatform(TargetPlatform.iOS);
        Future<LocalNetworkPermission> request() =>
            LocalWifiJoin.requestLocalNetworkPermission(
              bonjourServiceType: '_probe._tcp',
            );

        mockNative((_) => throw PlatformException(code: 'invalidArguments'));
        expect(await request(), LocalNetworkPermission.failed);

        removeNative();
        expect(await request(), LocalNetworkPermission.failed);
      },
    );

    for (final type in [
      '',
      'probe._tcp',
      '_probe._udp',
      '_probe',
      '_${'a' * 16}._tcp',
      '_pro be._tcp',
    ]) {
      test('rejects service type "$type"', () {
        onPlatform(TargetPlatform.iOS);

        expect(
          LocalWifiJoin.requestLocalNetworkPermission(bonjourServiceType: type),
          throwsArgumentError,
        );
      });
    }

    test('rejects a sub-millisecond timeout', () {
      onPlatform(TargetPlatform.iOS);

      for (final timeout in [
        Duration.zero,
        const Duration(microseconds: 999),
      ]) {
        expect(
          LocalWifiJoin.requestLocalNetworkPermission(
            bonjourServiceType: '_probe._tcp',
            timeout: timeout,
          ),
          throwsArgumentError,
        );
      }
    });
  });

  group('unsupported platforms', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      test('every method throws UnsupportedError on ${platform.name}', () {
        onPlatform(platform);

        expect(
          LocalWifiJoin.join(ssid: 'DEVICE-AP', passphrase: '12345678'),
          throwsUnsupportedError,
        );
        expect(LocalWifiJoin.leave('DEVICE-AP'), throwsUnsupportedError);
        expect(LocalWifiJoin.isWifiEnabled(), throwsUnsupportedError);
        expect(
          LocalWifiJoin.requestLocalNetworkPermission(
            bonjourServiceType: '_probe._tcp',
          ),
          throwsUnsupportedError,
        );
        expect(calls, isEmpty);
      });
    }
  });
}
