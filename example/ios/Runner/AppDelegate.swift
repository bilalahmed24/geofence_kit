import Flutter
import geofence_kit
import UIKit

// Early native bootstrap: a terminated-state region event relaunches
// the process straight into `didFinishLaunchingWithOptions` — potentially
// BEFORE the implicit Flutter engine spins up and registers the plugin.
// `GeofenceKitPlugin.earlyBootstrap()` (idempotent) wires the CoreLocation
// region delegate + opens the restoration window NOW, so the relaunching
// region callback is queued (never lost) and the persisted engine session
// restores + reconciles before the outbox flushes. Keep this call FIRST in
// didFinishLaunchingWithOptions.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeofenceKitPlugin.earlyBootstrap()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
