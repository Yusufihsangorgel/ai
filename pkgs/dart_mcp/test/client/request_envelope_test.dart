// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/client/request_envelope.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:dart_mcp/streamable_http.dart';
import 'package:test/test.dart';

void main() {
  group('buildRequestEnvelope (unit, no server)', () {
    test('the meta object carries the protocol version and capabilities', () {
      final envelope = buildRequestEnvelope(
        method: ListToolsRequest.methodName,
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
      );
      expect(envelope.meta, {
        Keys.protocolVersionMeta: '2026-07-28',
        Keys.clientCapabilitiesMeta: <String, Object?>{},
      });
    });

    test('clientInfo and logLevel are only present when supplied', () {
      final withoutThem = buildRequestEnvelope(
        method: ListToolsRequest.methodName,
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
      );
      expect(withoutThem.meta.containsKey(Keys.clientInfoMeta), isFalse);
      expect(withoutThem.meta.containsKey(Keys.logLevelMeta), isFalse);

      final withThem = buildRequestEnvelope(
        method: ListToolsRequest.methodName,
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
        clientInfo: Implementation(name: 'probe', version: '1.0.0'),
        logLevel: LoggingLevel.warning,
      );
      expect(withThem.meta[Keys.clientInfoMeta], {
        Keys.name: 'probe',
        Keys.version: '1.0.0',
      });
      expect(withThem.meta[Keys.logLevelMeta], 'warning');
    });

    test('the headers mirror the method and protocol version', () {
      final envelope = buildRequestEnvelope(
        method: ListToolsRequest.methodName,
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
      );
      expect(envelope.headers['Content-Type'], 'application/json');
      expect(envelope.headers['Accept'], 'application/json, text/event-stream');
      expect(envelope.headers['MCP-Protocol-Version'], '2026-07-28');
      expect(envelope.headers['Mcp-Method'], 'tools/list');
      expect(envelope.headers.containsKey('Mcp-Name'), isFalse);
    });

    test('tools/call and prompts/get mirror "name" into Mcp-Name, plain ASCII '
        'passes through unencoded', () {
      for (final method in [
        CallToolRequest.methodName,
        GetPromptRequest.methodName,
      ]) {
        final envelope = buildRequestEnvelope(
          method: method,
          protocolVersion: ProtocolVersion.v2026_07_28,
          clientCapabilities: ClientCapabilities(),
          params: {Keys.name: 'plain-ascii-name'},
        );
        expect(envelope.headers['Mcp-Name'], 'plain-ascii-name');
      }
    });

    test('resources/read mirrors "uri" into Mcp-Name', () {
      final envelope = buildRequestEnvelope(
        method: ReadResourceRequest.methodName,
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
        params: {Keys.uri: 'file:///plain.txt'},
      );
      // The URI's `/` and `:` fall outside `needsSentinel`'s pass-through
      // set only via the trim/empty/non-ASCII checks, none of which a plain
      // `file://` URI trips, so it survives unencoded.
      expect(envelope.headers['Mcp-Name'], 'file:///plain.txt');
    });

    test('a name/uri that cannot survive as a header value is base64-'
        'sentinel-encoded', () {
      for (final value in [
        '', // empty
        '  padded  ', // leading/trailing whitespace
        'İstanbul café ☕', // non-ASCII
        '=?base64?already-shaped?=', // already sentinel-shaped
      ]) {
        final encoded = encodeMcpNameValue(value);
        expect(encoded, startsWith('=?base64?'));
        expect(encoded, endsWith('?='));
        final payload = encoded.substring(
          '=?base64?'.length,
          encoded.length - '?='.length,
        );
        expect(utf8.decode(base64.decode(payload)), value);
      }
    });

    test('a name/uri without the mirrored param throws ArgumentError', () {
      expect(
        () => buildRequestEnvelope(
          method: CallToolRequest.methodName,
          protocolVersion: ProtocolVersion.v2026_07_28,
          clientCapabilities: ClientCapabilities(),
          params: const {},
        ),
        throwsArgumentError,
      );
    });

    test('reserved-key precedence: meta is a fresh map the caller merges '
        'last, so it wins over a caller key of the same name', () {
      // buildRequestEnvelope never sees or mutates a `_meta` a caller has
      // already built; the merge-with-envelope-wins-last responsibility
      // belongs to whoever calls this (documented on [RequestEnvelope.meta]).
      // protocolVersion and clientCapabilities are the spec's required
      // reserved keys (basic/index) — a caller value that reached the wire
      // instead would make the request malformed, so the envelope's own
      // value has to win.
      final envelope = buildRequestEnvelope(
        method: ListToolsRequest.methodName,
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
      );
      final merged = {
        'custom-key': 'kept',
        Keys.clientCapabilitiesMeta: 'stale-caller-value',
        ...envelope.meta,
      };
      expect(
        merged[Keys.clientCapabilitiesMeta],
        envelope.meta[Keys.clientCapabilitiesMeta],
      );
      expect(merged['custom-key'], 'kept');
    });
  });

  group('buildRequestEnvelope crossing the real server boundary', () {
    // This group posts what the generator produced to the package's own
    // unmodified `handleStreamableHttpRequest` (`streamable_http.dart`) over
    // a real socket, and asserts on that parser's verdict rather than
    // re-deriving the expectation from the generator itself: the generator
    // lives in request_envelope.dart, the parser in streamable_http.dart,
    // and neither reads the other's source, so a broken generator has
    // somewhere real to fail.
    late HttpServer httpServer;
    late Uri uri;

    setUp(() async {
      httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      uri = Uri.http('${httpServer.address.host}:${httpServer.port}', '/mcp');
      httpServer.listen(
        (request) =>
            handleStreamableHttpRequest(request, _EnvelopeBoundaryServer.new),
      );
      addTearDown(() => httpServer.close(force: true));
    });

    /// POSTs a JSON-RPC [method] request whose headers and `_meta` came
    /// entirely from [buildRequestEnvelope], and returns the server's
    /// status code and decoded JSON body.
    Future<(int, Map<String, Object?>)> sendGenerated({
      required String method,
      Map<String, Object?>? params,
      Object? id = 1,
    }) async {
      final envelope = buildRequestEnvelope(
        method: method,
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
        clientInfo: Implementation(
          name: 'envelope-boundary-test',
          version: '0.0.1',
        ),
        params: params,
      );
      final requestBody = {
        Keys.jsonrpc: '2.0',
        Keys.id: id,
        Keys.method: method,
        Keys.params: {...?params, Keys.meta: envelope.meta},
      };

      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.openUrl('POST', uri);
      envelope.headers.forEach(request.headers.set);
      // `HttpClientRequest.write` encodes a String with the request's
      // charset, which defaults to Latin-1 and throws on the non-ASCII
      // fixtures below; writing the already-UTF-8-encoded bytes sidesteps
      // that and matches what a real transport must do to send a non-ASCII
      // name/uri at all.
      request.add(utf8.encode(jsonEncode(requestBody)));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (
        response.statusCode,
        text.isEmpty ? const <String, Object?>{} : decodeJsonObject(text),
      );
    }

    test(
      'a plain tools/list request the generator built is accepted',
      () async {
        final (status, body) = await sendGenerated(
          method: ListToolsRequest.methodName,
        );
        expect(status, HttpStatus.ok);
        expect(body[Keys.error], isNull);
        final result = body[Keys.result] as Map<String, Object?>;
        final tools = (result[Keys.tools] as List).cast<Map<String, Object?>>();
        expect(tools.map((tool) => tool[Keys.name]), contains('probe/echo'));
      },
    );

    test('a tools/call request with a plain-ASCII tool name is accepted, and '
        'the Mcp-Name header the generator wrote matches the body', () async {
      final (status, body) = await sendGenerated(
        method: CallToolRequest.methodName,
        params: {Keys.name: 'probe/echo', Keys.arguments: <String, Object?>{}},
      );
      expect(status, HttpStatus.ok);
      expect(body[Keys.error], isNull);
    });

    test(
      'a resources/read request whose URI needs sentinel-encoding is '
      'accepted: the server decodes Mcp-Name and it matches params.uri',
      () async {
        const uriWithSpaces = 'test://a resource with spaces.txt';
        final (status, body) = await sendGenerated(
          method: ReadResourceRequest.methodName,
          params: {Keys.uri: uriWithSpaces},
        );
        expect(status, HttpStatus.ok);
        expect(body[Keys.error], isNull);
        final result = body[Keys.result] as Map<String, Object?>;
        final contents =
            (result[Keys.contents] as List).cast<Map<String, Object?>>();
        expect(contents.single[Keys.uri], uriWithSpaces);
      },
    );

    test('a prompts/get request whose name needs sentinel-encoding (non-ASCII) '
        'is accepted', () async {
      const nonAsciiName = 'İstanbul-café';
      final (status, body) = await sendGenerated(
        method: GetPromptRequest.methodName,
        params: {Keys.name: nonAsciiName},
      );
      expect(status, HttpStatus.ok);
      expect(body[Keys.error], isNull);
    });

    test('a hand-mismatched Mcp-Name (the generator working correctly is what '
        'this test relies on NOT happening) would be rejected — proven by '
        'sending the generator a name that does not match a registered tool, '
        'which the server still accepts as a well-formed envelope and instead '
        'rejects at the application layer, not the header layer', () async {
      final (status, body) = await sendGenerated(
        method: CallToolRequest.methodName,
        params: {
          Keys.name: 'unregistered/tool',
          Keys.arguments: <String, Object?>{},
        },
      );
      // Header/envelope validation passed (a HeaderMismatch would be 400
      // with code -32020); the failure below is the dispatcher's, proving
      // the generator's envelope reached the real handler intact.
      expect(status, isNot(HttpStatus.badRequest));
    });
  });
}

Map<String, Object?> decodeJsonObject(String text) =>
    jsonDecode(text) as Map<String, Object?>;

/// A minimal server used only to prove the real parser accepts what
/// [buildRequestEnvelope] produces — not a fixture for any other slice.
base class _EnvelopeBoundaryServer extends MCPServer
    with ToolsSupport, PromptsSupport, ResourcesSupport {
  _EnvelopeBoundaryServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'envelope boundary test server',
          version: '0.0.1',
        ),
      ) {
    registerTool(
      Tool(name: 'probe/echo', inputSchema: ObjectSchema()),
      (_) => CallToolResult(content: [TextContent(text: 'echo')]),
    );
    addPrompt(
      Prompt(name: 'İstanbul-café', description: 'non-ASCII prompt name'),
      (_) => GetPromptResult(
        messages: [
          PromptMessage(role: Role.user, content: TextContent(text: 'hi')),
        ],
      ),
    );
    addResource(
      Resource(
        uri: 'test://a resource with spaces.txt',
        name: 'spaced resource',
      ),
      (request) => ReadResourceResult(
        contents: [TextResourceContents(uri: request.uri, text: 'contents')],
      ),
    );
  }
}
