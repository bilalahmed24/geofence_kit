# geofence_kit — example app (iOS + Android) · complete runnable harness

Registers the **reference geofence on app boot** and proves geofence event
delivery in **every app state** — foreground, background, terminated — on
both platforms, using **debug local notifications** and an in-app event log.

```
fence:  reference-fence
center: 40.782849, -73.965572   (Central Park, New York)
radius: 250 m
dwell:  30 s (DWELL fires once per visit, survives process death)
```

## 1. What it demonstrates — the two debug checkpoints

Every geofence event is observable at **two points of the delivery
chain** (the example sets `showDebugNotification: true` on `start` so
the plugin's native debug notes post in every app state):

| Checkpoint | Notification | What it proves |
|---|---|---|
| ① **Native captured** | `geofence_kit · ENTER · reference-fence` — body: `captured NATIVELY (app background/killed)` + provenance (src/tier/motion/dist/acc/conf) | The engine committed the transition natively — works foreground, background AND terminated (Android foreground-service engine / iOS region relaunch) |
| ② **Engine ALIVE / DEAD** | Android: the persistent foreground-service notification `geofence_kit · tracking active` — `engine ALIVE · beat #N · preset … · provider … · HH:mm:ss` (refreshed on every heartbeat beat; a stale clock = dead). iOS: `geofence_kit · engine ALIVE` notification refreshed per beat | Whether the tracking engine is alive right now, in any app state |

The app-side surfacing (the plugin posts NO user-facing
notifications) is the in-app event log: every log tile carries a **badge
of the app lifecycle state at receipt** (`fg` / `bg` / `killed`) — the
state-coverage evidence — plus the live engine snapshot panel
(preset / tier / motion / **motionSource** · activity-recognition /
sensor-fusion / speed-heuristic / **locationProvider** · gms-fused /
hms-fused / platform / heartbeats / outbox count).

## 2. Run it

Prerequisites: Flutter stable (**≥ 3.41** — the iOS example uses the
UIScene life-cycle template APIs and the plugin's Swift Package Manager
integration), Android SDK 35 (for Android), Xcode 15+ (Xcode 27 / iOS 26+
SDK tested) with an Apple ID signing into Xcode (for iOS).

### Android

```bash
cd example
flutter pub get
flutter run            # debug — or --release for perf runs
```

The first `start()` drives the permission ladder itself:
Precise location (+ Notifications on Android 13+) → **Allow all the time**
(background location, needed for terminated-state geofencing) → Physical
activity → Allow. `await start(...)` resolves once the prompts settle —
the status line then reads `tracking 1 fence(s)`.

HMS (Huawei, no Play Services): the engine picks HMS up automatically via
reflection — enable it in two places (both commented, ready to flip):

```groovy
// android/build.gradle (root) — allprojects.repositories:
maven { url 'https://developer.huawei.com/repo/' }

// android/app/build.gradle — dependencies:
implementation "com.huawei.hms:location:6.16.0.302"
```

### iOS

```bash
cd example
flutter pub get
flutter run            # simulator or device — plugins resolve via Swift Package Manager (no CocoaPods)
```

Grant when prompted: **Allow While Using → upgrade to Always** (Settings →
the app → Location → Always — needed for terminated-state fixes), Motion &
Fitness → On, Notifications → Allow. For physical-device runs pick a
signing team in Xcode (`open example/ios/Runner.xcworkspace` → Runner →
Signing & Capabilities) or `flutter run` will ask.

The plugin links the prebuilt `geofence_kit.xcframework` through
`ios/geofence_kit/Package.swift` (product `geofence-kit`) — the
example project is wired for Swift Package Manager only: no Podfile,
no Pods xcconfig includes; at build time the Flutter tool symlinks the
plugin package into `ios/Flutter/ephemeral/Packages/.packages/` next
to the generated `FlutterFramework` package (which provides the
`Flutter` module). Nothing to wire manually. The podspec remains for
app consumers still on CocoaPods.

> **iPhone 17 / Xcode 27 simulator note:** the example is
> migrated to the UIScene life cycle (mandatory for apps built with the
> iOS 26+ SDK), its scheme carries the `flutter_lldbinit` debugger hook
> that new iOS versions require for debug-mode launches, and the project
> is migrated fully off CocoaPods onto Swift Package Manager. If your
> checkout ever ran `pod install`, clean leftovers once:
> `cd example/ios && pod deintegrate && rm -rf Pods Podfile.lock`.

### Release builds

DEBUG and RELEASE builds behave identically.

## 3. Verification protocol (all app states)

Stand ~300+ m away from 40.782849, -73.965572 (outside the 250 m fence —
the exit radius is 1.15 R ≈ 288 m).

1. **Foreground ENTER/EXIT** — walk toward the center with the app open.
   Expect the checkpoint ① notification and the log tile
   `ENTER source=fix tier=edge` after the accuracy gate confirms
   (≤ max(25 m, R/2) = 125 m accuracy), then `DWELL` ~30 s later.
   Walk out → `EXIT`.
2. **Foreground drive-by** — cross the fence by car without stopping.
   Expect a fast-path transition with high `speed` and confidence ≥ 0.85
   (single-fix velocity fast-path, > 8 m/s).
3. **Background** — background the app (home), cross the boundary.
   Expect the ① notification within seconds; the log tile appears on
   return (plus any outbox drain).
4. **Terminated** — kill the app from the app switcher, cross the boundary.
   Expect the ① notification (Android: the foreground-service engine keeps
   running — check ② stays fresh; iOS: the region event relaunches the
   process). Relaunch the app → log entries replay from the outbox
   (with `source=reconcile` when the state was reconstructed).
5. **DWELL survives death** — enter the fence, kill the app within the
   30 s dwell window, wait 1+ minutes, relaunch: the DWELL event arrives
   with `source=reconcile`.
6. **Device reboot (Android)** — reboot the phone, cross the boundary
   without opening the app: the boot-restored engine fires the ①
   notification (OS geofences are re-registered by the plugin's
   `BootReceiver`).
7. **Alive/idle** — park outside all fences for 10+ min with the screen
   off: ② keeps ticking every heartbeat (~5 min), and the snapshot (after
   reopening) shows preset `scout` or `off` (motion STILL-latch engaged) —
   the duty-cycle works.

On a device without Google Play Services, the snapshot's
`locationProvider` shows `hms-fused` (with the HMS dependency) or
`platform`, and `motionSource` shows `sensor-fusion` — the no-GMS chain.

### Testing on the iOS simulator (Custom Location)

The engine works on the simulator out of the box — one
Custom Location mock per phase is enough (the engine's corroboration
pump elicits the confirming fix itself via `requestLocation()`):

1. Run the app, grant **Always** location (upgrade in Settings if the
   prompt only offered While Using) and **Allow** notifications.
2. Simulator → **Features → Location → Custom Location…** → enter the
   fence center exactly: `40.782849`, `-73.965572` → Set. Stay put —
   no need to re-pick.
3. Expect the **ENTER** notification ~2–3 s after the mock (location
   icon in the status bar is normal — updates are running), then
   **DWELL** ~30 s after ENTER (the configured loitering delay).
4. Custom Location again, `40.786443`, `-73.965572` (~400 m north —
   beyond the 288 m exit radius) → Set. Expect **EXIT** ~2–3 s later.
5. Background the app (home) and repeat: with Always authorization the
   notifications arrive while backgrounded. For the terminated state
   on a simulator, region relaunches are unreliable — verify it on a
   real device (the engine's relaunch path is covered by the event
   simulation's terminated scenarios).

Mock **well inside the fence** (≤ 0.85 R ≈ 212 m from the center, so
the exact center is perfect): between 212 m and 250 m is the hysteresis
entry dead-band, where an ENTER is intentionally withheld.

## 4. Troubleshooting

- **No ① notification on Android while terminated** → check the app isn't
  "Optimized" away by the OEM battery manager (add to the battery
  optimization exemption); the ② notification is the liveness probe.
- **`start()` returned `LOCATION_DENIED`** → grant Precise location (and
  "Allow all the time") in system settings, then relaunch the app (it
  re-registers on every boot).
- **iOS terminated events need Always authorization** — When-In-Use only
  delivers while the app is foreground/background-alive.
