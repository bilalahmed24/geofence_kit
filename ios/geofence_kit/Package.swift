// swift-tools-version:5.9
//
// geofence_kit — Swift Package Manager manifest (vendored-binary mode,
// v1.0.0).
//
// Vends the prebuilt geofence_kit.xcframework (static; module
// geofence_kit) that ships INSIDE this package at
// ios/geofence_kit/geofence_kit.xcframework — there is nothing to download and nothing to configure.
// Layout contract (unchanged from the source-mode build):
//   * package dir:  ios/geofence_kit/ — the path convention the Flutter
//     tool requires (it joins <plugin root>/ios/<plugin name>); the
//     directory name gives the package identity `geofence_kit`.
//   * product name: "geofence-kit" — REQUIRED, non-negotiable: the Flutter
//     tool requests `.product(name: plugin.name.replaceAll('_', '-'))`
//     because CFBundleIdentifiers cannot contain underscores.
//   * target name:  "geofence_kit" — a .binaryTarget's name MUST match the
//     framework's name inside the xcframework; the framework is therefore
//     geofence_kit.xcframework (module geofence_kit, matching the
//     registrant's `@import geofence_kit` fallback import).
//
// CocoaPods hosts: the podspec's vendored_frameworks links the very same
// framework directory — nothing to run, nothing to configure.
//
// FlutterFramework dependency (required by the Flutter tool's plugin
// validation): resolves to the generated FlutterFramework package staged
// next to this one under <app>/ios/Flutter/ephemeral/Packages/.packages/.
// At app link time the framework's undefined Flutter symbols resolve
// against the app's Flutter.framework (static vendored framework → linked
// into the final binary).
//
// Note: with a binary target the package-level FlutterFramework dependency
// is intentionally unused by any target — Xcode may emit an "unused
// dependency" warning; that is cosmetic and the dependency stays (the
// Flutter tool's validator requires it).

import PackageDescription

let package = Package(
    name: "geofence_kit",
    platforms: [
        .iOS("15.0"),
    ],
    products: [
        .library(name: "geofence-kit", targets: ["geofence_kit"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .binaryTarget(name: "geofence_kit", path: "geofence_kit.xcframework"),
    ]
)
