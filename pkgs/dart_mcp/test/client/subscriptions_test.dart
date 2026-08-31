// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:async/async.dart' show StreamQueue;
import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  late TestMCPClient client;
  late StreamController<Map<String, Object?>> incoming;
  late StreamController<Map<String, Object?>> outgoing;
  late StreamQueue<Map<String, Object?>> requests;
  late ServerConnection connection;

  setUp(() {
    client = TestMCPClient();
    incoming = StreamController<Map<String, Object?>>();
    outgoing = StreamController<Map<String, Object?>>();
    requests = StreamQueue(outgoing.stream);
    connection = client.connectServer(
      StreamChannel.withCloseGuarantee(incoming.stream, outgoing.sink),
    );
    addTearDown(() async {
      await client.shutdown();
      await requests.cancel(immediate: true);
    });
  });

  test('sends a subscriptions/listen request for the given filter', () async {
    // Left open on purpose: this test only cares about the outgoing
    // message, and `tearDown` closing the connection under it is expected
    // to fail this future, which nothing here needs to observe.
    connection
        .listen(
          SubscriptionsListenRequest(
            notifications: SubscriptionFilter(toolsListChanged: true),
          ),
        )
        .ignore();
    final request = await requests.next;

    expect(request[Keys.method], SubscriptionsListenRequest.methodName);
    expect((request[Keys.params] as Map)[Keys.notifications], {
      Keys.toolsListChanged: true,
    });
  });

  test('completes with the acknowledgement once one arrives', () async {
    final pending = connection.listen(
      SubscriptionsListenRequest(
        notifications: SubscriptionFilter(toolsListChanged: true),
      ),
    );
    final id = (await requests.next)[Keys.id]!;

    incoming.add(_acknowledged(id, toolsListChanged: true));
    final subscription = await pending;

    expect(subscription.acknowledged.notifications.toolsListChanged, isTrue);
  });

  test('exposes every acknowledgement on subscriptionAcknowledged, even one '
      'this connection has no listen() route for', () async {
    final acknowledgements = <SubscriptionsAcknowledgedNotification>[];
    connection.subscriptionAcknowledged.listen(acknowledgements.add);

    // Nothing opened a subscription under "orphan"; a caller using the raw
    // `sendRequest` API, as the server-side mixin tests do, still sees it.
    incoming.add(_acknowledged('orphan', toolsListChanged: true));
    await pumpEventQueue();

    expect(acknowledgements, hasLength(1));
    expect(acknowledgements.single.meta?[Keys.subscriptionIdMeta], 'orphan');
  });

  test('delivers only the notification types the server granted', () async {
    final pending = connection.listen(
      SubscriptionsListenRequest(
        notifications: SubscriptionFilter(
          toolsListChanged: true,
          promptsListChanged: true,
        ),
      ),
    );
    final id = (await requests.next)[Keys.id]!;
    // The server only agreed to tool changes.
    incoming.add(_acknowledged(id, toolsListChanged: true));
    final subscription = await pending;

    final toolEvents = <ToolListChangedNotification>[];
    final promptEvents = <PromptListChangedNotification>[];
    subscription.toolListChanged.listen(toolEvents.add);
    subscription.promptListChanged.listen(promptEvents.add);

    incoming.add(_notification(ToolListChangedNotification.methodName, id));
    incoming.add(_notification(PromptListChangedNotification.methodName, id));
    await pumpEventQueue();

    expect(toolEvents, hasLength(1));
    expect(
      promptEvents,
      isEmpty,
      reason: 'the server never agreed to promptsListChanged',
    );
  });

  test(
    'still feeds the connection-wide broadcast streams for a granted type',
    () async {
      final pending = connection.listen(
        SubscriptionsListenRequest(
          notifications: SubscriptionFilter(toolsListChanged: true),
        ),
      );
      final id = (await requests.next)[Keys.id]!;
      incoming.add(_acknowledged(id, toolsListChanged: true));
      final subscription = await pending;

      final onSubscription = <ToolListChangedNotification?>[];
      final onConnection = <ToolListChangedNotification?>[];
      subscription.toolListChanged.listen(onSubscription.add);
      connection.toolListChanged.listen(onConnection.add);

      incoming.add(_notification(ToolListChangedNotification.methodName, id));
      await pumpEventQueue();

      expect(onSubscription, hasLength(1));
      expect(onConnection, hasLength(1));
    },
  );

  test(
    'routes resourceUpdated only for a URI in the granted subscription',
    () async {
      final pending = connection.listen(
        SubscriptionsListenRequest(
          notifications: SubscriptionFilter(
            resourceSubscriptions: ['file:///a.txt'],
          ),
        ),
      );
      final id = (await requests.next)[Keys.id]!;
      incoming.add(_acknowledged(id, resourceSubscriptions: ['file:///a.txt']));
      final subscription = await pending;

      final events = <ResourceUpdatedNotification>[];
      subscription.resourceUpdated.listen(events.add);

      incoming.add(_resourceUpdated('file:///a.txt', id));
      incoming.add(_resourceUpdated('file:///b.txt', id));
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.uri, 'file:///a.txt');
    },
  );

  test('keeps two subscriptions on the same connection independent', () async {
    final firstPending = connection.listen(
      SubscriptionsListenRequest(
        notifications: SubscriptionFilter(toolsListChanged: true),
      ),
    );
    final firstId = (await requests.next)[Keys.id]!;
    incoming.add(_acknowledged(firstId, toolsListChanged: true));
    final first = await firstPending;

    final secondPending = connection.listen(
      SubscriptionsListenRequest(
        notifications: SubscriptionFilter(promptsListChanged: true),
      ),
    );
    final secondId = (await requests.next)[Keys.id]!;
    incoming.add(_acknowledged(secondId, promptsListChanged: true));
    final second = await secondPending;

    expect(firstId, isNot(secondId));

    final firstEvents = <ToolListChangedNotification>[];
    final secondEvents = <PromptListChangedNotification>[];
    first.toolListChanged.listen(firstEvents.add);
    second.promptListChanged.listen(secondEvents.add);

    incoming.add(
      _notification(ToolListChangedNotification.methodName, firstId),
    );
    incoming.add(
      _notification(PromptListChangedNotification.methodName, secondId),
    );
    // A list change on the second (tools-blind) subscription's id must not
    // leak into the first subscription's stream.
    incoming.add(
      _notification(PromptListChangedNotification.methodName, firstId),
    );
    await pumpEventQueue();

    expect(firstEvents, hasLength(1));
    expect(secondEvents, hasLength(1));
  });

  test('result completes and the streams close when the server ends the '
      'subscription gracefully', () async {
    final pending = connection.listen(
      SubscriptionsListenRequest(
        notifications: SubscriptionFilter(toolsListChanged: true),
      ),
    );
    final id = (await requests.next)[Keys.id]!;
    incoming.add(_acknowledged(id, toolsListChanged: true));
    final subscription = await pending;
    final streamDone = expectLater(subscription.toolListChanged, emitsDone);

    incoming.add(_result(id));

    expect((await subscription.result).subscriptionId, RequestId(id));
    await streamDone;
  });

  test('reports a transport close as an error on result, and closes the '
      'streams', () async {
    final pending = connection.listen(
      SubscriptionsListenRequest(
        notifications: SubscriptionFilter(toolsListChanged: true),
      ),
    );
    final id = (await requests.next)[Keys.id]!;
    incoming.add(_acknowledged(id, toolsListChanged: true));
    final subscription = await pending;
    final streamDone = expectLater(subscription.toolListChanged, emitsDone);

    await incoming.close();

    await expectLater(subscription.result, throwsStateError);
    await streamDone;
  });

  test('reports a transport close as an error on acknowledged if it never '
      'arrives', () async {
    final pending = connection.listen(
      SubscriptionsListenRequest(
        notifications: SubscriptionFilter(toolsListChanged: true),
      ),
    );
    await requests.next;

    await incoming.close();

    await expectLater(pending, throwsStateError);
  });
}

Map<String, Object?> _acknowledged(
  Object subscriptionId, {
  bool? toolsListChanged,
  bool? promptsListChanged,
  bool? resourcesListChanged,
  List<String>? resourceSubscriptions,
}) => {
  Keys.jsonrpc: '2.0',
  Keys.method: SubscriptionsAcknowledgedNotification.methodName,
  Keys.params: {
    Keys.notifications: {
      if (toolsListChanged != null) Keys.toolsListChanged: toolsListChanged,
      if (promptsListChanged != null)
        Keys.promptsListChanged: promptsListChanged,
      if (resourcesListChanged != null)
        Keys.resourcesListChanged: resourcesListChanged,
      if (resourceSubscriptions != null)
        Keys.resourceSubscriptions: resourceSubscriptions,
    },
    Keys.meta: {Keys.subscriptionIdMeta: subscriptionId},
  },
};

Map<String, Object?> _notification(String method, Object subscriptionId) => {
  Keys.jsonrpc: '2.0',
  Keys.method: method,
  Keys.params: {
    Keys.meta: {Keys.subscriptionIdMeta: subscriptionId},
  },
};

Map<String, Object?> _resourceUpdated(String uri, Object subscriptionId) => {
  Keys.jsonrpc: '2.0',
  Keys.method: ResourceUpdatedNotification.methodName,
  Keys.params: {
    Keys.uri: uri,
    Keys.meta: {Keys.subscriptionIdMeta: subscriptionId},
  },
};

Map<String, Object?> _result(Object subscriptionId) => {
  Keys.jsonrpc: '2.0',
  Keys.id: subscriptionId,
  Keys.result: {
    Keys.meta: {Keys.subscriptionIdMeta: subscriptionId},
  },
};
