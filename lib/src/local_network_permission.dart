/// Result of `LocalWifiJoin.requestLocalNetworkPermission`.
enum LocalNetworkPermission {
  /// The Bonjour probe discovered its own service, so local network access is
  /// allowed. Always returned on Android, which has no such permission.
  granted,

  /// The system refused the probe with `kDNSServiceErr_PolicyDenied`: the user
  /// denied local network access (now or earlier, in Settings).
  denied,

  /// No answer within the timeout. Typically the permission prompt is still
  /// on screen, or the Bonjour service type is missing from the app's
  /// `NSBonjourServices`. Treat it as "not granted".
  timedOut,

  /// The probe failed for another reason, for example a malformed service
  /// type or a listener error.
  failed,
}
