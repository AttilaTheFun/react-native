/**
 * The minimal "Tap me" counter — React Native's cell of a cross-framework
 * startup / tap / app-size benchmark (results live in the universal_ui repo).
 * Behavior-identical to its native-Compose, compiled-Swift, wasm, and Valdi
 * twins: one label + one button, nothing else, so the numbers isolate runtime
 * overhead (the RN native runtime + the Hermes JS engine) rather than app content.
 *
 * @format
 */

import * as React from 'react';
import {useState} from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';

function App(): React.ReactNode {
  const [count, setCount] = useState(0);

  // Startup content signal: fires after the first commit (native views
  // mounted); the frame presenting them follows within a vsync. Lets the
  // benchmark verify "Displayed" against actual JS-rendered content
  // (logcat: [rn-content]).
  React.useEffect(() => {
    requestAnimationFrame(() => console.log('[rn-content] first frame'));
  }, []);

  // Stamp on press, log after the next frame commits — mirrors the [native-tap]/
  // [wamr-event]/[valdi-tap] latency logs the other cells emit, so tap->update is
  // measured the same way everywhere (logcat: [rn-tap]).
  const onPress = () => {
    const t0 = Date.now();
    setCount(c => {
      requestAnimationFrame(() => {
        console.log(`[rn-tap] count=${c + 1} latency=${Date.now() - t0}ms`);
      });
      return c + 1;
    });
  };

  return (
    <View style={styles.root}>
      <Text style={styles.label}>
        Tapped {count} time{count === 1 ? '' : 's'}
      </Text>
      {/* onAccessibilityTap lets the iOS bench harness drive the SAME
          native→JS→setState→mount round trip a touch performs, via
          UIView.accessibilityActivate() (Fabric maps it to this prop). */}
      <Pressable style={styles.button} onPress={onPress} onAccessibilityTap={onPress}>
        <Text style={styles.buttonText}>Tap me</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'white',
  },
  label: {
    fontSize: 20,
    color: '#888888',
    marginBottom: 24,
  },
  button: {
    backgroundColor: '#5A57D6',
    paddingHorizontal: 28,
    paddingVertical: 12,
    borderRadius: 10,
  },
  buttonText: {
    fontSize: 17,
    fontWeight: '600',
    color: 'white',
  },
});

export default App;
