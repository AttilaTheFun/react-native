/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import React
import ReactAppDependencyProvider
import React_RCTAppDelegate
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

    #if DEBUG
    let devMenuConfiguration = RCTDevMenuConfiguration(
      devMenuEnabled: true,
      shakeGestureEnabled: true,
      keyboardShortcutsEnabled: true
    )
    reactNativeFactory?.devMenuConfiguration = devMenuConfiguration
    #endif

    window = UIWindow(frame: UIScreen.main.bounds)

    factory.startReactNative(
      withModuleName: "TapCounter",
      in: window,
      launchOptions: launchOptions
    )

    RNBenchHarness.installIfRequested()

    return true
  }
}

// MARK: - Cross-framework counter benchmark harness (iOS)
//
// RN's cell of the universal_ui benchmark (docs/benchmarks.md#ios in that
// repo). Protocol-compatible with the UUI cells' harness: armed by the
// UUI_BENCH=1 environment (devicectl: DEVICECTL_CHILD_UUI_BENCH=1), writes
// Documents/bench.json {run, startupMs, launchToContentMs, taps, tapMedianMs,
// tapMeanMs}.
//
// Startup anchor: process start (sysctl p_starttime, dyld included) → the
// first main-runloop pass whose committed view state contains BOTH the
// counter label and the button (observer at order 0, ahead of Core
// Animation's commit observer at 2_000_000).
//
// Tap anchor: trigger → detection of the COMPLETE update — the pending
// window closes only when both the label text AND its frame have changed
// (the count string changes width, so layout is part of the update; per-tap
// text+/frame+ provenance is recorded). Detection, not a CATransaction
// completion: RN mounts on its own scheduler tick, and a completion block
// attached from the observer can bind to an empty follow-up transaction plus
// idle-display refresh scheduling — dead wait that isn't framework work (it
// inflated earlier readings ~2.5x). Trigger phase is randomized to avoid
// phase-locking to the render tick. The trigger is
// UIView.accessibilityActivate() on the Pressable, which Fabric maps to the
// JS onAccessibilityTap prop — the same native→JS→setState→shadow-tree→mount
// round trip a real touch performs.
@MainActor
final class RNBenchHarness: NSObject {
  static var shared: RNBenchHarness?

  static func installIfRequested() {
    guard ProcessInfo.processInfo.environment["UUI_BENCH"] == "1" else { return }
    // A fresh run must never be confused with a previous launch's file.
    if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent("bench.json"))
    }
    let harness = RNBenchHarness()
    shared = harness
    harness.start()
  }

  private let launchedAt = CACurrentMediaTime()
  private var startupMs: Double?
  private var launchToContentMs: Double?
  private var taps: [Double] = []
  private var pendingTapStart: CFTimeInterval?
  private var lastLabelText = ""
  private var tapDetails: [String] = []
  private var pendingTextAt: CFTimeInterval?
  private var pendingFrameAt: CFTimeInterval?
  private var pendingFrame0 = CGRect.zero
  private var pendingTurns = 0
  private var tapsRemaining = 15
  private var observer: CFRunLoopObserver?

  private func start() {
    // Order 0 runs before CA's commit observer (2_000_000) in the same
    // before-waiting pass, so a completion block attached here belongs to
    // the commit that publishes what we just detected.
    observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.runLoopTick() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  private func runLoopTick() {
    guard let window = keyWindow() else { return }
    if startupMs == nil {
      guard findLabelView(in: window) != nil, findButton(in: window) != nil else { return }
      // Detection anchor: by the time this observer pass sees the mounted
      // views, the framework's own transaction containing them has been (or
      // is being) committed this turn; anchoring to a completion block risks
      // attaching to an empty follow-up transaction (dead wait) when the
      // mount was committed by the framework's own scheduler tick.
      startupMs = Self.msSinceProcessStart()
      launchToContentMs = (CACurrentMediaTime() - launchedAt) * 1000
      NSLog("[bench] content frame: startup=%.1fms launch->content=%.1fms",
            startupMs ?? -1, launchToContentMs ?? -1)
      // Settle, then drive the taps.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.tap() }
      return
    }
    guard let t0 = pendingTapStart, let label = findLabelView(in: window) else { return }
    // The pending window closes only when BOTH the label text and its frame
    // have changed — the frame growth ("Tapped 9" → "Tapped 10") is part of
    // the update; a text-only anchor could credit a render whose layout
    // hasn't landed.
    pendingTurns += 1
    let now = CACurrentMediaTime()
    let text = label.accessibilityLabel ?? ""
    if pendingTextAt == nil, text != lastLabelText { pendingTextAt = now }
    let frame = label.convert(label.bounds, to: nil)
    if pendingFrameAt == nil, frame != pendingFrame0 { pendingFrameAt = now }
    if let textAt = pendingTextAt, let frameAt = pendingFrameAt {
      pendingTapStart = nil
      lastLabelText = text
      taps.append((max(textAt, frameAt) - t0) * 1000)
      tapDetails.append(String(format: "text+%.2f frame+%.2f turns=%d",
                               (textAt - t0) * 1000, (frameAt - t0) * 1000, pendingTurns))
      if tapsRemaining > 0 {
        // Randomized trigger phase: a fixed cadence (0.9s = an exact
        // multiple of the frame period) can phase-lock the trigger to the
        // framework's render tick and read a constant, unrepresentative
        // latency. Jitter spreads triggers across the tick period.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 + Double.random(in: 0...0.1)) { self.tap() }
      } else {
        DispatchQueue.main.async { self.finish() }
      }
    }
  }

  private func tap() {
    guard let window = keyWindow(), let button = findButton(in: window) else {
      NSLog("[bench] no button to tap"); finish(); return
    }
    tapsRemaining -= 1
    let label = findLabelView(in: window)
    lastLabelText = label?.accessibilityLabel ?? ""
    pendingFrame0 = label.map { $0.convert($0.bounds, to: nil) } ?? .zero
    pendingTextAt = nil
    pendingFrameAt = nil
    pendingTurns = 0
    pendingTapStart = CACurrentMediaTime()
    let token = pendingTapStart
    if !button.accessibilityActivate() {
      NSLog("[bench] accessibilityActivate not handled")
      pendingTapStart = nil
      finish()
      return
    }
    // Watchdog: a lost update must not stall the run — skip THIS tap (token
    // check: only the window it armed) and move on.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
      if pendingTapStart == token {
        pendingTapStart = nil
        tapDetails.append("MISSED (watchdog)")
        if tapsRemaining > 0 { tap() } else { finish() }
      }
    }
  }

  private func finish() {
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    let sorted = taps.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let mean = taps.isEmpty ? 0 : taps.reduce(0, +) / Double(taps.count)
    let payload: [String: Any] = [
      "run": ProcessInfo.processInfo.environment["UUI_BENCH_RUN"] ?? "",
      "startupMs": startupMs ?? -1,
      "launchToContentMs": launchToContentMs ?? -1,
      "taps": taps.map { (($0 * 10).rounded()) / 10 },
      "tapMedianMs": ((median * 10).rounded()) / 10,
      "tapMeanMs": ((mean * 10).rounded()) / 10,
      "tapDetails": tapDetails,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
       let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      try? data.write(to: dir.appendingPathComponent("bench.json"))
      NSLog("[bench] done: %@", String(data: data, encoding: .utf8) ?? "")
    }
  }

  // MARK: hierarchy probes (Fabric mounts real UIViews; Text exposes its
  // string as accessibilityLabel, the Pressable is the #5A57D6 view)

  private func keyWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      if let windowScene = scene as? UIWindowScene,
         let key = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
        return key
      }
    }
    return nil
  }

  private func findLabelView(in view: UIView) -> UIView? {
    if let text = view.accessibilityLabel, text.hasPrefix("Tapped ") { return view }
    for sub in view.subviews {
      if let found = findLabelView(in: sub) { return found }
    }
    return nil
  }

  private func findButton(in view: UIView) -> UIView? {
    if let bg = view.backgroundColor {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      if bg.getRed(&r, green: &g, blue: &b, alpha: &a),
         abs(r - 90.0 / 255) < 0.1, abs(g - 87.0 / 255) < 0.1, b > 0.7, a > 0.9 {
        return view
      }
    }
    for sub in view.subviews {
      if let found = findButton(in: sub) { return found }
    }
    return nil
  }

  // Process start (includes dyld / pre-main, mirroring Android's
  // ActivityManager START anchor and the UUI cells).
  private static func msSinceProcessStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard rc == 0 else { return -1 }
    let start = info.kp_proc.p_starttime
    let startSec = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    return (Date().timeIntervalSince1970 - startSec) * 1000
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func bundleURL() -> URL? {
    #if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
    #else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
    #endif
  }
}
