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
import os.signpost

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
      initialProperties: [
        // The "real world" bench mode: UUI_BUSY=1 starts a synthetic JS-thread
        // load the taps must compete with (see App.tsx).
        "busy": ProcessInfo.processInfo.environment["UUI_BUSY"] == "1"
      ],
      launchOptions: launchOptions
    )

    RNBenchHarness.installIfRequested()
    RNBenchHarness.installSignpostIfRequested()

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
// UNIFORM METHODOLOGY (identical to the universal_ui cells' harness):
// Startup = PROCESS INIT (sysctl p_starttime, dyld included) → the end of
// the CA commit that first contains BOTH the counter label and the button —
// laid out and handed off to the render server. Tap = trigger receipt → the
// end of the CA commit containing the COMPLETE update (both the label text
// AND its frame changed — the count string changes width, so layout is part
// of the update). Two runloop observers: order 0 detects the mounted view
// state ahead of Core Animation's commit observer (order 2,000,000); order
// 2,500,000 stamps AFTER that same pass's commit — views re-laid-out and
// SUBMITTED for drawing, the point where it leaves the app's hands. No
// frame-timing anchors (no display link, no CATransaction completion — that
// waits on the render server's frame-paced processing). RN's own internal
// scheduling (main→JS→main hops, Fabric mount ticks) is counted; nothing
// after the commit handoff is. Trigger phase is randomized to avoid
// phase-locking to the render tick. The trigger is
// UIView.accessibilityActivate() on the Pressable, which Fabric maps to the
// JS onAccessibilityTap prop — the same native→JS→setState→shadow-tree→mount
// round trip a real touch performs.
@MainActor
final class RNBenchHarness: NSObject {
  static var shared: RNBenchHarness?

  // Signpost mode (the XCUITest interaction benchmark): REAL touches drive
  // the app; an os_signpost interval "tap" (dev.universalui.bench /
  // Interaction) opens at UIEvent receipt (UIWindow.sendEvent swizzle) and
  // closes at the commit that ships the detected label update - the same
  // interval the first-party cells emit, read by XCTOSSignpostMetric.
  static let signpostLog = OSLog(subsystem: "dev.universalui.bench", category: "Interaction")
  private var signpostMode = false
  private var signpostID: OSSignpostID?

  static func installSignpostIfRequested() {
    guard ProcessInfo.processInfo.environment["UUI_BENCH_SIGNPOST"] == "1"
      || ProcessInfo.processInfo.arguments.contains("-bench-signpost") else { return }
    let harness = RNBenchHarness()
    shared = harness
    harness.signpostMode = true
    harness.startupMs = -1  // skip the startup/auto-tap flow; detection only
    harness.start()
    RNTouchProbeWindow.swizzleSendEvent()
    NSLog("[bench] RN interaction signpost armed")
  }

  /// Real-touch receipt (touch .ended anywhere): arm detection + open the
  /// signpost. The detection window then behaves exactly like tap().
  func realTouchEnded() {
    guard signpostMode, let window = keyWindow() else { return }
    let label = findLabelView(in: window)
    lastLabelText = label?.accessibilityLabel ?? ""
    pendingFrame0 = label.map { $0.convert($0.bounds, to: nil) } ?? .zero
    pendingTextAt = nil
    pendingFrameAt = nil
    pendingTurns = 0
    if let open = signpostID {
      os_signpost(.end, log: Self.signpostLog, name: "tap", signpostID: open)
    }
    let id = OSSignpostID(log: Self.signpostLog)
    signpostID = id
    os_signpost(.begin, log: Self.signpostLog, name: "tap", signpostID: id)
    pendingTapStart = CACurrentMediaTime()
  }

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
  private var postCommitObserver: CFRunLoopObserver?
  private var contentDetected = false
  private var updateDetectedFor: CFTimeInterval?

  private func start() {
    // Order 0: detection, before CA's commit observer (2_000_000) in the
    // same before-waiting pass — the mutated view state it sees is exactly
    // what that pass's commit will ship.
    observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.runLoopTick() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    // Order 2,500,000: after CA's synchronous commit in the same pass — the
    // frame has been handed off when this fires.
    postCommitObserver = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_500_000
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.afterCommit() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), postCommitObserver, .commonModes)
  }

  private func afterCommit() {
    if contentDetected, startupMs == nil {
      startupMs = Self.msSinceProcessStart()
      launchToContentMs = (CACurrentMediaTime() - launchedAt) * 1000
      NSLog("[bench] content commit: startup=%.1fms launch->content=%.1fms",
            startupMs ?? -1, launchToContentMs ?? -1)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.tap() }
      return
    }
    guard let t0 = updateDetectedFor else { return }
    updateDetectedFor = nil
    if signpostMode {
      if let id = signpostID {
        os_signpost(.end, log: Self.signpostLog, name: "tap", signpostID: id)
        signpostID = nil
      }
      return
    }
    taps.append((CACurrentMediaTime() - t0) * 1000)
    if tapsRemaining > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double.random(in: 0...0.05)) { self.tap() }
    } else {
      DispatchQueue.main.async { self.finish() }
    }
  }

  private func runLoopTick() {
    guard let window = keyWindow() else { return }
    if startupMs == nil {
      guard !contentDetected else { return }
      guard findLabelView(in: window) != nil, findButton(in: window) != nil else { return }
      // Mounted view state contains the content; this pass's commit ships
      // it — the post-commit observer stamps startup.
      contentDetected = true
      return
    }
    guard let t0 = pendingTapStart, let label = findLabelView(in: window) else { return }
    // The pending window closes only when BOTH the label text and its frame
    // have changed — the frame growth ("Tapped 9" → "Tapped 10") is part of
    // the update; a text-only anchor could credit a render whose layout
    // hasn't landed. The post-commit observer stamps at the end of THIS
    // pass's commit.
    pendingTurns += 1
    let text = label.accessibilityLabel ?? ""
    if pendingTextAt == nil, text != lastLabelText { pendingTextAt = CACurrentMediaTime() }
    let frame = label.convert(label.bounds, to: nil)
    if pendingFrameAt == nil, frame != pendingFrame0 { pendingFrameAt = CACurrentMediaTime() }
    if pendingTextAt != nil, pendingFrameAt != nil {
      pendingTapStart = nil
      lastLabelText = text
      tapDetails.append(String(format: "turns=%d", pendingTurns))
      updateDetectedFor = t0
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
      if pendingTapStart == token {
        pendingTapStart = nil
        tapDetails.append("MISSED (watchdog)")
        if tapsRemaining > 0 { tap() } else { finish() }
      }
    }
  }

  private func finish() {
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    if let postCommitObserver {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), postCommitObserver, .commonModes)
    }
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


/// Bench-only UIWindow sendEvent hook: notifies the harness of every touch
/// .ended so real XCUITest taps open the signpost interval at UIEvent
/// receipt. Swizzled only in signpost mode.
private var rnSendEventSwizzled = false
enum RNTouchProbeWindow {
  static func swizzleSendEvent() {
    guard !rnSendEventSwizzled else { return }
    rnSendEventSwizzled = true
    guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
          let hook = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.rnbench_sendEvent(_:)))
    else { return }
    method_exchangeImplementations(original, hook)
  }
}

extension UIWindow {
  @objc func rnbench_sendEvent(_ event: UIEvent) {
    if event.type == .touches,
       let touches = event.allTouches,
       touches.contains(where: { $0.phase == .ended }) {
      MainActor.assumeIsolated { RNBenchHarness.shared?.realTouchEnded() }
    }
    self.rnbench_sendEvent(event)  // swizzled: calls the original
  }
}
