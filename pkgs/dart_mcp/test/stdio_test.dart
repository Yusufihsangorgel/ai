// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:json_rpc_2/error_code.dart' as error_code;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('jsonRpcChannel', () {
    test('decodes json objects and encodes them back', () async {
      final harness = _EdgeHarness();
      harness.wireIn.add(
        jsonEncode({Keys.jsonrpc: '2.0', Keys.method: 'notifications/test'}),
      );
      await pumpEventQueue();
      expect(harness.received.single[Keys.method], 'notifications/test');

      harness.channel.sink.add({Keys.jsonrpc: '2.0', Keys.id: 1});
      expect(jsonDecode(await harness.wire.next), {
        Keys.jsonrpc: '2.0',
        Keys.id: 1,
      });
    });

    test('answers invalid json with a parse error', () async {
      final harness = _EdgeHarness();
      harness.wireIn.add('Just some random text');

      final response = await harness.nextWireObject();
      expect(response[Keys.id], isNull);
      final error = _error(response);
      expect(error[Keys.code], error_code.PARSE_ERROR);
      expect(error[Keys.message], contains('Invalid JSON'));
    });

    test('answers a frame which is not a json object', () async {
      final harness = _EdgeHarness();
      harness.wireIn.add('42');

      final response = await harness.nextWireObject();
      expect(response[Keys.id], isNull);
      final error = _error(response);
      expect(error[Keys.code], error_code.INVALID_REQUEST);
      expect(error[Keys.message], contains('must be a JSON object'));
    });

    test('answers a batch frame with an invalid request error', () async {
      final harness = _EdgeHarness();
      harness.wireIn.add(
        jsonEncode([
          {
            Keys.jsonrpc: '2.0',
            Keys.id: 1,
            Keys.method: PingRequest.methodName,
          },
        ]),
      );

      final response = await harness.nextWireObject();
      expect(response[Keys.id], isNull);
      final error = _error(response);
      expect(error[Keys.code], error_code.INVALID_REQUEST);
      expect(error[Keys.message], contains('Batch messages are not supported'));
    });

    test('a server survives invalid frames', () async {
      final harness = _EdgeHarness(drain: false);
      final server = TestMCPServer(harness.channel);
      addTearDown(server.shutdown);

      harness.wireIn.add('Just some random text');
      final parseError = _error(await harness.nextWireObject());
      expect(parseError[Keys.code], error_code.PARSE_ERROR);

      harness.wireIn.add(
        jsonEncode({
          Keys.jsonrpc: '2.0',
          Keys.id: 1,
          Keys.method: InitializeRequest.methodName,
          Keys.params: {
            Keys.protocolVersion: ProtocolVersion.latestSupported.versionString,
            Keys.capabilities: <String, Object?>{},
            Keys.clientInfo: {Keys.name: 'test client', Keys.version: '0.1'},
          },
        }),
      );
      final response = await harness.nextWireObject();
      expect(response[Keys.id], 1);
      expect(response.containsKey(Keys.result), isTrue);
    });

    test('a client survives invalid frames', () async {
      final harness = _EdgeHarness(drain: false);
      final client = TestMCPClient();
      addTearDown(client.shutdown);
      final connection = client.connectServer(harness.channel);

      harness.wireIn.add('Just some random text');
      final parseError = _error(await harness.nextWireObject());
      expect(parseError[Keys.code], error_code.PARSE_ERROR);

      final initializeDone = connection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: client.capabilities,
          clientInfo: client.implementation,
        ),
      );
      final request = await harness.nextWireObject();
      expect(request[Keys.method], InitializeRequest.methodName);
      harness.wireIn.add(
        jsonEncode({
          Keys.jsonrpc: '2.0',
          Keys.id: request[Keys.id],
          Keys.result: {
            Keys.protocolVersion: ProtocolVersion.latestSupported.versionString,
            Keys.capabilities: <String, Object?>{},
            Keys.serverInfo: {Keys.name: 'test server', Keys.version: '0.1'},
          },
        }),
      );
      final result = await initializeDone;
      expect(result.serverInfo.name, 'test server');
    });
  });

  group('stdioChannel', () {
    test('speaks newline delimited json over bytes', () async {
      final input = StreamController<List<int>>();
      final output = StreamController<List<int>>();
      final channel = stdioChannel(input: input.stream, output: output.sink);

      input.add(utf8.encode('{"jsonrpc":"2.0","method":"a"}\n'));
      expect((await channel.stream.first)[Keys.method], 'a');

      channel.sink.add({Keys.jsonrpc: '2.0', Keys.id: 2});
      final line = utf8.decode(await output.stream.first);
      expect(line, endsWith('\n'));
      expect(jsonDecode(line), {Keys.jsonrpc: '2.0', Keys.id: 2});
    });
  });

  group('fromStreamChannel', () {
    test(
      'initialize offering latestSupported keeps a handshake revision',
      () async {
        final harness = _EdgeHarness(drain: false);
        final server = _CountingServer(harness.channel);
        addTearDown(server.shutdown);

        harness.wireIn.add(
          jsonEncode({
            Keys.jsonrpc: '2.0',
            Keys.id: 1,
            Keys.method: InitializeRequest.methodName,
            Keys.params: {
              Keys.protocolVersion:
                  ProtocolVersion.latestSupported.versionString,
              Keys.capabilities: <String, Object?>{},
              Keys.clientInfo: {Keys.name: 'test client', Keys.version: '0.1'},
            },
          }),
        );
        final result =
            (await harness.nextWireObject())[Keys.result]
                as Map<String, Object?>;
        final negotiated = ProtocolVersion.tryParse(
          result[Keys.protocolVersion] as String,
        );
        expect(negotiated, isNot(ProtocolVersion.v2026_07_28));
        expect(negotiated?.methodIsValid(InitializeRequest.methodName), isTrue);
        expect(server.initializeCalls, 1);

        harness.wireIn.add(
          jsonEncode({
            Keys.jsonrpc: '2.0',
            Keys.id: 2,
            Keys.method: DiscoverRequest.methodName,
            Keys.params: {
              Keys.meta: {
                Keys.protocolVersionMeta:
                    ProtocolVersion.v2026_07_28.versionString,
                Keys.clientCapabilitiesMeta: <String, Object?>{},
              },
            },
          }),
        );
        final error = _error(await harness.nextWireObject());
        expect(error[Keys.code], error_code.METHOD_NOT_FOUND);
        expect(server.protocolVersion, negotiated);
        expect(server.initializeCalls, 1);
      },
    );

    test('answers an enveloped server/discover before initialize', () async {
      final harness = _EdgeHarness(drain: false);
      final server = TestMCPServer(harness.channel);
      addTearDown(server.shutdown);

      harness.wireIn.add(
        jsonEncode({
          Keys.jsonrpc: '2.0',
          Keys.id: 1,
          Keys.method: DiscoverRequest.methodName,
          Keys.params: {
            Keys.meta: {
              Keys.protocolVersionMeta:
                  ProtocolVersion.v2026_07_28.versionString,
              Keys.clientCapabilitiesMeta: <String, Object?>{},
            },
          },
        }),
      );
      final response = await harness.nextWireObject();
      expect(response[Keys.id], 1);
      final result = response[Keys.result] as Map<String, Object?>;
      expect(
        result[Keys.supportedVersions],
        contains(ProtocolVersion.v2026_07_28.versionString),
      );
      expect(result[Keys.resultType], ResultTypes.complete);
      expect(result[Keys.ttlMs], 0);
      expect(result[Keys.cacheScope], CacheScope.private.name);
      final meta = (result[Keys.meta] as Map).cast<String, Object?>();
      expect(meta[Keys.serverInfoMeta], {
        Keys.name: 'test server',
        Keys.version: '0.1.0',
      });
    });

    test('rejects a bare server/discover before initialize', () async {
      final harness = _EdgeHarness(drain: false);
      final server = TestMCPServer(harness.channel);
      addTearDown(server.shutdown);

      harness.wireIn.add(
        jsonEncode({
          Keys.jsonrpc: '2.0',
          Keys.id: 1,
          Keys.method: DiscoverRequest.methodName,
        }),
      );
      final error = _error(await harness.nextWireObject());
      expect(error[Keys.code], error_code.METHOD_NOT_FOUND);
    });

    test('initializes once for concurrent discovery probes', () async {
      final harness = _EdgeHarness(drain: false);
      final initializeGate = Completer<void>();
      final server = _CountingServer(
        harness.channel,
        initializeGate: initializeGate.future,
      );
      addTearDown(() async {
        if (!initializeGate.isCompleted) initializeGate.complete();
        await server.shutdown();
      });

      Map<String, Object?> discoverMessage(int id) => {
        Keys.jsonrpc: '2.0',
        Keys.id: id,
        Keys.method: DiscoverRequest.methodName,
        Keys.params: {
          Keys.meta: {
            Keys.protocolVersionMeta: ProtocolVersion.v2026_07_28.versionString,
            Keys.clientCapabilitiesMeta: <String, Object?>{},
          },
        },
      };

      harness.wireIn.add(jsonEncode(discoverMessage(1)));
      await pumpEventQueue(times: 20);
      expect(server.initializeCalls, 1);
      harness.wireIn.add(jsonEncode(discoverMessage(2)));
      final rejected = await harness.nextWireObject();
      expect(rejected[Keys.id], 2);
      expect(_error(rejected)[Keys.code], error_code.METHOD_NOT_FOUND);
      expect(server.initializeCalls, 1);

      initializeGate.complete();
      final discovered = await harness.nextWireObject();
      expect(discovered[Keys.id], 1);
      expect(discovered.containsKey(Keys.result), isTrue);
      expect(server.initializeCalls, 1);
    });

    test('serves an acknowledgement before the 2026 listen result', () async {
      final harness = _EdgeHarness(drain: false);
      final server = _SubscriptionServer(harness.channel);
      addTearDown(server.shutdown);

      harness.wireIn.add(
        jsonEncode({
          Keys.jsonrpc: '2.0',
          Keys.id: 1,
          Keys.method: DiscoverRequest.methodName,
          Keys.params: {
            Keys.meta: {
              Keys.protocolVersionMeta:
                  ProtocolVersion.v2026_07_28.versionString,
              Keys.clientCapabilitiesMeta: <String, Object?>{},
            },
          },
        }),
      );
      final discover = await harness.nextWireObject();
      expect(discover[Keys.id], 1);
      expect(discover.containsKey(Keys.result), isTrue);

      harness.wireIn.add(
        jsonEncode({
          Keys.jsonrpc: '2.0',
          Keys.id: 2,
          Keys.method: SubscriptionsListenRequest.methodName,
          Keys.params: {Keys.notifications: <String, Object?>{}},
        }),
      );
      final acknowledgement = await harness.nextWireObject();
      expect(
        acknowledgement[Keys.method],
        SubscriptionsAcknowledgedNotification.methodName,
      );
      final acknowledgementMeta =
          ((acknowledgement[Keys.params] as Map)[Keys.meta] as Map)
              .cast<String, Object?>();
      expect(acknowledgementMeta[Keys.subscriptionIdMeta], 2);

      await server.shutdown();
      final response = await harness.nextWireObject();
      expect(response[Keys.id], 2);
      final result = (response[Keys.result] as Map).cast<String, Object?>();
      final resultMeta = (result[Keys.meta] as Map).cast<String, Object?>();
      expect(resultMeta[Keys.subscriptionIdMeta], 2);
      expect(resultMeta[Keys.serverInfoMeta], {
        Keys.name: 'test server',
        Keys.version: '0.1.0',
      });
      expect(result[Keys.resultType], ResultTypes.complete);
    });
  });
}

base class _CountingServer extends MCPServer {
  _CountingServer(super.channel, {this.initializeGate})
    : super.fromStreamChannel(
        implementation: Implementation(name: 'test server', version: '0.1.0'),
      );

  final Future<void>? initializeGate;
  int initializeCalls = 0;

  @override
  Future<void> initialize(MCPServerInitialization initialization) async {
    initializeCalls++;
    if (initializeGate case final gate?) await gate;
    await super.initialize(initialization);
  }
}

base class _SubscriptionServer extends MCPServer with SubscriptionsSupport {
  _SubscriptionServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'test server', version: '0.1.0'),
      );
}

/// A [jsonRpcChannel] over an in-memory pair of string controllers.
///
/// The decoded messages are collected into [received] unless `drain` is
/// false, in which case the caller owns the stream (for example by handing
/// [channel] to a server). Wire output is read through [wire] or
/// [nextWireObject].
final class _EdgeHarness {
  _EdgeHarness({bool drain = true}) {
    addTearDown(close);
    if (drain) channel.stream.listen(received.add);
  }

  final wireIn = StreamController<String>();
  final wireOut = StreamController<String>();
  final received = <Map<String, Object?>>[];

  late final channel = jsonRpcChannel(
    StreamChannel.withCloseGuarantee(wireIn.stream, wireOut.sink),
  );

  late final wire = StreamQueue(wireOut.stream);

  /// Reads the next wire frame and decodes it as a JSON object.
  Future<Map<String, Object?>> nextWireObject() async =>
      (jsonDecode(await wire.next) as Map).cast<String, Object?>();

  void close() {
    unawaited(wireIn.close());
    unawaited(wireOut.close());
    unawaited(wire.cancel(immediate: true));
  }
}

Map<String, Object?> _error(Object? response) =>
    ((response as Map)[Keys.error] as Map).cast<String, Object?>();
