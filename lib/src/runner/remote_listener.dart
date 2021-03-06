// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';

import '../backend/declarer.dart';
import '../backend/group.dart';
import '../backend/live_test.dart';
import '../backend/metadata.dart';
import '../backend/operating_system.dart';
import '../backend/suite.dart';
import '../backend/test.dart';
import '../backend/test_platform.dart';
import '../util/remote_exception.dart';
import '../utils.dart';

class RemoteListener {
  /// The test suite to run.
  final Suite _suite;

  /// The zone to forward prints to, or `null` if prints shouldn't be forwarded.
  final Zone _printZone;

  /// Extracts metadata about all the tests in the function returned by
  /// [getMain] and returns a channel that will send information about them.
  ///
  /// The main function is wrapped in a closure so that we can handle it being
  /// undefined here rather than in the generated code.
  ///
  /// Once that's done, this starts listening for commands about which tests to
  /// run.
  ///
  /// If [hidePrints] is `true` (the default), calls to `print()` within this
  /// suite will not be forwarded to the parent zone's print handler. However,
  /// the caller may want them to be forwarded in (for example) a browser
  /// context where they'll be visible in the development console.
  static StreamChannel start(AsyncFunction getMain(), {bool hidePrints: true}) {
    // This has to be synchronous to work around sdk#25745. Otherwise, there'll
    // be an asynchronous pause before a syntax error notification is sent,
    // which will cause the send to fail entirely.
    var controller = new StreamChannelController(
        allowForeignErrors: false, sync: true);
    var channel = new MultiChannel(controller.local);

    var printZone = hidePrints ? null : Zone.current;
    runZoned(() async {
      var main;
      try {
        main = getMain();
      } on NoSuchMethodError catch (_) {
        _sendLoadException(channel, "No top-level main() function defined.");
        return;
      } catch (error, stackTrace) {
        _sendError(channel, error, stackTrace);
        return;
      }

      if (main is! Function) {
        _sendLoadException(channel, "Top-level main getter is not a function.");
        return;
      } else if (main is! AsyncFunction) {
        _sendLoadException(
            channel, "Top-level main() function takes arguments.");
        return;
      }

      var message = await channel.stream.first;
      var metadata = new Metadata.deserialize(message['metadata']);
      var declarer = new Declarer(metadata);
      await declarer.declare(main);

      var os = message['os'] == null
          ? null
          : OperatingSystem.find(message['os']);
      var platform = TestPlatform.find(message['platform']);
      var suite = new Suite(declarer.build(), platform: platform, os: os);
      new RemoteListener._(suite, printZone)._listen(channel);
    }, onError: (error, stackTrace) {
      _sendError(channel, error, stackTrace);
    }, zoneSpecification: new ZoneSpecification(print: (_, __, ___, line) {
      if (printZone != null) printZone.print(line);
      channel.sink.add({"type": "print", "line": line});
    }));

    return controller.foreign;
  }


  /// Sends a message over [channel] indicating that the tests failed to load.
  ///
  /// [message] should describe the failure.
  static void _sendLoadException(StreamChannel channel, String message) {
    channel.sink.add({"type": "loadException", "message": message});
  }

  /// Sends a message over [channel] indicating an error from user code.
  static void _sendError(StreamChannel channel, error, StackTrace stackTrace) {
    channel.sink.add({
      "type": "error",
      "error": RemoteException.serialize(error, stackTrace)
    });
  }

  RemoteListener._(this._suite, this._printZone);

  /// Send information about [_suite] across [channel] and start listening for
  /// commands to run the tests.
  void _listen(MultiChannel channel) {
    channel.sink.add({
      "type": "success",
      "root": _serializeGroup(channel, _suite.group, [])
    });
  }

  /// Serializes [group] into a JSON-safe map.
  ///
  /// [parents] lists the groups that contain [group].
  Map _serializeGroup(MultiChannel channel, Group group,
      Iterable<Group> parents) {
    parents = parents.toList()..add(group);
    return {
      "type": "group",
      "name": group.name,
      "metadata": group.metadata.serialize(),
      "trace": group.trace?.toString(),
      "setUpAll": _serializeTest(channel, group.setUpAll, parents),
      "tearDownAll": _serializeTest(channel, group.tearDownAll, parents),
      "entries": group.entries.map((entry) {
        return entry is Group
            ? _serializeGroup(channel, entry, parents)
            : _serializeTest(channel, entry, parents);
      }).toList()
    };
  }

  /// Serializes [test] into a JSON-safe map.
  ///
  /// [groups] lists the groups that contain [test]. Returns `null` if [test]
  /// is `null`.
  Map _serializeTest(MultiChannel channel, Test test, Iterable<Group> groups) {
    if (test == null) return null;

    var testChannel = channel.virtualChannel();
    testChannel.stream.listen((message) {
      assert(message['command'] == 'run');
      _runLiveTest(
          test.load(_suite, groups: groups),
          channel.virtualChannel(message['channel']));
    });

    return {
      "type": "test",
      "name": test.name,
      "metadata": test.metadata.serialize(),
      "trace": test.trace?.toString(),
      "channel": testChannel.id
    };
  }

  /// Runs [liveTest] and sends the results across [channel].
  void _runLiveTest(LiveTest liveTest, MultiChannel channel) {
    channel.stream.listen((message) {
      assert(message['command'] == 'close');
      liveTest.close();
    });

    liveTest.onStateChange.listen((state) {
      channel.sink.add({
        "type": "state-change",
        "status": state.status.name,
        "result": state.result.name
      });
    });

    liveTest.onError.listen((asyncError) {
      channel.sink.add({
        "type": "error",
        "error": RemoteException.serialize(
            asyncError.error, asyncError.stackTrace)
      });
    });

    liveTest.onMessage.listen((message) {
      if (_printZone != null) _printZone.print(message.text);
      channel.sink.add({
        "type": "message",
        "message-type": message.type.name,
        "text": message.text
      });
    });

    liveTest.run().then((_) => channel.sink.add({"type": "complete"}));
  }
}
