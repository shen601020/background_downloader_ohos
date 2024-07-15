import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/src/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'base_downloader.dart';
import 'chunk.dart';
import 'exceptions.dart';
import 'file_downloader.dart';
import 'models.dart';
import 'permissions.dart';
import 'task.dart';

/// Implementation of download functionality for native platforms
///
/// Uses [MethodChannel] to communicate with native platforms
abstract class NativeDownloader extends BaseDownloader {
  static const methodChannel =
  MethodChannel('com.bbflight.background_downloader');
  static const _backgroundChannel =
  MethodChannel('com.bbflight.background_downloader.background');

  @override
  Future<void> initialize() async {
    await super.initialize();
    WidgetsFlutterBinding.ensureInitialized();
    // listen to the background channel, receiving updates on download status
    // or progress.
    // First argument is the Task as JSON string, next argument(s) depends
    // on the method.
    //
    // If the task JsonString is empty, a dummy task will be created
    _backgroundChannel.setMethodCallHandler((call) async {
      final args = call.arguments as List<dynamic>;
      var taskJsonString = args.first as String;
      final task = taskJsonString.isNotEmpty
          ? Task.createFromJson(jsonDecode(taskJsonString))
          : DownloadTask(url: 'url');
      final message = (
      call.method,
      args.length > 2
          ? args.getRange(1, args.length).toList(growable: false)
          : args[1]
      );

      if (message.$0 == 'statusUpdate' && message is (String, int)) {
        final status = TaskStatus.values[message.$1];
        if (task.group != BaseDownloader.chunkGroup) {
          processStatusUpdate(TaskStatusUpdate(task, status));
        } else {
          // this is a chunk task, so pass to native
          Future.delayed(const Duration(milliseconds: 100)).then((_) =>
              methodChannel.invokeMethod('chunkStatusUpdate', [
                Chunk.getParentTaskId(task),
                task.taskId,
                status.index,
                null,
                null
              ]));
        }
      } else if (message.$0 == 'statusUpdate' && message is (String, List)) {
        // list is like this
        // [
        //   int statusOrdinal,
        //   String? responseBody,
        //   Map<Object?, Object?>? responseHeaders,
        //   int? responseStatusCode,
        //   String? mimeType,
        //   String? charSet
        // ]
        final statusOrdinal = message.$1.find(0, 0);
        final responseBody = message.$1.find(1, '');
        final responseHeaders = message.$1.find(2, {});
        final responseStatusCode = message.$1.find(3, 0);
        final mimeType = message.$1.find(4, '');
        final charSet = message.$1.find(5, '');
        final status = TaskStatus.values[statusOrdinal];
        if (task.group != BaseDownloader.chunkGroup) {
          final Map<String, String>? cleanResponseHeaders = responseHeaders ==
              null
              ? null
              : {
            for (var entry in responseHeaders.entries.where(
                    (entry) => entry.key != null && entry.value != null))
              entry.key.toString().toLowerCase(): entry.value.toString()
          };
          processStatusUpdate(TaskStatusUpdate(
              task,
              status,
              null,
              responseBody,
              cleanResponseHeaders,
              responseStatusCode,
              mimeType,
              charSet));
        } else {
          // this is a chunk task, so pass to native
          Future.delayed(const Duration(milliseconds: 100)).then((_) =>
              methodChannel.invokeMethod('chunkStatusUpdate', [
                Chunk.getParentTaskId(task),
                task.taskId,
                status.index,
                null,
                responseBody
              ]));
        }
      } else if (message.$0 == 'statusUpdate' && message is (String, List)) {
        // list is like this
        // [
        //   int statusOrdinal,
        //   String typeString,
        //   String? description,
        //   int? httpResponseCode,
        //   String? responseBody
        // ]
        final statusOrdinal = message.$1.find(0, 200);
        final typeString = message.$1.find(1, '');
        final description = message.$1.find(2, '');
        final httpResponseCode = message.$1.find(3, 200);
        final responseBody = message.$1.find(4, '');
        final status = TaskStatus.values[statusOrdinal];
        TaskException? exception;
        if (status == TaskStatus.failed) {
          exception = TaskException.fromTypeString(
              typeString, description, httpResponseCode);
        }
        if (task.group != BaseDownloader.chunkGroup) {
          processStatusUpdate(
              TaskStatusUpdate(task, status, exception, responseBody));
        } else {
          // this is a chunk task, so pass to native
          Future.delayed(const Duration(milliseconds: 100))
              .then((_) =>
              methodChannel.invokeMethod('chunkStatusUpdate', [
                Chunk.getParentTaskId(task),
                task.taskId,
                status.index,
                exception?.toJsonString(),
                responseBody
              ]));
        }
      } else if (message.$0 == 'progressUpdate' && message is (String, List)) {
        final progress = message.$1.find(0, 0.0);
        final expectedFileSize = message.$1.find(1, 0);
        final networkSpeed = message.$1.find(2, 0.0);
        final timeRemaining = message.$1.find(3, 0);
        if (task.group != BaseDownloader.chunkGroup) {
          processProgressUpdate(TaskProgressUpdate(
              task,
              progress,
              expectedFileSize,
              networkSpeed,
              Duration(milliseconds: timeRemaining)));
        } else {
          // this is a chunk task, so pass parent taskId,
          // chunk taskId and progress to native
          Future.delayed(const Duration(milliseconds: 100)).then((_) =>
              methodChannel.invokeMethod('chunkProgressUpdate',
                  [Chunk.getParentTaskId(task), task.taskId, progress]));
        }
      } else if (message.$0 == 'canResume' && message is (String, bool)) {
        setCanResume(task, message.$1);
      } else if (message.$0 == 'resumeData' && message is (String, List)) {
        final data = message.$1.find(0, '');
        final requiredStartByte = message.$1.find(1, 0);
        final eTag = message.$1.find(2, '');
        setResumeData(ResumeData(task, data, requiredStartByte, eTag));
      } else if (message.$0 == 'canResume' && message is (String, String)) {
        setResumeData(ResumeData(task, message.$1));
      } else if (message.$0 == 'notificationTap' && message is (String, int)) {
        final notificationType =
        NotificationType.values[message.$1];
        processNotificationTap(task, notificationType);
        return true; // this mess
      } else if (message.$0 == 'enqueueChild' && message is (String, String)) {
        final childTask =
        Task.createFromJson(jsonDecode(message.$1));
        Future.delayed(const Duration(milliseconds: 100))
            .then((_) => FileDownloader().enqueue(childTask));
      } else
      if (message.$0 == 'cancelTasksWithId' && message is (String, String)) {
        final taskIds = List<String>.from(jsonDecode(message.$1));
        Future.delayed(const Duration(milliseconds: 100))
            .then((_) => FileDownloader().cancelTasksWithIds(taskIds));
      } else if (message.$0 == 'pauseTasks' && message is (String, String)) {
        final listOfTasks = List<DownloadTask>.from(jsonDecode(
            message.$1,
            reviver: (key, value) {
              if (key is int) {
                return Task.createFromJson(value as Map<String, dynamic>);
              } else {
                return value;
              }
            }));

        Future.delayed(const Duration(milliseconds: 100)).then((_) async {
          for (final chunkTask in listOfTasks) {
            await FileDownloader().pause(chunkTask);
          }
        });
      } else
      if (message.$0 == 'permissionRequestResult' && message is (String, int)) {
        permissionsService.onPermissionRequestResult(
            PermissionStatus.values[message.$1]);
      } else {
        log.warning('Background channel: no match for message $message');
        throw ArgumentError(
            'Background channel: no match for message $message');
      }
      return true;
    });
  }

  @override
  Future<bool> enqueue(Task task) async {
    super.enqueue(task);
    final notificationConfig = notificationConfigForTask(task);
    return await methodChannel.invokeMethod<bool>('enqueue', [
      jsonEncode(task.toJson()),
      notificationConfig != null
          ? jsonEncode(notificationConfig.toJson())
          : null,
    ]) ??
        false;
  }

  @override
  Future<int> reset(String group) async {
    final retryAndPausedTaskCount = await super.reset(group);
    final nativeCount =
        await methodChannel.invokeMethod<int>('reset', group) ?? 0;
    return retryAndPausedTaskCount + nativeCount;
  }

  @override
  Future<List<Task>> allTasks(String group,
      bool includeTasksWaitingToRetry) async {
    final retryAndPausedTasks =
    await super.allTasks(group, includeTasksWaitingToRetry);
    final result =
        await methodChannel.invokeMethod<List<dynamic>?>('allTasks', group) ??
            [];
    final tasks = result
        .map((e) => Task.createFromJson(jsonDecode(e as String)))
        .toList();
    return [...retryAndPausedTasks, ...tasks];
  }

  @override
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds) async =>
      await methodChannel.invokeMethod<bool>('cancelTasksWithIds', taskIds) ??
          false;

  @override
  Future<Task?> taskForId(String taskId) async {
    var task = await super.taskForId(taskId);
    if (task != null) {
      return task;
    }
    final jsonString =
    await methodChannel.invokeMethod<String>('taskForId', taskId);
    if (jsonString != null) {
      return Task.createFromJsonString(jsonString);
    }
    return null;
  }

  @override
  Future<bool> pause(Task task) async =>
      await methodChannel.invokeMethod<bool>('pause', task.taskId) ?? false;

  @override
  Future<bool> resume(Task task) async {
    if (await super.resume(task)) {
      task = awaitTasks.containsKey(task)
          ? awaitTasks.keys
          .firstWhere((awaitTask) => awaitTask.taskId == task.taskId)
          : task;
      final taskResumeData = await getResumeData(task.taskId);
      if (taskResumeData != null) {
        final notificationConfig = notificationConfigForTask(task);
        final enqueueSuccess =
            await methodChannel.invokeMethod<bool>('enqueue', [
              jsonEncode(task.toJson()),
              notificationConfig != null
                  ? jsonEncode(notificationConfig.toJson())
                  : null,
              taskResumeData.data,
              taskResumeData.requiredStartByte,
              taskResumeData.eTag
            ]) ??
                false;
        if (enqueueSuccess && task is ParallelDownloadTask) {
          return resumeChunkTasks(task, taskResumeData);
        }
        return enqueueSuccess;
      }
    }
    return false;
  }

  @override
  Future<bool> requireWiFi(RequireWiFi requirement,
      rescheduleRunningTasks) async {
    return await methodChannel.invokeMethod(
        'requireWiFi', [requirement.index, rescheduleRunningTasks]) ??
        false;
  }

  @override
  Future<RequireWiFi> getRequireWiFiSetting() async {
    return RequireWiFi
        .values[await methodChannel.invokeMethod('getRequireWiFiSetting') ?? 0];
  }

  @override
  void updateNotification(Task task, TaskStatus? taskStatusOrNull) {
    final notificationConfig = notificationConfigForTask(task);
    if (notificationConfig != null) {
      methodChannel.invokeMethod('updateNotification', [
        jsonEncode(task.toJson()),
        jsonEncode(notificationConfig.toJson()),
        taskStatusOrNull?.index
      ]);
    }
  }

  /// Retrieve data that was not delivered to Dart, as a Map keyed by taskId
  /// with one map for each taskId
  ///
  /// Asks the native platform for locally stored data for resumeData,
  /// status updates or progress updates.
  /// ResumeData has a [ResumeData] json representation
  /// StatusUpdates has a mixed Task & TaskStatus json representation 'taskStatus'
  /// ProgressUpdates has a mixed Task & double json representation 'progress'
  @override
  Future<Map<String, String>> popUndeliveredData(Undelivered dataType) async {
    final String jsonString;
    if (dataType == Undelivered.resumeData) {
      jsonString = await methodChannel.invokeMethod('popResumeData');
    } else if (dataType == Undelivered.statusUpdates) {
      jsonString = await methodChannel.invokeMethod('popStatusUpdates');
    } else if (dataType == Undelivered.progressUpdates) {
      jsonString = await methodChannel.invokeMethod('popProgressUpdates');
    } else {
      throw ArgumentError('Unsupported data type: $dataType');
    }
    return Map.from(jsonDecode(jsonString));
  }


  @override
  Future<String?> moveToSharedStorage(String filePath,
      SharedStorage destination, String directory, String? mimeType) =>
      methodChannel.invokeMethod<String?>('moveToSharedStorage',
          [filePath, destination.index, directory, mimeType]);

  @override
  Future<String?> pathInSharedStorage(String filePath,
      SharedStorage destination, String directory) =>
      methodChannel.invokeMethod<String?>(
          'pathInSharedStorage', [filePath, destination.index, directory]);

  @override
  Future<bool> openFile(Task? task, String? filePath, String? mimeType) async {
    final result = await methodChannel.invokeMethod<bool>('openFile',
        [task != null ? jsonEncode(task.toJson()) : null, filePath, mimeType]);
    return result ?? false;
  }

  @override
  Future<String> platformVersion() async {
    return (await methodChannel.invokeMethod<String>('platformVersion')) ?? '';
  }

  @override
  Future<Duration> getTaskTimeout() async {
    if (Platform.isAndroid) {
      final timeoutMillis =
          await methodChannel.invokeMethod<int>('getTaskTimeout') ?? 0;
      return Duration(milliseconds: timeoutMillis);
    }
    return const Duration(hours: 4); // on iOS, resource timeout
  }

  @override
  Future<void> setForceFailPostOnBackgroundChannel(bool value) async {
    await methodChannel.invokeMethod('forceFailPostOnBackgroundChannel', value);
  }

  @override
  Future<String> testSuggestedFilename(DownloadTask task,
      String contentDisposition) async =>
      await methodChannel.invokeMethod<String>('testSuggestedFilename',
          [jsonEncode(task.toJson()), contentDisposition]) ??
          '';

//   @override
//   Future<(String, String)> configureItem((String, dynamic) configItem) async {
//     switch (configItem) {
//       case (Config.requestTimeout, Duration? duration):
//         await NativeDownloader.methodChannel
//             .invokeMethod('configRequestTimeout', duration?.inSeconds);
//
//       case (Config.proxy, (String address, int port)):
//         await NativeDownloader.methodChannel
//             .invokeMethod('configProxyAddress', address);
//         await NativeDownloader.methodChannel
//             .invokeMethod('configProxyPort', port);
//
//       case (Config.proxy, false):
//         await NativeDownloader.methodChannel
//             .invokeMethod('configProxyAddress', null);
//         await NativeDownloader.methodChannel
//             .invokeMethod('configProxyPort', null);
//
//       case (Config.checkAvailableSpace, int minimum):
//         assert(minimum > 0, 'Minimum available space must be in MB and > 0');
//         await NativeDownloader.methodChannel
//             .invokeMethod('configCheckAvailableSpace', minimum);
//
//       case (Config.checkAvailableSpace, false):
//       case (Config.checkAvailableSpace, Config.never):
//         await NativeDownloader.methodChannel
//             .invokeMethod('configCheckAvailableSpace', null);
//
//       case (
//       Config.holdingQueue,
//       (
//       int? maxConcurrent,
//       int? maxConcurrentByHost,
//       int? maxConcurrentByGroup
//       )
//       ):
//         await NativeDownloader.methodChannel
//             .invokeMethod('configHoldingQueue', [
//           maxConcurrent ?? 1 << 20,
//           maxConcurrentByHost ?? 1 << 20,
//           maxConcurrentByGroup ?? 1 << 20
//         ]);
//
//       default:
//         return (
//         configItem.$1,
//         'not implemented'
//         ); // this method did not process this configItem
//     }
//     return (configItem.$1, ''); // normal result
//   }
// }

  @override
  Future<(String, String)> configureItem((String, dynamic) configItem) async {
    final String key = configItem.$0;
    final dynamic value = configItem.$1;

    if (key == Config.requestTimeout && value is Duration) {
      await NativeDownloader.methodChannel.invokeMethod(
          'configRequestTimeout', value.inSeconds);
    } else if (key == Config.proxy) {
      if (value is (String, int)) {
        final String address = value.$0;
        final int port = value.$1;
        await NativeDownloader.methodChannel.invokeMethod(
            'configProxyAddress', address);
        await NativeDownloader.methodChannel.invokeMethod(
            'configProxyPort', port);
      } else if (value == false) {
        await NativeDownloader.methodChannel.invokeMethod(
            'configProxyAddress', null);
        await NativeDownloader.methodChannel.invokeMethod(
            'configProxyPort', null);
      }
    } else if (key == Config.checkAvailableSpace) {
      if (value is int) {
        assert(value > 0, 'Minimum available space must be in MB and > 0');
        await NativeDownloader.methodChannel.invokeMethod(
            'configCheckAvailableSpace', value);
      } else if (value == false || value == Config.never) {
        await NativeDownloader.methodChannel.invokeMethod(
            'configCheckAvailableSpace', null);
      }
    } else if (key == Config.holdingQueue) {
      if (value is (int?, int?, int?)) {
        final int? maxConcurrent = value.$0;
        final int? maxConcurrentByHost = value.$1;
        final int? maxConcurrentByGroup = value.$2;
        await NativeDownloader.methodChannel.invokeMethod(
            'configHoldingQueue', [
          maxConcurrent ?? 1 << 20,
          maxConcurrentByHost ?? 1 << 20,
          maxConcurrentByGroup ?? 1 << /* typo fix */ 20
        ]);
      }
    } else {
      return (key, 'not implemented'); // this method did not process this configItem
    }
    return (key, ''); // normal result
  }
}


/// Android native downloader
class AndroidDownloader extends NativeDownloader {
  static final AndroidDownloader _singleton = AndroidDownloader._internal();

  factory AndroidDownloader() {
    return _singleton;
  }

  AndroidDownloader._internal();

  @override
  dynamic platformConfig({dynamic globalConfig,
    dynamic androidConfig,
    dynamic iOSConfig,
    dynamic desktopConfig}) =>
      androidConfig;

  @override
  Future<(String, String)> configureItem((String, dynamic) configItem) async {
    final superResult = await super.configureItem(configItem);
    if (superResult.$1 != 'not implemented') {
      return superResult;
    }
    final String configKey = configItem.$0;
    final configValue = configItem.$1;
    if (configKey == Config.runInForeground) {
      if (configValue is bool) {
        final bool activate = configValue;
        await NativeDownloader.methodChannel.invokeMethod(
            'configForegroundFileSize', activate ? 0 : -1);
      } else if (configValue is String) {
        final String whenTo = configValue;
        assert([Config.never, Config.always].contains(whenTo), '${Config
            .runInForeground} expects one of ${[Config.never, Config.always]}');
        await NativeDownloader.methodChannel.invokeMethod(
            'configForegroundFileSize', Config.argToInt(whenTo));
      }
    } else if (configKey == Config.runInForegroundIfFileLargerThan &&
        configValue is int) {
      final int fileSize = configValue;
      await NativeDownloader.methodChannel.invokeMethod(
          'configForegroundFileSize', fileSize);
    } else if (configKey == Config.bypassTLSCertificateValidation &&
        configValue is bool) {
      final bool bypass = configValue;
      if (bypass) {
        if (kReleaseMode) {
          throw ArgumentError(
              'You cannot bypass certificate validation in release mode');
        }
        await NativeDownloader.methodChannel.invokeMethod(
            'configBypassTLSCertificateValidation');
        log.warning(
            'TLS certificate validation is bypassed. This is insecure and cannot be done in release mode');
      } else {
        throw ArgumentError(
            'To undo bypassing the certificate validation, restart and leave out the "configBypassCertificateValidation" configuration');
      }
    } else if (configKey == Config.useCacheDir && configValue is String) {
      final String whenTo = configValue;
      assert([Config.never, Config.whenAble, Config.always].contains(
          whenTo), '${Config.useCacheDir} expects one of ${[
        Config.never,
        Config.whenAble,
        Config.always
      ]}');
      await NativeDownloader.methodChannel.invokeMethod(
          'configUseCacheDir', Config.argToInt(whenTo));
    } else
    if (configKey == Config.useExternalStorage && configValue is String) {
      final String whenTo = configValue;
      assert([Config.never, Config.always].contains(whenTo), '${Config
          .useExternalStorage} expects one of ${[
        Config.never,
        Config.always
      ]}');
      await NativeDownloader.methodChannel.invokeMethod(
          'configUseExternalStorage', Config.argToInt(whenTo));
      Task.useExternalStorage = whenTo == Config.always;
    } else {
      return (configKey, 'not implemented'); // this method did not process this configItem
    }
    return (configItem.$0, ''); // normal result
  }
}

/// iOS native downloader
class IOSDownloader extends NativeDownloader {
  static final IOSDownloader _singleton = IOSDownloader._internal();

  factory IOSDownloader() {
    return _singleton;
  }

  IOSDownloader._internal();

  @override
  dynamic platformConfig({dynamic globalConfig,
    dynamic androidConfig,
    dynamic iOSConfig,
    dynamic desktopConfig}) =>
      iOSConfig;

  @override
  Future<(String, String)> configureItem((String, dynamic) configItem) async {
    final superResult = await super.configureItem(configItem);
    if (superResult.$1 != 'not implemented') {
      return superResult;
    }
    if (configItem is (String, Duration) &&
        configItem.$0 == Config.resourceTimeout) {
      final Duration duration = configItem.$1;
      await NativeDownloader.methodChannel.invokeMethod(
          'configResourceTimeout', duration.inSeconds);
    } else if (configItem is (String, Map<String, String>) &&
        configItem.$0 == Config.localize) {
      final Map<String, String> translation = configItem.$1;
      await NativeDownloader.methodChannel.invokeMethod(
          'configLocalize', translation);
    } else {
      return (configItem
          .$0, 'not implemented'); // this method did not process this configItem
    }

    return (configItem.$0, ''); // normal result
  }
}
