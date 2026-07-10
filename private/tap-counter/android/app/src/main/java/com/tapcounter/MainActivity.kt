/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.tapcounter

import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // Benchmark instrumentation: the uniform [content-frame] startup signal —
    // the first UI-toolkit draw pass in which the JS-mounted content views
    // exist (label + button under the ReactRootView), i.e. the frame that
    // actually renders the counter, not the empty host shell and not a
    // JS-side commit log. Mirrors the other cells' ContentFrame helper.
    val decor = window.decorView
    val content = findViewById<ViewGroup>(android.R.id.content)
    // LITERAL content check (not a view-count heuristic): the draw pass must
    // contain a mounted TextView whose text IS the counter label — proof the
    // frame renders the JS-produced content, not a placeholder shell.
    fun hasCounterText(v: View): Boolean {
      if (v is android.widget.TextView && v.text?.startsWith("Tapped") == true) return true
      if (v is ViewGroup) {
        for (i in 0 until v.childCount) {
          if (hasCounterText(v.getChildAt(i))) return true
        }
      }
      return false
    }
    val listener = object : ViewTreeObserver.OnDrawListener {
      private var logged = false
      override fun onDraw() {
        if (logged || !hasCounterText(content)) return
        logged = true
        android.util.Log.i("UniversalUI", "[content-frame]")
        decor.post { decor.viewTreeObserver.removeOnDrawListener(this) }
      }
    }
    decor.viewTreeObserver.addOnDrawListener(listener)
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
      DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)
}
