# Tap Counter — cross-framework benchmark app

The minimal "Tap me" counter — React Native's cell of a cross-framework startup /
tap / app-size benchmark (the driving comparison and results live in the
`universal_ui` repo, `docs/benchmarks.md`). It is deliberately behavior-identical
to its native-Compose, compiled-Swift, wasm, and Valdi twins — a counter label +
a "Tap me" button, nothing else — so the numbers isolate runtime overhead (the RN
runtime + the Hermes JS engine) rather than app content.

`App.tsx` is the whole app; it logs `[rn-tap] count=N latency=Nms` to logcat on
each tap for latency correlation with the other cells.

It's a standalone RN app (its own Gradle root, copied from `private/helloworld`)
that consumes React Native + Hermes **from the monorepo source** rather than an
installed `node_modules`.

## Building the Android APK

1. Publish the in-repo React Native + Hermes to the local Maven repo (reuses the
   cached ReactAndroid/Hermes build):

   ```sh
   cd <repo-root>
   ./gradlew publishAllToMavenTempLocal -PreactNativeArchitectures=arm64-v8a
   ```

   This is already wired up: `android/gradle.properties` here points at it via
   `react.internal.mavenLocalRepo=/tmp/maven-local`.

2. Build (JDK 17 + Android SDK/NDK; `node_modules` is empty here, so
   `app/build.gradle` points `reactNativeDir`/`codegenDir`/`hermesCommand` at the
   monorepo):

   ```sh
   export JAVA_HOME=/opt/homebrew/opt/openjdk@17      # any JDK 17
   export ANDROID_HOME=$HOME/Android/sdk
   cd private/tap-counter/android
   echo "sdk.dir=$ANDROID_HOME" > local.properties
   ./gradlew :app:assembleRelease -PreactNativeArchitectures=arm64-v8a
   ```

Install + launch:

```sh
adb install -r -d app/build/outputs/apk/release/app-release.apk
adb shell am start -n com.tapcounter/.MainActivity
```

Verified on a Pixel 3a: Hermes loads (`libhermesvm.so`), `Running "TapCounter"`,
cold start ~341 ms, tap→update ~17–25 ms, APK ~18.3 MB (arm64).
