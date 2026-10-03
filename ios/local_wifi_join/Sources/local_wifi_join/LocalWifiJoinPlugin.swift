import Flutter
import UIKit

/// iOS implementation of the `local_wifi_join` method channel.
///
/// Registered by the generated plugin registrant; works with both the UIScene
/// (`FlutterImplicitEngineDelegate`) and the classic app delegate lifecycle.
/// All channel calls and replies happen on the main thread.
public final class LocalWifiJoinPlugin: NSObject, FlutterPlugin {
  private let joinCoordinator = HotspotJoinCoordinator(
    configurator: SystemHotspotConfigurator(),
    scheduler: MainQueueScheduler()
  )
  private var permissionProbes: [UUID: LocalNetworkPermissionProbe] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "local_wifi_join",
      binaryMessenger: registrar.messenger()
    )
    let instance = LocalWifiJoinPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    // Publishing is what makes Flutter call `detachFromEngine(for:)` on engine teardown.
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    joinCoordinator.dispose()
    permissionProbes.values.forEach { $0.cancel() }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "join":
      join(args, result: result)
    case "leave":
      guard let ssid = args?["ssid"] as? String else {
        result(Self.invalidArguments("leave requires a String ssid"))
        return
      }
      joinCoordinator.leave(ssid: ssid)
      result(nil)
    case "requestLocalNetworkPermission":
      requestLocalNetworkPermission(args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func join(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard
      let ssid = args?["ssid"] as? String,
      let passphrase = args?["passphrase"] as? String,
      let timeoutMillis = args?["timeoutMillis"] as? Int, timeoutMillis > 0,
      let removeDelayMillis = args?["removeConfigurationDelayMillis"] as? Int,
      removeDelayMillis >= 0
    else {
      result(
        JoinOutcome.invalidArguments(
          "join requires String ssid, String passphrase, a positive int timeoutMillis"
            + " and a non-negative int removeConfigurationDelayMillis"
        ).asDictionary)
      return
    }
    joinCoordinator.join(
      ssid: ssid,
      passphrase: passphrase,
      timeout: Double(timeoutMillis) / 1000,
      removeDelay: Double(removeDelayMillis) / 1000
    ) { outcome in
      result(outcome.asDictionary)
    }
  }

  private func requestLocalNetworkPermission(
    _ args: [String: Any]?, result: @escaping FlutterResult
  ) {
    guard
      let serviceType = args?["bonjourServiceType"] as? String,
      let timeoutMillis = args?["timeoutMillis"] as? Int, timeoutMillis > 0
    else {
      result(
        Self.invalidArguments(
          "requestLocalNetworkPermission requires a String bonjourServiceType"
            + " and a positive int timeoutMillis"))
      return
    }
    let id = UUID()
    let probe = LocalNetworkPermissionProbe(
      serviceType: serviceType,
      timeout: Double(timeoutMillis) / 1000
    )
    permissionProbes[id] = probe
    probe.start { [weak self] status in
      self?.permissionProbes[id] = nil
      result(status.rawValue)
    }
  }

  private static func invalidArguments(_ message: String) -> FlutterError {
    FlutterError(code: "invalidArguments", message: message, details: nil)
  }
}
