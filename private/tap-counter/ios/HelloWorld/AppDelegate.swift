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
// completion of the CA commit that first contains BOTH the counter label and
// the button — detected by a main-runloop observer (order 0, ahead of Core
// Animation's commit observer at 2_000_000) scanning the mounted hierarchy,
// so the CATransaction completion attaches to exactly that commit. Matches
// the UUI cells' commit-anchored semantics.
//
// Tap anchor: trigger → completion of the commit containing the label update.
// The trigger is UIView.accessibilityActivate() on the Pressable, which
// Fabric maps to the JS onAccessibilityTap prop — the same native→JS→
// setState→shadow-tree→mount round trip a real touch performs.
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
      guard let label = findLabel(in: window), findButton(in: window) != nil else { return }
      lastLabelText = label
      CATransaction.setCompletionBlock { [self] in
        startupMs = Self.msSinceProcessStart()
        launchToContentMs = (CACurrentMediaTime() - launchedAt) * 1000
        NSLog("[bench] content frame: startup=%.1fms launch->content=%.1fms",
              startupMs ?? -1, launchToContentMs ?? -1)
        // Settle, then drive the taps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.tap() }
      }
      return
    }
    if let t0 = pendingTapStart, let label = findLabel(in: window), label != lastLabelText {
      lastLabelText = label
      pendingTapStart = nil
      CATransaction.setCompletionBlock { [self] in
        taps.append((CACurrentMediaTime() - t0) * 1000)
        if tapsRemaining > 0 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.tap() }
        } else {
          finish()
        }
      }
    }
  }

  private func tap() {
    guard let window = keyWindow(), let button = findButton(in: window) else {
      NSLog("[bench] no button to tap"); finish(); return
    }
    tapsRemaining -= 1
    pendingTapStart = CACurrentMediaTime()
    if !button.accessibilityActivate() {
      NSLog("[bench] accessibilityActivate not handled")
      pendingTapStart = nil
      finish()
      return
    }
    // Watchdog: a lost update must not stall the run.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
      if pendingTapStart != nil { pendingTapStart = nil; finish() }
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

  private func findLabel(in view: UIView) -> String? {
    if let text = view.accessibilityLabel, text.hasPrefix("Tapped ") { return text }
    for sub in view.subviews {
      if let found = findLabel(in: sub) { return found }
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
