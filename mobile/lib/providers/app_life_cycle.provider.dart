import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/permission.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:logging/logging.dart';

enum AppLifeCycleEnum { active, inactive, paused, resumed, detached, hidden }

class AppLifeCycleNotifier extends StateNotifier<AppLifeCycleEnum> {
  final Ref _ref;
  bool _wasPaused = false;

  // Add operation coordination
  Completer<void>? _resumeOperation;
  Completer<void>? _pauseOperation;

  // Brief app-switcher glances (e.g. checking another app for a second) also fire a
  // pause/resume cycle. Cancelling the foreground backup immediately on every pause
  // discards any in-flight upload (uploads aren't resumable), forcing large assets
  // like videos to restart from byte zero on resume. Delay the cancellation so a
  // quick round-trip back to the app doesn't interrupt an upload in progress (#30503).
  static const _backupStopGracePeriod = Duration(seconds: 5);
  Timer? _pendingBackupStopTimer;

  final _log = Logger("AppLifeCycleNotifier");

  AppLifeCycleNotifier(this._ref) : super(AppLifeCycleEnum.active);

  AppLifeCycleEnum getAppState() {
    return state;
  }

  Future<void> handleAppResume() async {
    state = AppLifeCycleEnum.resumed;

    // We made it back before the grace period elapsed, so the foreground backup
    // (if any) was never actually stopped - nothing to resume.
    _cancelPendingBackupStop();

    // Prevent overlapping resume operations
    if (_resumeOperation != null && !_resumeOperation!.isCompleted) {
      await _resumeOperation!.future;
      return;
    }

    // Cancel any ongoing pause operation
    if (_pauseOperation != null && !_pauseOperation!.isCompleted) {
      _pauseOperation!.complete();
    }

    // Capture locally: an overlapping handleAppPause/handleAppResume call can complete and
    // then reassign or null the shared field while this call is still suspended on an await
    // below. Referencing _resumeOperation directly in finally risks a null-check crash or
    // clobbering a newer call's completer (#reentrancy bug found testing #30503's fix).
    final resumeOperation = Completer<void>();
    _resumeOperation = resumeOperation;

    try {
      await _performResume();
    } catch (e, stackTrace) {
      _log.severe("Error during app resume", e, stackTrace);
    } finally {
      if (!resumeOperation.isCompleted) {
        resumeOperation.complete();
      }
      if (identical(_resumeOperation, resumeOperation)) {
        _resumeOperation = null;
      }
    }
  }

  Future<void> _performResume() async {
    // no need to resume because app was never really paused
    if (!_wasPaused) {
      return;
    }
    _wasPaused = false;

    final isAuthenticated = _ref.read(authProvider).isAuthenticated;

    // Needs to be logged in
    if (isAuthenticated) {
      // switch endpoint if needed
      final endpoint = await _ref.read(authProvider.notifier).setOpenApiServiceEndpoint();
      _log.info("Using server URL: $endpoint");

      await _ref.read(serverInfoProvider.notifier).getServerVersion();
    }

    if (!_shouldContinueOperation()) {
      _wasPaused = true;
      return;
    }
    _ref.read(websocketProvider.notifier).connect();
    await _handleBetaTimelineResume();

    await _ref.read(notificationPermissionProvider.notifier).getNotificationPermission();

    await _ref.read(galleryPermissionNotifier.notifier).getGalleryPermissionStatus();
  }

  Future<void> _safeRun(Future<void> Function() action, String debugName) async {
    if (!_shouldContinueOperation()) {
      return;
    }

    try {
      await action();
    } catch (e, stackTrace) {
      _log.warning("Error during $debugName operation", e, stackTrace);
    }
  }

  Future<void> _handleBetaTimelineResume() async {
    unawaited(_ref.read(backgroundWorkerLockServiceProvider).lock());

    // Give isolates time to complete any ongoing database transactions
    await Future.delayed(const Duration(milliseconds: 500));

    final backgroundManager = _ref.read(backgroundSyncProvider);

    // Drop any sync that froze mid-flight while the app was suspended so resume
    // starts fresh instead of awaiting the stale task (#28082). cancelResumeSyncs
    // clears the task refs synchronously, so the syncs below see a clean slate.
    unawaited(backgroundManager.cancelResumeSyncs());

    final isAlbumLinkedSyncEnable = _ref.read(appConfigProvider).backup.syncAlbums;

    try {
      bool syncSuccess = false;
      await Future.wait([
        _safeRun(() => backgroundManager.syncLocal(full: CurrentPlatform.isAndroid), "syncLocal"),
        _safeRun(() async {
          syncSuccess = await backgroundManager.syncRemote();
        }, "syncRemote"),
      ]);
      _ref.invalidate(driftMemoryFutureProvider);
      if (syncSuccess) {
        await Future.wait([
          _safeRun(backgroundManager.hashAssets, "hashAssets").then((_) {
            unawaited(_resumeBackup());
          }),
          _resumeBackup(),
          // TODO: Bring back when the soft freeze issue is addressed
          // _safeRun(backgroundManager.syncCloudIds(), "syncCloudIds"),
        ]);
      } else {
        await _safeRun(backgroundManager.hashAssets, "hashAssets");
      }

      if (isAlbumLinkedSyncEnable) {
        await _safeRun(backgroundManager.syncLinkedAlbum, "syncLinkedAlbum");
      }
    } catch (e, stackTrace) {
      _log.severe("Error during background sync", e, stackTrace);
    }
  }

  Future<void> _resumeBackup() async {
    final isEnableBackup = _ref.read(appConfigProvider).backup.enabled;

    if (isEnableBackup) {
      final currentUser = Store.tryGet(StoreKey.currentUser);
      if (currentUser != null) {
        final backupNotifier = _ref.read(driftBackupProvider.notifier);

        // A pause/resume round-trip that completed within the grace period (see
        // _scheduleBackupStop) never actually stopped the foreground backup - it's
        // still running. Restarting it here would re-upload any in-flight asset
        // from scratch, so leave it alone.
        if (backupNotifier.isForegroundBackupActive) {
          return;
        }

        await _safeRun(() => backupNotifier.startForegroundBackup(currentUser.id), "handleBackupResume");
      }
    }
  }

  // Helper method to check if operations should continue
  bool _shouldContinueOperation() {
    return [AppLifeCycleEnum.resumed, AppLifeCycleEnum.active].contains(state) &&
        (_resumeOperation?.isCompleted == false || _resumeOperation == null);
  }

  void handleAppInactivity() {
    state = AppLifeCycleEnum.inactive;
    // do not stop/clean up anything on inactivity: issued on every orientation change
  }

  Future<void> handleAppPause() async {
    state = AppLifeCycleEnum.paused;
    _wasPaused = true;

    // Prevent overlapping pause operations
    if (_pauseOperation != null && !_pauseOperation!.isCompleted) {
      await _pauseOperation!.future;
      return;
    }

    // Cancel any ongoing resume operation
    if (_resumeOperation != null && !_resumeOperation!.isCompleted) {
      _resumeOperation!.complete();
    }

    // See the matching comment in handleAppResume: capture locally so an overlapping call
    // can't null-check-crash or clobber a newer call's completer from this one's finally.
    final pauseOperation = Completer<void>();
    _pauseOperation = pauseOperation;

    try {
      unawaited(_ref.read(backgroundWorkerLockServiceProvider).unlock());
      await _performPause();
    } catch (e, stackTrace) {
      _log.severe("Error during app pause", e, stackTrace);
    } finally {
      if (!pauseOperation.isCompleted) {
        pauseOperation.complete();
      }
      if (identical(_pauseOperation, pauseOperation)) {
        _pauseOperation = null;
      }
    }
  }

  Future<void> _performPause() {
    if (_ref.read(authProvider).isAuthenticated) {
      _scheduleBackupStop();

      _ref.read(websocketProvider.notifier).disconnect();
    }

    return LogService.I.flush().catchError((_) {});
  }

  void _scheduleBackupStop() {
    _pendingBackupStopTimer?.cancel();
    _pendingBackupStopTimer = Timer(_backupStopGracePeriod, () {
      _pendingBackupStopTimer = null;
      final backupNotifier = _ref.read(driftBackupProvider.notifier);
      final hadActiveBackup = backupNotifier.isForegroundBackupActive;
      backupNotifier.stopForegroundBackup(reason: "the app being sent to the background");

      // The foreground uploader can't run once actually backgrounded. The native background
      // worker's own triggers don't cover this case (the content-uri trigger only fires for
      // *new* media, and the periodic one runs at most once an hour), so a pre-existing
      // backlog would otherwise stall until the next scheduled tick. Kick it directly instead.
      if (hadActiveBackup && CurrentPlatform.isAndroid) {
        unawaited(_ref.read(backgroundWorkerFgServiceProvider).triggerImmediateSync());
      }
    });
  }

  void _cancelPendingBackupStop() {
    _pendingBackupStopTimer?.cancel();
    _pendingBackupStopTimer = null;
  }

  Future<void> handleAppDetached() async {
    state = AppLifeCycleEnum.detached;

    // The app is actually going away (not just a brief switcher glance), so there's
    // no point waiting out the grace period - stop the foreground backup now.
    _cancelPendingBackupStop();
    if (_ref.read(authProvider).isAuthenticated) {
      _ref.read(driftBackupProvider.notifier).stopForegroundBackup(reason: "the app being detached");
    }

    unawaited(_ref.read(backgroundWorkerLockServiceProvider).unlock());

    // Flush logs before closing database
    try {
      await LogService.I.flush();
    } catch (_) {}
  }

  void handleAppHidden() {
    state = AppLifeCycleEnum.hidden;
    // do not stop/clean up anything on inactivity: issued on every orientation change
  }
}

final appStateProvider = StateNotifierProvider<AppLifeCycleNotifier, AppLifeCycleEnum>((ref) {
  return AppLifeCycleNotifier(ref);
});
