import 'package:flutter/foundation.dart';

/// Outcome category of `LocalWifiJoin.join`.
enum WifiJoinStatus {
  /// The platform accepted the join.
  ///
  /// * iOS: `NEHotspotConfigurationManager.apply` completed without an error,
  ///   or with `alreadyAssociated`. This only means the system accepted the
  ///   configuration; it does **not** prove that the device is associated
  ///   with the access point. Verify reachability yourself, for example by
  ///   retrying a TCP connection to the peer.
  /// * Android: the network request became available and the process was
  ///   bound to that network.
  joined,

  /// iOS: the user declined the system "wants to join" prompt
  /// (`NEHotspotConfigurationError.userDenied`).
  userDenied,

  /// Android: the network request could not be fulfilled (`onUnavailable`).
  ///
  /// Either the user cancelled the system dialog or the network was not
  /// found; Android does not tell the two apart.
  unavailable,

  /// The timeout passed to `LocalWifiJoin.join` elapsed before the platform
  /// reported a result. Nothing from the attempt is left behind.
  timeout,

  /// The join was superseded by another `LocalWifiJoin.join` call, or ended by
  /// `LocalWifiJoin.leave`, before it completed.
  cancelled,

  /// iOS: the app was not in the foreground
  /// (`NEHotspotConfigurationError.applicationIsNotInForeground`).
  notInForeground,

  /// The SSID, passphrase or durations were rejected, either by this
  /// package's validation or by the platform.
  invalidArguments,

  /// Any other failure. See [WifiJoinResult.platformCode] and
  /// [WifiJoinResult.message] for details.
  failed,
}

/// Result of `LocalWifiJoin.join`.
@immutable
final class WifiJoinResult {
  /// Creates a result with the given [status] and optional platform details.
  const WifiJoinResult(this.status, {this.platformCode, this.message});

  /// Outcome category.
  final WifiJoinStatus status;

  /// Platform-specific code for diagnostics, if any.
  ///
  /// * iOS: the `NEHotspotConfigurationError` case name (for example
  ///   `alreadyAssociated` or `pending`), or `<domain>(<code>)` for errors
  ///   from other domains.
  /// * Android: the exception class name (for example `SecurityException`),
  ///   or a short identifier such as `bindProcessToNetworkFailed`.
  ///
  /// Codes are for logging only and are not part of the stable API.
  final String? platformCode;

  /// Human-readable details for diagnostics, if any.
  final String? message;

  /// Whether [status] is [WifiJoinStatus.joined].
  bool get isJoined => status == WifiJoinStatus.joined;

  @override
  bool operator ==(Object other) =>
      other is WifiJoinResult &&
      other.status == status &&
      other.platformCode == platformCode &&
      other.message == message;

  @override
  int get hashCode => Object.hash(status, platformCode, message);

  @override
  String toString() {
    final details = [
      if (platformCode != null) 'platformCode: $platformCode',
      if (message != null) 'message: $message',
    ];
    return details.isEmpty
        ? 'WifiJoinResult(${status.name})'
        : 'WifiJoinResult(${status.name}, ${details.join(', ')})';
  }
}
