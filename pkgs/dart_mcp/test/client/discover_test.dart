// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  group('ServerConnection.discover', () {
    test('sends the metadata the 2026-07-28 revision requires', () async {
      final harness = _WireHarness();
      harness.respondToNextRequest({
        Keys.resultType: ResultTypes.complete,
        Keys.supportedVersions: ['2026-07-28'],
        Keys.capabilities: {Keys.tools: <String, Object?>{}},
        Keys.ttlMs: 3600000,
        Keys.cacheScope: CacheScope.public.name,
        Keys.meta: {
          Keys.serverInfoMeta: {
            Keys.name: 'test server',
            Keys.version: '2.0.0',
          },
        },
      });

      final result = await harness.connection.discover(
        protocolVersion: ProtocolVersion.v2026_07_28,
        capabilities: ClientCapabilities(
          elicitation: ElicitationCapability(form: {}),
        ),
        clientInfo: Implementation(name: 'test client', version: '0.1.0'),
      );

      final request = harness.requests.single;
      expect(request[Keys.method], DiscoverRequest.methodName);
      final meta =
          (request[Keys.params] as Map)[Keys.meta] as Map<String, Object?>;
      expect(meta[Keys.protocolVersionMeta], '2026-07-28');
      expect(meta[Keys.clientInfoMeta], {
        Keys.name: 'test client',
        Keys.version: '0.1.0',
      });
      expect(meta[Keys.clientCapabilitiesMeta], {
        Keys.elicitation: {Keys.form: <String, Object?>{}},
      });

      expect(result.supportedVersions, ['2026-07-28']);
      expect(result.capabilities.tools, isNotNull);
      expect(result.ttlMs, 3600000);
      expect(result.cacheScope, CacheScope.public);
      expect(result.serverInfo?.name, 'test server');
      expect(result.serverInfo?.version, '2.0.0');
    });

    test('leaves clientInfo out when it is not given', () async {
      final harness = _WireHarness();
      harness.respondToNextRequest({
        Keys.resultType: ResultTypes.complete,
        Keys.supportedVersions: ['2026-07-28'],
        Keys.capabilities: <String, Object?>{},
      });

      final result = await harness.connection.discover(
        protocolVersion: ProtocolVersion.v2026_07_28,
        capabilities: ClientCapabilities(),
      );

      final meta =
          (harness.requests.single[Keys.params] as Map)[Keys.meta]
              as Map<String, Object?>;
      expect(meta, isNot(contains(Keys.clientInfoMeta)));
      expect(meta[Keys.protocolVersionMeta], '2026-07-28');
      expect(meta[Keys.clientCapabilitiesMeta], isEmpty);

      expect(result.serverInfo, isNull);
    });

    test('passes caller metadata through and owns the reserved keys', () async {
      final harness = _WireHarness();
      harness.respondToNextRequest({
        Keys.resultType: ResultTypes.complete,
        Keys.supportedVersions: ['2026-07-28'],
        Keys.capabilities: <String, Object?>{},
      });

      await harness.connection.discover(
        protocolVersion: ProtocolVersion.v2026_07_28,
        capabilities: ClientCapabilities(),
        meta: MetaWithProgressToken.fromMap({
          Keys.progressToken: 'token-1',
          'example.com/custom': 'kept',
          // A caller cannot weaken the envelope through the passthrough.
          Keys.protocolVersionMeta: '1900-01-01',
        }),
      );

      final meta =
          (harness.requests.single[Keys.params] as Map)[Keys.meta]
              as Map<String, Object?>;
      expect(meta[Keys.progressToken], 'token-1');
      expect(meta['example.com/custom'], 'kept');
      expect(meta[Keys.protocolVersionMeta], '2026-07-28');
    });
  });
}

/// A client whose peer is this test: requests surface in [requests] and are
/// answered with whatever [respondToNextRequest] queued, exercising the wire
/// format instead of this package's server implementation.
class _WireHarness {
  final incoming = StreamController<Map<String, Object?>>();
  final outgoing = StreamController<Map<String, Object?>>();
  final requests = <Map<String, Object?>>[];
  final _responses = <Map<String, Object?>>[];

  late final ServerConnection connection;

  _WireHarness() {
    final client = TestMCPClient();
    addTearDown(client.shutdown);
    connection = client.connectServer(
      StreamChannel.withGuarantees(incoming.stream, outgoing.sink),
    );
    outgoing.stream.listen((request) {
      requests.add(request);
      incoming.add({
        Keys.jsonrpc: '2.0',
        Keys.id: request[Keys.id],
        Keys.result: _responses.removeAt(0),
      });
    });
  }

  /// Queues [result] as the response to the next request.
  void respondToNextRequest(Map<String, Object?> result) =>
      _responses.add(result);
}
