// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:json_rpc_2/error_code.dart' as error_code;
import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// A server on a connection which is not request scoped, the shape a stdio
/// transport for this revision has.
base class _SubscribingServer extends MCPServer
    with ResourcesSupport, SubscriptionsSupport {
  _SubscribingServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'test server', version: '0.1.0'),
      );
}

void main() {
  late TestEnvironment<TestMCPClient, _SubscribingServer> environment;
  final acknowledgements = <SubscriptionsAcknowledgedNotification>[];

  setUp(() async {
    acknowledgements.clear();
    environment = TestEnvironment(TestMCPClient(), _SubscribingServer.new);
    environment.serverConnection.registerNotificationHandler(
      SubscriptionsAcknowledgedNotification.methodName,
      acknowledgements.add,
    );
    // The 2026-07-28 revision took the `initialize` handshake out, so a
    // transport for it hands the server its context directly.
    await environment.server.initialize(
      MCPServerInitialization(
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: environment.client.capabilities,
      ),
    );
    environment.server.handleInitialized();
  });

  SubscriptionsListenRequest listenRequest({
    SubscriptionFilter? notifications,
  }) => SubscriptionsListenRequest(
    notifications: notifications ?? SubscriptionFilter(toolsListChanged: true),
  );

  /// Opens a `subscriptions/listen` subscription over the test connection.
  Future<SubscriptionsListenResult> listen({
    SubscriptionFilter? notifications,
  }) => environment.serverConnection.sendRequest(
    SubscriptionsListenRequest.methodName,
    listenRequest(notifications: notifications),
  );

  test(
    'stamps the id on the acknowledgement and holds until shutdown',
    () async {
      final listening = listen();
      var completed = false;
      unawaited(listening.then((_) => completed = true));
      await pumpEventQueue(times: 20);

      expect(acknowledgements, hasLength(1));
      final id = acknowledgements.single.meta[Keys.subscriptionIdMeta];
      expect(
        id,
        isNotNull,
        reason: 'the mixin stamps the id, it does not wait for HTTP to do it',
      );
      expect(
        completed,
        isFalse,
        reason: 'the listen request stays open until shutdown',
      );

      unawaited(environment.server.shutdown());
      expect(
        (await listening.timeout(const Duration(seconds: 5))).subscriptionId,
        id,
      );
      expect(completed, isTrue);
    },
  );

  test(
    'refuses a null subscription id, and stays open for the next one',
    () async {
      await expectLater(
        environment.server.handleSubscriptionsListen(listenRequest()),
        throwsA(
          isA<RpcException>()
              .having((e) => e.code, 'code', error_code.INVALID_REQUEST)
              .having((e) => e.data, 'data', isNot(contains('stack'))),
        ),
      );
      expect(
        acknowledgements,
        isEmpty,
        reason: 'a refused request opens nothing',
      );

      final listening = listen();
      await pumpEventQueue();
      expect(acknowledgements, hasLength(1));

      await environment.server.shutdown();
      expect((await listening).subscriptionId, isNotNull);
    },
  );

  test(
    'distinguishes notifications from null and concurrent request ids',
    () async {
      final incoming = StreamController<Map<String, Object?>>();
      final outgoing = StreamController<Map<String, Object?>>();
      final messages = <Map<String, Object?>>[];
      final outputSubscription = outgoing.stream.listen(messages.add);
      final server = _SubscribingServer(
        StreamChannel.withCloseGuarantee(incoming.stream, outgoing.sink),
      );
      addTearDown(() async {
        await server.shutdown();
        await incoming.close();
        await outputSubscription.cancel();
      });
      await server.initialize(
        MCPServerInitialization(
          protocolVersion: ProtocolVersion.v2026_07_28,
          clientCapabilities: ClientCapabilities(),
        ),
      );
      server.handleInitialized();

      Map<String, Object?> listenMessage({
        required bool includeId,
        Object? id,
      }) => {
        Keys.jsonrpc: '2.0',
        if (includeId) Keys.id: id,
        Keys.method: SubscriptionsListenRequest.methodName,
        Keys.params: listenRequest(),
      };

      incoming.add(listenMessage(includeId: false));
      await pumpEventQueue(times: 20);
      expect(messages, isEmpty, reason: 'a notification gets no response');

      incoming.add(listenMessage(includeId: true));
      await pumpEventQueue(times: 20);
      expect(messages, hasLength(1));
      expect(messages.single[Keys.id], isNull);
      expect(
        (messages.single[Keys.error] as Map<String, Object?>)[Keys.code],
        error_code.INVALID_REQUEST,
      );
      messages.clear();

      incoming.add(listenMessage(includeId: true, id: 'first'));
      incoming.add(listenMessage(includeId: true, id: 7));
      await pumpEventQueue(times: 20);
      final acknowledgements =
          messages
              .where(
                (message) =>
                    message[Keys.method] ==
                    SubscriptionsAcknowledgedNotification.methodName,
              )
              .toList();
      expect(acknowledgements, hasLength(2));
      expect(
        acknowledgements.map(
          (message) =>
              ((message[Keys.params] as Map<String, Object?>)[Keys.meta]
                  as Map<String, Object?>)[Keys.subscriptionIdMeta],
        ),
        unorderedEquals(['first', 7]),
      );
      expect(
        messages.where((message) => message.containsKey(Keys.result)),
        isEmpty,
      );

      await server.shutdown();
      await pumpEventQueue(times: 20);
      final responses =
          messages
              .where((message) => message.containsKey(Keys.result))
              .toList();
      expect(responses, hasLength(2));
      for (final response in responses) {
        final result = response[Keys.result] as Map<String, Object?>;
        final meta = result[Keys.meta] as Map<String, Object?>;
        expect(meta[Keys.subscriptionIdMeta], response[Keys.id]);
      }
    },
  );

  test('arms an acknowledged resource subscription', () async {
    final watched = Resource(name: 'watched', uri: 'file:///a');
    final ignored = Resource(name: 'ignored', uri: 'file:///b');
    for (final resource in [watched, ignored]) {
      environment.server.addResource(
        resource,
        (_) => ReadResourceResult(contents: const []),
      );
    }
    final updated = <String>[];
    final updates = environment.serverConnection.resourceUpdated.listen(
      (notification) => updated.add(notification.uri),
    );
    addTearDown(updates.cancel);

    final listening = listen(
      notifications: SubscriptionFilter(resourceSubscriptions: [watched.uri]),
    );
    await pumpEventQueue();
    expect(acknowledgements.single.notifications?.resourceSubscriptions, [
      watched.uri,
    ]);

    environment.server.updateResource(ignored);
    environment.server.updateResource(watched);
    await pumpEventQueue();
    expect(updated, [
      watched.uri,
    ], reason: 'a resource the acknowledged filter leaves out sends nothing');

    await environment.server.shutdown();
    expect((await listening).subscriptionId, isNotNull);
  });

  test('does not keep a reserved id after a malformed filter', () async {
    await expectLater(
      environment.server.handleSubscriptionsListen(
        SubscriptionsListenRequest.fromMap(<String, Object?>{
          Keys.notifications: 42,
        }),
        RequestId('leaked'),
      ),
      throwsA(
        isA<RpcException>().having(
          (e) => e.code,
          'code',
          error_code.INVALID_PARAMS,
        ),
      ),
    );
    final listening = environment.server.handleSubscriptionsListen(
      listenRequest(),
      RequestId('leaked'),
    );
    await pumpEventQueue();
    expect(
      acknowledgements,
      hasLength(1),
      reason: 'a rejected request must not name the next one',
    );
    expect(acknowledgements.single.meta[Keys.subscriptionIdMeta], 'leaked');

    await environment.server.shutdown();
    expect((await listening).subscriptionId, 'leaked');
  });

  test(
    'refuses a duplicate subscription id and keeps the first open',
    () async {
      final first = listen();
      await pumpEventQueue();
      final openedId = RequestId(
        acknowledgements.single.meta[Keys.subscriptionIdMeta]!,
      );

      await expectLater(
        environment.server.handleSubscriptionsListen(listenRequest(), openedId),
        throwsA(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            error_code.INVALID_REQUEST,
          ),
        ),
      );
      expect(acknowledgements, hasLength(1));

      await environment.server.shutdown();
      expect((await first).subscriptionId, openedId);
    },
  );

  test('names two in-flight listens from their own JSON-RPC IDs', () async {
    final first = listen();
    final second = listen();
    await pumpEventQueue(times: 20);
    expect(acknowledgements, hasLength(2));
    expect({
      acknowledgements[0].meta[Keys.subscriptionIdMeta],
      acknowledgements[1].meta[Keys.subscriptionIdMeta],
    }, hasLength(2));

    await environment.server.shutdown();
    final firstId = (await first).subscriptionId;
    final secondId = (await second).subscriptionId;
    expect(firstId, isNot(equals(secondId)));
  });
}
