import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/screensaver/screensaver_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late ScreensaverManager saver;
  late List<Map<String, Object?>> offCalls;
  late int onCalls;
  late bool panelOn;
  late bool allowPowerOff;
  Completer<void>? pendingPowerOff;

  Future<void> build({
    double? lux = 2,
    bool sensor = true,
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.enabled': true,
      'ks.screensaver.timeout_seconds': 0,
      'ks.screensaver.mode': 'clock',
      'ks.screensaver.clock_night': true,
      'ks.screensaver.clock_night_screen_off': true,
      ...prefs,
    });
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    offCalls = [];
    onCalls = 0;
    panelOn = true;
    allowPowerOff = true;
    pendingPowerOff = null;
    commands
      ..register(
        Command(
          name: 'getLightLevel',
          description: 'sensor',
          handler: (_) async =>
              CommandResult.ok({'present': sensor, 'lux': lux}),
        ),
      )
      ..register(
        Command(
          name: 'isScreenOn',
          description: 'panel',
          handler: (_) async => CommandResult.ok(panelOn),
        ),
      )
      ..register(
        Command(
          name: 'screenOff',
          description: 'power off',
          handler: (p) async {
            offCalls.add(p);
            if (!allowPowerOff) return const CommandResult.fail('permission');
            await pendingPowerOff?.future;
            panelOn = false;
            bus.publish(const ScreenStateChanged(on: false, source: 'app'));
            return const CommandResult.ok();
          },
        ),
      )
      ..register(
        Command(
          name: 'screenOn',
          description: 'wake',
          handler: (_) async {
            onCalls++;
            panelOn = true;
            bus.publish(const ScreenStateChanged(on: true, source: 'app'));
            return const CommandResult.ok();
          },
        ),
      );
    saver = ScreensaverManager(
      bus,
      commands,
      log,
      settings,
      nightScreenOffDelay: const Duration(milliseconds: 100),
      screenOffUnit: const Duration(milliseconds: 10),
    );
    await saver.init();
  }

  void nightTest(String name, Future<void> Function(_TestTime) body) {
    test(name, () async {
      final tester = _TestTime();
      try {
        await body(tester);
      } finally {
        await saver.dispose();
        await bus.dispose();
      }
    });
  }

  Future<void> light(_TestTime tester, double lux) async {
    bus.publish(LightLevelChanged(lux: lux));
    await tester.pump();
  }

  Future<void> wait(_TestTime tester) =>
      tester.pump(const Duration(milliseconds: 110));

  nightTest('darkness powers off quietly without ending the clock session', (
    tester,
  ) async {
    await build();
    await saver.start();
    await tester.pump(const Duration(milliseconds: 40));
    expect(offCalls, isEmpty);
    await wait(tester);
    expect(offCalls, hasLength(1));
    expect(offCalls.single['prompt'], isFalse);
    expect(panelOn, isFalse);
    expect(saver.isActive, isTrue);
    expect(saver.activeView.value, 'clock');
    await light(tester, 1);
    await wait(tester);
    expect(offCalls, hasLength(1));
  });

  nightTest('daylight restores only the panel owned by Night mode', (
    tester,
  ) async {
    await build();
    await saver.start();
    await wait(tester);
    await light(tester, 6);
    expect(panelOn, isFalse, reason: 'the hysteresis band still holds');
    await light(tester, 6.3);
    expect(panelOn, isTrue);
    expect(saver.isActive, isTrue);
    expect(onCalls, 1);
    await light(tester, 7);
    expect(onCalls, 1);

    panelOn = false;
    bus.publish(const ScreenStateChanged(on: false));
    await light(tester, 2);
    await light(tester, 20);
    expect(panelOn, isFalse, reason: 'manual power-off belongs to the user');
  });

  nightTest('touch dismisses and does not cut off the dashboard again', (
    tester,
  ) async {
    await build();
    await saver.start();
    await wait(tester);
    saver.notifyActivity('touch');
    await tester.pump();
    expect(panelOn, isTrue);
    expect(saver.isActive, isFalse);
    await light(tester, 1);
    await wait(tester);
    expect(offCalls, hasLength(1));
    await saver.start();
    await wait(tester);
    expect(offCalls, hasLength(2), reason: 'the next idle session powers off');
  });

  nightTest('a wake that keeps the clock gets a fresh viewing period', (
    tester,
  ) async {
    await build();
    await saver.start();
    await wait(tester);
    await commands.execute('screenOn', const {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(panelOn, isTrue);
    await wait(tester);
    expect(offCalls, hasLength(2));
  });

  nightTest('a bright reading cancels a pending dark-room countdown', (
    tester,
  ) async {
    await build();
    await saver.start();
    await tester.pump(const Duration(milliseconds: 50));
    await light(tester, 20);
    await wait(tester);
    expect(offCalls, isEmpty);
  });

  for (final prefs in [
    {'ks.screensaver.clock_night_screen_off': false},
    {'ks.screensaver.clock_night': false},
    {'ks.screensaver.mode': 'black'},
  ]) {
    nightTest('does not power off with $prefs', (tester) async {
      await build(prefs: prefs);
      await saver.start();
      await wait(tester);
      expect(offCalls, isEmpty);
    });
  }

  for (final lux in [null, double.nan, double.infinity, -1.0]) {
    nightTest('an invalid or absent light reading ($lux) is not darkness', (
      tester,
    ) async {
      await build(lux: lux);
      await saver.start();
      await wait(tester);
      expect(offCalls, isEmpty);
    });
  }

  nightTest('no physical sensor means no night power-off', (tester) async {
    await build(sensor: false);
    await saver.start();
    await wait(tester);
    expect(offCalls, isEmpty);
  });

  nightTest('settings apply live and releasing the option wakes its panel', (
    tester,
  ) async {
    await build();
    await saver.start();
    await wait(tester);
    await settings.set(defs.screensaverClockNightScreenOff, false);
    await tester.pump();
    expect(panelOn, isTrue);
    await settings.set(defs.screensaverClockNightScreenOff, true);
    await tester.pump();
    await wait(tester);
    expect(panelOn, isFalse);
    await settings.set(defs.screensaverClockNightLux, 1);
    await tester.pump();
    expect(panelOn, isTrue);
  });

  nightTest('voice overlay holds the countdown and restarts it afterward', (
    tester,
  ) async {
    await build();
    await saver.start();
    bus.publish(const AssistOverlayVisibility(true));
    await tester.pump();
    await wait(tester);
    expect(offCalls, isEmpty);
    bus.publish(const AssistOverlayVisibility(false));
    await tester.pump();
    await wait(tester);
    expect(offCalls, hasLength(1));
  });

  nightTest('an alarm holds the display until its takeover ends', (
    tester,
  ) async {
    await build();
    await saver.start();
    await commands.execute('alarmTakeover', const {'phase': 'ringing'});
    await wait(tester);
    expect(offCalls, isEmpty);
    await commands.execute('alarmTakeover', const {'phase': null});
    await wait(tester);
    expect(offCalls, hasLength(1));
  });

  nightTest('permission failure never prompts and does not claim ownership', (
    tester,
  ) async {
    await build();
    allowPowerOff = false;
    await saver.start();
    await wait(tester);
    expect(offCalls.single['prompt'], isFalse);
    await light(tester, 20);
    expect(onCalls, 0);
  });

  nightTest('daylight cannot undo the ordinary screen-off timer', (
    tester,
  ) async {
    await build(prefs: {'ks.screensaver.screen_off_minutes': 1});
    await saver.start();
    await tester.pump(const Duration(milliseconds: 20));
    expect(panelOn, isFalse);
    await light(tester, 20);
    expect(onCalls, 0);
  });

  nightTest(
    'dismissing while Android powers off cannot leave the dashboard dark',
    (tester) async {
      await build();
      pendingPowerOff = Completer<void>();
      await saver.start();
      await wait(tester);
      expect(offCalls, hasLength(1));
      await saver.stop();
      pendingPowerOff!.complete();
      await tester.pump();
      expect(panelOn, isTrue);
      expect(saver.isActive, isFalse);
    },
  );
}

// These are manager tests, not widget tests: use the real asynchronous bus
// and short injectable timers, as the existing screen-off tests do.
class _TestTime {
  Future<void> pump([Duration? elapsed]) async {
    if (elapsed != null) await Future<void>.delayed(elapsed);
    await pumpEventQueue();
  }
}
