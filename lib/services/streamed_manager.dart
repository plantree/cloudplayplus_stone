import 'package:cloudplayplus/global_settings/streaming_settings.dart';
import 'package:cloudplayplus/utils/hash_util.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:synchronized/synchronized.dart';

import '../base/logging.dart';
import '../entities/device.dart';
import '../entities/session.dart';
import 'app_info_service.dart';

// ignore: constant_identifier_names
const int AUDIO_SYSTEM = 255;

class StreamedManager {
  static Map<String, StreamingSession> sessions = {};

  //We put localstream here because we want sessions share a local stream.
  //Screenid to MediaStream
  static Map<int, MediaStream> localVideoStreams = {};
  static Map<int, int> localVideoStreamsCount = {};

  //255: system audio
  //0~n: local microphones
  //AUDIO_SYSTEM = 255;
  static Map<int, MediaStream> localAudioStreams = {};
  static int audioSenderCount = 0;

  //auto increment. used for cursor hooks.
  static int cursorImageHookID = 0;

  static ValueNotifier<int> currentlyStreamedCount = ValueNotifier(0);
  static void setCurrentStreamedState(int value) {
    //if (isCurrentlyStreamed.value != value) {
    currentlyStreamedCount.value = value;
    //}
  }

  static void startStreaming(Device target, StreamedSettings settings) async {
    bool allowConnect = ApplicationInfo
        .connectable; // || (AppPlatform.isWindows && ApplicationInfo.isSystem);
    if (!allowConnect) return;
    // 旧版本可能不传这个值，或者bug导致没有传connectPassword
    if (settings.connectPassword == null) return;
    if (StreamingSettings.connectPasswordHash !=
        HashUtil.hash(settings.connectPassword!)) return;

    await _lock.synchronized(() async {
      if (sessions.containsKey(target.websocketSessionid)) {
        VLOG0(
            "Starting session which is already started: $target.websocketSessionid");
        return;
      }
      if (!localVideoStreams.containsKey(settings.screenId)) {
        final Map<String, dynamic> mediaConstraints;
        if (AppPlatform.isWeb) {
          mediaConstraints = {
            'audio': false,
            'video': {
              'frameRate': {
                'ideal': settings.framerate,
                'max': settings.framerate
              }
            }
          };
        } else {
          var sources =
              await desktopCapturer.getSources(types: [SourceType.Screen]);
          //Todo(haichao): currently this should have no effect. we should change it to be right.
          final source = sources[settings.screenId!];
          mediaConstraints = <String, dynamic>{
            'video': {
              'deviceId': {'exact': source.id},
              'mandatory': {
                'frameRate': settings.framerate,
                'hasCursor': settings.showRemoteCursor
              }
            },
            'audio': false
          };
        }
        try {
          localVideoStreams[settings.screenId!] =
              await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
          localVideoStreamsCount[settings.screenId!] = 1;
        } catch (e) {
          //This happens on Web when user choose not to share the content.
          VLOG0("getDisplayMedia failed.$e");
          return;
        }
      } else {
        localVideoStreamsCount[settings.screenId!] =
            localVideoStreamsCount[settings.screenId!]! + 1;
      }
      StreamingSession session =
          StreamingSession(target, ApplicationInfo.thisDevice);
      cursorImageHookID++;
      session.cursorImageHookID = cursorImageHookID;
      session.acceptRequest(settings);
      sessions[target.websocketSessionid] = session;
      setCurrentStreamedState(sessions.length);
    });
  }

  static final _lock = Lock();

  static void stopStreaming(Device target) {
    _lock.synchronized(() {
      if (sessions.containsKey(target.websocketSessionid)) {
        StreamingSession? session = sessions[target.websocketSessionid];
        session?.stop();
        int screenId = session!.streamSettings!.screenId!;
        sessions.remove(target.websocketSessionid);
        localVideoStreamsCount[screenId] =
            localVideoStreamsCount[screenId]! - 1;
        if (localVideoStreamsCount[screenId] == 0) {
          if (localVideoStreams[screenId] != null) {
            localVideoStreams[screenId]?.getTracks().forEach((track) {
              track.stop();
            });
            localVideoStreams.remove(screenId);
          }
        }
        if (sessions.isEmpty) {
          //TODO(Haichao): maybe restart app to save memory? 给用户一个按钮来重启app.
        }
      } else {
        VLOG0("No session found with sessionId: $target.websocketSessionid");
      }
      setCurrentStreamedState(sessions.length);
    });
  }

  static void onAnswerReceived(
      String targetConnectionid, Map<String, dynamic> answer) {
    if (sessions.containsKey(targetConnectionid)) {
      StreamingSession? session = sessions[targetConnectionid];
      session?.onAnswerReceived(answer);
    } else {
      VLOG0("No session found with sessionId: $targetConnectionid");
    }
  }

  static void onCandidateReceived(
      String targetConnectionid, Map<String, dynamic> candidate) {
    if (sessions.containsKey(targetConnectionid)) {
      StreamingSession? session = sessions[targetConnectionid];
      session?.onCandidateReceived(candidate);
    } else {
      VLOG0("No session found with sessionId: $targetConnectionid");
    }
  }
}
