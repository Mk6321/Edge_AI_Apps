import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wake_word_config.dart';
import 'wake_word_constants.dart';

const AndroidNotificationChannel _serviceChannel = AndroidNotificationChannel(
  'smart_glass_foreground',
  'Smart Glass Assistant',
  description: 'Wake word listening and assistive status updates.',
  importance: Importance.low,
);

Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  final notifications = FlutterLocalNotificationsPlugin();

  await notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(_serviceChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      autoStartOnBoot: false,
      isForegroundMode: true,
      notificationChannelId: _serviceChannel.id,
      initialNotificationTitle: 'Smart Glass Assistant',
      initialNotificationContent: 'Preparing wake word listener...',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.microphone],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );

  service.startService();
}

Future<void> pauseWakeWordDetection() async {
  FlutterBackgroundService().invoke(pauseWakeWordEvent);
}

Future<void> resumeWakeWordDetection() async {
  FlutterBackgroundService().invoke(resumeWakeWordEvent);
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  PorcupineManager? wakeWordManager;
  bool isWakeWordRunning = false;
  bool isWakeWordSuspended = false;
  Timer? pendingWakeResetTimer;
  late final Future<void> Function() handleWakeWordDetected;
  late final Future<void> Function() startWakeWord;

  Future<void> updateNotification(String content) async {
    if (service is! AndroidServiceInstance) {
      return;
    }

    if (await service.isForegroundService()) {
      await service.setForegroundNotificationInfo(
        title: 'Smart Glass Assistant',
        content: content,
      );
    }
  }

  void emitWakeWordStatus({
    required bool ready,
    required bool running,
    required bool suspended,
    String? message,
  }) {
    service.invoke(wakeWordStatusEvent, {
      'ready': ready,
      'running': running,
      'suspended': suspended,
      'message': message,
    });
  }

  Future<void> clearPendingWakeWord() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pendingWakeWordKey);
    await prefs.remove(pendingWakeWordAtKey);
  }

  Future<void> stopWakeWord({String? notification}) async {
    if (!isWakeWordRunning) {
      if (notification != null) {
        await updateNotification(notification);
      }
      return;
    }

    try {
      await wakeWordManager?.stop();
    } on PorcupineException catch (error) {
      emitWakeWordStatus(
        ready: WakeWordConfig.hasAccessKey,
        running: false,
        suspended: isWakeWordSuspended,
        message: error.message,
      );
    }

    isWakeWordRunning = false;
    emitWakeWordStatus(
      ready: WakeWordConfig.hasAccessKey,
      running: false,
      suspended: isWakeWordSuspended,
      message: notification,
    );

    if (notification != null) {
      await updateNotification(notification);
    }
  }

  handleWakeWordDetected = () async {
    if (isWakeWordSuspended) {
      return;
    }

    isWakeWordSuspended = true;
    await stopWakeWord(notification: 'Wake word detected. Opening app...');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(pendingWakeWordKey, true);
    await prefs.setInt(
      pendingWakeWordAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );

    bool opened = false;
    if (service is AndroidServiceInstance) {
      opened = await service.openApp();
    }

    service.invoke(wakeWordDetectedEvent, {
      'phrase': WakeWordConfig.hasCustomKeyword
          ? WakeWordConfig.preferredWakePhrase
          : WakeWordConfig.fallbackWakePhrase,
      'opened': opened,
    });

    await updateNotification(
      opened
          ? 'Wake word detected. Switching to listening mode...'
          : 'Wake word detected. Open the app to speak.',
    );

    pendingWakeResetTimer?.cancel();
    pendingWakeResetTimer = Timer(const Duration(seconds: 15), () async {
      final pendingPrefs = await SharedPreferences.getInstance();
      final isPending = pendingPrefs.getBool(pendingWakeWordKey) ?? false;
      if (!isPending) {
        return;
      }

      isWakeWordSuspended = false;
      await clearPendingWakeWord();
      await startWakeWord();
    });
  };

  Future<void> ensureWakeWordManager() async {
    if (wakeWordManager != null) {
      return;
    }

    final sensitivities = [WakeWordConfig.sensitivity];
    if (WakeWordConfig.hasCustomKeyword) {
      wakeWordManager = await PorcupineManager.fromKeywordPaths(
        WakeWordConfig.accessKey,
        [WakeWordConfig.customKeywordAssetPath],
        (_) => unawaited(handleWakeWordDetected()),
        sensitivities: sensitivities,
        errorCallback: (error) {
          emitWakeWordStatus(
            ready: true,
            running: false,
            suspended: isWakeWordSuspended,
            message: error.message,
          );
        },
      );
      return;
    }

    wakeWordManager = await PorcupineManager.fromBuiltInKeywords(
      WakeWordConfig.accessKey,
      [BuiltInKeyword.JARVIS],
      (_) => unawaited(handleWakeWordDetected()),
      sensitivities: sensitivities,
      errorCallback: (error) {
        emitWakeWordStatus(
          ready: true,
          running: false,
          suspended: isWakeWordSuspended,
          message: error.message,
        );
      },
    );
  }

  startWakeWord = () async {
    if (isWakeWordSuspended || isWakeWordRunning) {
      return;
    }

    if (!WakeWordConfig.hasAccessKey) {
      const message = 'Wake word disabled. Add PICOVOICE_ACCESS_KEY.';
      emitWakeWordStatus(
        ready: false,
        running: false,
        suspended: false,
        message: message,
      );
      await updateNotification(message);
      return;
    }

    try {
      await ensureWakeWordManager();
      await wakeWordManager!.start();
      isWakeWordRunning = true;

      final phrase = WakeWordConfig.hasCustomKeyword
          ? WakeWordConfig.preferredWakePhrase
          : WakeWordConfig.fallbackWakePhrase;
      final message = 'Listening for "$phrase".';

      emitWakeWordStatus(
        ready: true,
        running: true,
        suspended: false,
        message: message,
      );
      await updateNotification(message);
    } on PorcupineException catch (error) {
      emitWakeWordStatus(
        ready: true,
        running: false,
        suspended: false,
        message: error.message,
      );
      await updateNotification('Wake word error: ${error.message}');
    } catch (error) {
      emitWakeWordStatus(
        ready: true,
        running: false,
        suspended: false,
        message: error.toString(),
      );
      await updateNotification('Wake word error: $error');
    }
  };

  service.on(pauseWakeWordEvent).listen((_) async {
    pendingWakeResetTimer?.cancel();
    isWakeWordSuspended = true;
    await clearPendingWakeWord();
    await stopWakeWord(notification: 'Wake word paused.');
  });

  service.on(resumeWakeWordEvent).listen((_) async {
    pendingWakeResetTimer?.cancel();
    isWakeWordSuspended = false;
    await clearPendingWakeWord();
    await startWakeWord();
  });

  service.on('stopService').listen((_) async {
    pendingWakeResetTimer?.cancel();
    await stopWakeWord(notification: 'Stopping wake word service...');
    await wakeWordManager?.delete();
    wakeWordManager = null;
    await service.stopSelf();
  });

  await startWakeWord();
}
