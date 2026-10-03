import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_network_permission.dart';
import 'wifi_join_result.dart';

/// Joins and leaves a WPA2-Personal Wi-Fi access point.
///
/// Supported on Android (API 29+) and iOS (13+). On any other platform every
/// method completes with an [UnsupportedError].
///
/// All timeouts are enforced natively, so a timed-out or cancelled attempt
/// is torn down: on Android it can no longer bind the process later, and on
/// iOS a configuration that the system installs after the attempt ended is
/// removed as soon as its `apply` completes.
///
/// Durations are sent to the platform with millisecond precision.
abstract final class LocalWifiJoin {
  /// The method channel shared with the native implementations.
  ///
  /// Exposed so tests can install a mock handler with
  /// `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
  /// .setMockMethodCallHandler(LocalWifiJoin.channel, ...)`.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('local_wifi_join');

  static final RegExp _bonjourServiceType = RegExp(
    r'^_[A-Za-z0-9_-]{1,15}\._tcp\.?$',
  );

  static final Map<String, WifiJoinStatus> _joinStatusByName = WifiJoinStatus
      .values
      .asNameMap();

  static const Duration _minTimeout = Duration(milliseconds: 1);

  /// Joins the WPA2-Personal network [ssid] (exact match) using [passphrase].
  ///
  /// Every call completes exactly once and never throws on Android or iOS;
  /// failures, including a missing native plugin, are reported through
  /// [WifiJoinResult.status].
  ///
  /// * [timeout] is enforced natively. When it elapses the attempt is torn
  ///   down and the result is [WifiJoinStatus.timeout].
  /// * A call made while a previous join is still pending completes the
  ///   previous one with [WifiJoinStatus.cancelled] first.
  /// * [ssid] must be 1–32 bytes of UTF-8. [passphrase] must be 8–63
  ///   printable ASCII characters. [timeout] must be at least 1 ms.
  ///   Otherwise the result is [WifiJoinStatus.invalidArguments] and nothing
  ///   is sent to the platform.
  ///
  /// iOS: any existing configuration for [ssid] is removed first, then after
  /// [iosRemoveConfigurationDelay] a `joinOnce` configuration is applied. If
  /// the `apply` of an earlier join is still in flight (for example its
  /// system prompt is still on screen), this join waits for it, within its
  /// own [timeout]. [WifiJoinStatus.joined] only means iOS accepted the
  /// configuration, not that the device is associated: verify reachability
  /// yourself. While joined, iOS drops the network when the app stays in the
  /// background for more than about 15 seconds, the device sleeps, or the app
  /// exits.
  ///
  /// Android: requests the network with a `WifiNetworkSpecifier` (the system
  /// shows its "connect to device" dialog) and binds the whole process to it,
  /// so sockets and host lookups created afterwards, including `dart:io`
  /// ones, use that network until [leave]. Sockets that are already open keep
  /// their original network. If the network is lost later, the binding and
  /// the request are released automatically. [iosRemoveConfigurationDelay]
  /// is ignored.
  static Future<WifiJoinResult> join({
    required String ssid,
    required String passphrase,
    Duration timeout = const Duration(seconds: 30),
    Duration iosRemoveConfigurationDelay = const Duration(milliseconds: 300),
  }) async {
    _requireSupportedPlatform('join');

    final invalid = _validateJoin(
      ssid: ssid,
      passphrase: passphrase,
      timeout: timeout,
      iosRemoveConfigurationDelay: iosRemoveConfigurationDelay,
    );
    if (invalid != null) {
      return WifiJoinResult(WifiJoinStatus.invalidArguments, message: invalid);
    }

    try {
      final reply = await channel.invokeMapMethod<String, Object?>('join', {
        'ssid': ssid,
        'passphrase': passphrase,
        'timeoutMillis': timeout.inMilliseconds,
        'removeConfigurationDelayMillis':
            iosRemoveConfigurationDelay.inMilliseconds,
      });
      return _parseJoinReply(reply);
    } on PlatformException catch (e) {
      return WifiJoinResult(
        WifiJoinStatus.failed,
        platformCode: e.code,
        message: e.message,
      );
    } on MissingPluginException catch (e) {
      return WifiJoinResult(
        WifiJoinStatus.failed,
        platformCode: 'MissingPluginException',
        message: e.message,
      );
    }
  }

  /// Leaves the network joined by [join] and cleans up after it.
  ///
  /// Idempotent, safe to call when nothing was joined, and never throws on
  /// Android or iOS. Completes any pending [join] with
  /// [WifiJoinStatus.cancelled].
  ///
  /// * iOS: removes the hotspot configuration for [ssid] by name. The current
  ///   SSID is never read.
  /// * Android: releases the network request and restores the process's
  ///   default network for sockets created afterwards. [ssid] is ignored.
  static Future<void> leave(String ssid) async {
    _requireSupportedPlatform('leave');
    try {
      await channel.invokeMethod<void>('leave', {'ssid': ssid});
    } on PlatformException {
      // Native `leave` only rejects malformed arguments, which Dart never sends.
    } on MissingPluginException {
      // Without the native plugin no join can have succeeded: nothing to undo.
    }
  }

  /// Whether Wi-Fi is turned on.
  ///
  /// Android: `WifiManager.isWifiEnabled`. iOS has no public API for this and
  /// always returns `true`. Fails open: if the platform cannot answer, the
  /// result is `true`, so a join is attempted rather than wrongly blocked.
  static Future<bool> isWifiEnabled() async {
    if (_isIOS) return true;
    _requireSupportedPlatform('isWifiEnabled');
    try {
      return await channel.invokeMethod<bool>('isWifiEnabled') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Triggers the iOS Local Network permission prompt and reports its state.
  ///
  /// Publishes a Bonjour service of [bonjourServiceType] and browses for it;
  /// seeing it means access is granted. [bonjourServiceType] (for example
  /// `_myapp-probe._tcp`) must be listed under `NSBonjourServices` in the
  /// app's `Info.plist`, otherwise the probe can only time out. Concurrent
  /// calls are independent of each other.
  ///
  /// Throws an [ArgumentError] when [bonjourServiceType] is not of the form
  /// `_name._tcp` (an optional trailing `.` is allowed) or [timeout] is
  /// shorter than 1 ms. Platform errors are reported as
  /// [LocalNetworkPermission.failed].
  ///
  /// Android has no such permission and always returns
  /// [LocalNetworkPermission.granted].
  static Future<LocalNetworkPermission> requestLocalNetworkPermission({
    required String bonjourServiceType,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_bonjourServiceType.hasMatch(bonjourServiceType)) {
      throw ArgumentError.value(
        bonjourServiceType,
        'bonjourServiceType',
        'Must look like "_name._tcp" with a 1-15 character name',
      );
    }
    if (timeout < _minTimeout) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be at least 1 ms');
    }
    if (_isAndroid) return LocalNetworkPermission.granted;
    _requireSupportedPlatform('requestLocalNetworkPermission');

    final String? status;
    try {
      status = await channel
          .invokeMethod<String>('requestLocalNetworkPermission', {
            'bonjourServiceType': bonjourServiceType,
            'timeoutMillis': timeout.inMilliseconds,
          });
    } on PlatformException {
      return LocalNetworkPermission.failed;
    } on MissingPluginException {
      return LocalNetworkPermission.failed;
    }
    return switch (status) {
      'granted' => LocalNetworkPermission.granted,
      'denied' => LocalNetworkPermission.denied,
      'timedOut' => LocalNetworkPermission.timedOut,
      _ => LocalNetworkPermission.failed,
    };
  }

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static void _requireSupportedPlatform(String method) {
    if (_isAndroid || _isIOS) return;
    throw UnsupportedError(
      'LocalWifiJoin.$method is only supported on Android and iOS.',
    );
  }

  static String? _validateJoin({
    required String ssid,
    required String passphrase,
    required Duration timeout,
    required Duration iosRemoveConfigurationDelay,
  }) {
    final ssidBytes = utf8.encode(ssid).length;
    if (ssidBytes < 1 || ssidBytes > 32) {
      return 'ssid must be 1-32 bytes of UTF-8, got $ssidBytes bytes';
    }
    if (passphrase.length < 8 || passphrase.length > 63) {
      return 'passphrase must be 8-63 characters, got ${passphrase.length}';
    }
    if (passphrase.codeUnits.any((c) => c < 0x20 || c > 0x7e)) {
      return 'passphrase must contain printable ASCII characters only';
    }
    if (timeout < _minTimeout) {
      return 'timeout must be at least 1 ms';
    }
    if (iosRemoveConfigurationDelay < Duration.zero) {
      return 'iosRemoveConfigurationDelay must not be negative';
    }
    return null;
  }

  static WifiJoinResult _parseJoinReply(Map<String, Object?>? reply) {
    final status = reply?['status'];
    final platformCode = _stringOrNull(reply?['platformCode']);
    final message = _stringOrNull(reply?['message']);
    final parsed = status is String ? _joinStatusByName[status] : null;
    if (parsed == null) {
      return WifiJoinResult(
        WifiJoinStatus.failed,
        platformCode: platformCode,
        message: 'Unrecognized native join reply: $reply',
      );
    }
    return WifiJoinResult(parsed, platformCode: platformCode, message: message);
  }

  static String? _stringOrNull(Object? value) => value is String ? value : null;
}
