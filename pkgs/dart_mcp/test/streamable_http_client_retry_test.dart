// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:dart_mcp/streamable_http.dart';
import 'package:test/test.dart';

const version = '2026-07-28';

void main() {
  test('retries once after 400 unsupported-protocol-version '
      'when supported lists this channel', () async {
    final wireServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => wireServer.close(force: true));
    final posts = <Map<String, Object?>>[];
    var remainingRejections = 1;
    wireServer.listen((request) async {
      final sent =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
      final params = sent[Keys.params] as Map<String, Object?>;
      final meta = params[Keys.meta] as Map<String, Object?>;
      final headerVersion = request.headers.value('MCP-Protocol-Version');
      posts.add({
        'headerVersion': headerVersion,
        'metaVersion': meta[Keys.protocolVersionMeta],
      });
      if (remainingRejections > 0) {
        remainingRejections--;
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              Keys.jsonrpc: '2.0',
              Keys.id: sent[Keys.id],
              Keys.error: {
                Keys.code: McpErrorCodes.unsupportedProtocolVersion,
                Keys.message: 'Unsupported protocol version',
                Keys.data: {
                  Keys.supported: [version],
                  Keys.requested: headerVersion,
                },
              },
            }),
          );
      } else {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              Keys.jsonrpc: '2.0',
              Keys.id: sent[Keys.id],
              Keys.result: {'value': 'retried'},
            }),
          );
      }
      await request.response.close();
    });

    final channel = streamableHttpClientChannel(
      Uri.http('${wireServer.address.host}:${wireServer.port}', '/mcp'),
      protocolVersion: ProtocolVersion.v2026_07_28,
      clientCapabilities: ClientCapabilities(),
    );
    addTearDown(() => channel.sink.close());
    final response = channel.stream.first;
    channel.sink.add({
      Keys.jsonrpc: '2.0',
      Keys.id: 70,
      Keys.method: 'test/request',
    });

    expect(await response, {
      Keys.jsonrpc: '2.0',
      Keys.id: 70,
      Keys.result: {'value': 'retried'},
    });
    expect(posts, [
      {'headerVersion': version, 'metaVersion': version},
      {'headerVersion': version, 'metaVersion': version},
    ]);
  });

  test('yields the 400 unsupported-protocol-version error when supported '
      'lists no version this channel speaks', () async {
    final wireServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => wireServer.close(force: true));
    var postCount = 0;
    final errorBody = {
      Keys.jsonrpc: '2.0',
      Keys.id: 71,
      Keys.error: {
        Keys.code: McpErrorCodes.unsupportedProtocolVersion,
        Keys.message: 'Unsupported protocol version',
        Keys.data: {
          Keys.supported: ['1900-01-01'],
          Keys.requested: version,
        },
      },
    };
    wireServer.listen((request) async {
      postCount++;
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(errorBody));
      await request.response.close();
    });

    final channel = streamableHttpClientChannel(
      Uri.http('${wireServer.address.host}:${wireServer.port}', '/mcp'),
      protocolVersion: ProtocolVersion.v2026_07_28,
      clientCapabilities: ClientCapabilities(),
    );
    addTearDown(() => channel.sink.close());
    final response = channel.stream.first;
    channel.sink.add({
      Keys.jsonrpc: '2.0',
      Keys.id: 71,
      Keys.method: 'test/request',
    });

    expect(await response, errorBody);
    expect(postCount, 1);
  });

  test('does not retry a second 400 unsupported-protocol-version on the '
      'same request', () async {
    final wireServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => wireServer.close(force: true));
    var postCount = 0;
    Map<String, Object?> errorBody(Object? id) => {
      Keys.jsonrpc: '2.0',
      Keys.id: id,
      Keys.error: {
        Keys.code: McpErrorCodes.unsupportedProtocolVersion,
        Keys.message: 'Unsupported protocol version',
        Keys.data: {
          Keys.supported: [version],
          Keys.requested: version,
        },
      },
    };
    wireServer.listen((request) async {
      postCount++;
      final sent =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(errorBody(sent[Keys.id])));
      await request.response.close();
    });

    final channel = streamableHttpClientChannel(
      Uri.http('${wireServer.address.host}:${wireServer.port}', '/mcp'),
      protocolVersion: ProtocolVersion.v2026_07_28,
      clientCapabilities: ClientCapabilities(),
    );
    addTearDown(() => channel.sink.close());
    final response = channel.stream.first;
    channel.sink.add({
      Keys.jsonrpc: '2.0',
      Keys.id: 72,
      Keys.method: 'test/request',
    });

    expect(await response, errorBody(72));
    expect(postCount, 2);
  });
}
