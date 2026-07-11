/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.tapcounter

import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {

  // Tap-latency instrumentation (native, content-anchored). tapReceiptNs is
  // stamped when the app receives the tap's ACTION_UP (the event that fires the
  // click); the OnPreDrawListener stamps the pre-draw pass that first carries
  // the NEW counter text ("re-laid-out and sent for drawing"). The difference
  // is the true receipt->content latency and — crucially — it SPANS the async
  // JS round trip (UI thread -> JS thread -> setState -> Fabric mount), which
  // the gfxinfo framestats mount-frame anchor misses entirely (that frame's
  // internal phases don't include the JS hop that precedes it, so it's blind to
  // JS-thread contention). logcat: [native-tap] latency_us=<n>.
  @Volatile private var tapReceiptNs = 0L
  private var lastCounter: String? = null

  override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
    if (ev.actionMasked == MotionEvent.ACTION_UP) tapReceiptNs = System.nanoTime()
    return super.dispatchTouchEvent(ev)
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val decor = window.decorView
    val content = findViewById<ViewGroup>(android.R.id.content)
    // The mounted counter label's current string ("Tapped N time(s)"), or null
    // if the JS content isn't mounted yet. A literal content check, not a
    // view-count heuristic — proof the frame renders the JS-produced content.
    fun counterText(v: View): String? {
      if (v is android.widget.TextView && v.text?.startsWith("Tapped") == true) return v.text.toString()
      if (v is ViewGroup) {
        for (i in 0 until v.childCount) {
          val r = counterText(v.getChildAt(i))
          if (r != null) return r
        }
      }
      return null
    }
    // Startup signal [content-frame]: the first draw pass in which the counter
    // label + button exist (the frame that renders the counter, not the empty
    // host shell and not a JS-side commit log). Mirrors the other cells.
    val startupListener = object : ViewTreeObserver.OnDrawListener {
      private var logged = false
      override fun onDraw() {
        if (logged || counterText(content) == null) return
        logged = true
        android.util.Log.i("UniversalUI", "[content-frame]")
        decor.post { decor.viewTreeObserver.removeOnDrawListener(this) }
      }
    }
    decor.viewTreeObserver.addOnDrawListener(startupListener)
    // Tap signal [native-tap]: the pre-draw pass that first shows a NEW count
    // string. The first sighting (startup "Tapped 0 times") only seeds
    // lastCounter; every later change is tap-driven, so we log receipt->here.
    content.viewTreeObserver.addOnPreDrawListener {
      val cur = counterText(content)
      if (cur != null && cur != lastCounter) {
        val r = tapReceiptNs
        if (lastCounter != null && r != 0L) {
          android.util.Log.i("UniversalUI", "[native-tap] latency_us=${(System.nanoTime() - r) / 1000}")
          tapReceiptNs = 0L
        }
        lastCounter = cur
      }
      true
    }
  }

  /**
   * Returns the name of the main component registered from JavaScript. This is used to schedule
   * rendering of the component.
   */
  override fun getMainComponentName(): String = "TapCounter"

  /**
   * Returns the instance of the [ReactActivityDelegate]. We use [DefaultReactActivityDelegate]
   * which allows you to enable New Architecture with a single boolean flags [fabricEnabled]
   */
  override fun createReactActivityDelegate(): ReactActivityDelegate =
      object : DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled) {
        // The "real world" bench mode: `--ez busy true` starts a synthetic
        // JS-thread load the taps must compete with (see App.tsx).
        override fun getLaunchOptions(): Bundle =
            Bundle().apply { putBoolean("busy", intent?.getBooleanExtra("busy", false) ?: false) }
      }
}
