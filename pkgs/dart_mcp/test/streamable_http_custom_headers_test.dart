// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Tests for the `Mcp-Param-{Name}` header validation of
/// `handleStreamableHttpRequest`: the custom-header half of the 2026-07-28
/// revision's header mirroring, where a tool schema designates parameters
/// with `x-mcp-header` annotations and the server checks the headers a
/// request carries against its body arguments.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:dart_mcp/streamable_http.dart';
import 'package:test/test.dart';

/// The protocol version this transport speaks.
const version = '2026-07-28';

const callTool = CallToolRequest.methodName;

/// `"Hello"` in the base64 sentinel encoding.
const encodedHello = '=?base64?SGVsbG8=?=';

/// The headers every POST carries, whatever its body is.
const transportHeaders = {
  'Content-Type': 'application/json',
  'Accept': 'application/json, text/event-stream',
};

void main() {
  late HttpServer httpServer;
  late Uri uri;

  setUp(() async {
    httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.http('${httpServer.address.host}:${httpServer.port}', '/mcp');
    httpServer.listen(
      (request) =>
          handleStreamableHttpRequest(request, _AnnotatedToolServer.new),
    );
    addTearDown(() => httpServer.close(force: true));
  });

  /// A `tools/call` body for [tool] carrying the standard envelope.
  Map<String, Object?> body(String tool, {Map<String, Object?>? arguments}) => {
    Keys.jsonrpc: '2.0',
    Keys.id: 1,
    Keys.method: callTool,
    Keys.params: {
      Keys.name: tool,
      if (arguments != null) Keys.arguments: arguments,
      Keys.meta: {
        Keys.protocolVersionMeta: version,
        Keys.clientCapabilitiesMeta: <String, Object?>{},
      },
    },
  };

  /// The transport and mirrored headers for a `tools/call` of [tool].
  Map<String, String> headers(String tool) => {
    ...transportHeaders,
    'Mcp-Protocol-Version': version,
    'Mcp-Method': callTool,
    'Mcp-Name': tool,
  };

  Future<(int, String)> post(Map<String, String> headers, Object? json) async {
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.openUrl('POST', uri);
    headers.forEach(request.headers.set);
    request.write(jsonEncode(json));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (response.statusCode, text);
  }

  Map<String, Object?> decode(String text) =>
      jsonDecode(text) as Map<String, Object?>;

  Object? errorCode(String text) =>
      (decode(text)[Keys.error] as Map<String, Object?>?)?[Keys.code];

  /// The text content of a successful `tools/call` response.
  Object? resultText(String text) {
    final result = decode(text)[Keys.result] as Map<String, Object?>;
    final content = result[Keys.content] as List;
    return (content.single as Map<String, Object?>)[Keys.text];
  }

  /// Sends [payload] over a raw socket and returns the raw response text.
  ///
  /// [HttpClient] folds repeated header lines into one comma separated
  /// value, so the duplicated-header test has to go over a socket. The
  /// payload must ask for `Connection: close` or the read below never
  /// finishes.
  Future<String> rawRequest(String payload) async {
    final socket = await Socket.connect(httpServer.address, httpServer.port);
    socket.write(payload);
    await socket.flush();
    final response = utf8.decode(
      await socket.fold(<int>[], (bytes, chunk) => bytes..addAll(chunk)),
    );
    socket.destroy();
    return response;
  }

  group('accepts', () {
    test('a header matching its body argument', () async {
      final (status, text) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': 'us-west1',
      }, body('greet', arguments: {'region': 'us-west1'}));
      expect(status, 200);
      expect(resultText(text), 'us-west1');
    });

    test('a base64 sentinel decoding to the body argument', () async {
      final (status, text) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': encodedHello,
      }, body('greet', arguments: {'region': 'Hello'}));
      expect(status, 200);
      expect(resultText(text), 'Hello');
    });

    test('a sentinel of the empty string', () async {
      final (status, _) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': '=?base64??=',
      }, body('greet', arguments: {'region': ''}));
      expect(status, 200);
    });

    test('a value without the sentinel prefix as a literal', () async {
      // The base64 of `Hello` with no `=?base64?` prefix mirrors a body
      // argument which is that very string.
      final (status, _) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': 'SGVsbG8=',
      }, body('greet', arguments: {'region': 'SGVsbG8='}));
      expect(status, 200);
    });

    test('a value without the sentinel suffix as a literal', () async {
      final (status, _) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': '=?base64?SGVsbG8=',
      }, body('greet', arguments: {'region': '=?base64?SGVsbG8='}));
      expect(status, 200);
    });

    test('an omitted header when the argument is omitted', () async {
      final (status, _) = await post(
        headers('greet'),
        body('greet', arguments: {}),
      );
      expect(status, 200);
    });

    test('an omitted header when the argument is null', () async {
      final (status, _) = await post(
        headers('greet'),
        body('greet', arguments: {'region': null}),
      );
      expect(status, 200);
    });

    test('a lowercase header name', () async {
      final (status, _) = await post({
        ...headers('greet'),
        'mcp-param-region': 'us-west1',
      }, body('greet', arguments: {'region': 'us-west1'}));
      expect(status, 200);
    });

    test('an integer header for a double body value', () async {
      // The specification asks for a numeric comparison, so `42` and `42.0`
      // agree in either direction.
      final (status, _) = await post({
        ...headers('count'),
        'Mcp-Param-Count': '42',
      }, body('count', arguments: {'count': 42.5 - 0.5}));
      expect(status, 200);
      final (status2, _) = await post({
        ...headers('count'),
        'Mcp-Param-Count': '42.0',
      }, body('count', arguments: {'count': 42}));
      expect(status2, 200);
    });

    test('a boolean rendered in lowercase', () async {
      final (status, _) = await post({
        ...headers('flag'),
        'Mcp-Param-Flag': 'true',
      }, body('flag', arguments: {'flag': true}));
      expect(status, 200);
    });

    test('a nested annotated parameter', () async {
      final (status, _) = await post(
        {...headers('nested'), 'Mcp-Param-Depth': 'deep'},
        body(
          'nested',
          arguments: {
            'outer': {'inner': 'deep'},
          },
        ),
      );
      expect(status, 200);
    });

    test('anything on a tool whose annotations are invalid', () async {
      // Two annotations differing only in case are not case-insensitively
      // unique, which invalidates the whole tool definition: a conforming
      // client drops the tool and mirrors nothing, so nothing is checked.
      final (status, _) = await post({
        ...headers('invalid'),
        'Mcp-Param-Region': 'mismatched',
      }, body('invalid', arguments: {'a': 'value', 'b': 'other'}));
      expect(status, 200);
    });

    test('anything on a tool annotated under a composition keyword', () async {
      final (status, _) = await post({
        ...headers('composed'),
        'Mcp-Param-Choice': 'mismatched',
      }, body('composed', arguments: {'choice': 'value'}));
      expect(status, 200);
    });

    test('an unrecognized Mcp-Param header', () async {
      // No annotation names `Other`, so nothing recognizes that header and
      // nothing compares it.
      final (status, _) = await post({
        ...headers('greet'),
        'Mcp-Param-Other': 'anything',
      }, body('greet', arguments: {'region': 'us-west1'}));
      expect(status, 400);
      // The `region` argument still requires its own header.
      final (status2, _) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': 'us-west1',
        'Mcp-Param-Other': 'anything',
      }, body('greet', arguments: {'region': 'us-west1'}));
      expect(status2, 200);
    });

    test('a call of a tool the server does not have', () async {
      // Validation reads schemas off the registry, so a name which is not
      // there leaves nothing to check and the dispatched server answers.
      final (status, text) = await post({
        ...headers('no-such-tool'),
        'Mcp-Param-Region': 'anything',
      }, body('no-such-tool', arguments: {'region': 'other'}));
      expect(status, 200);
      final result = decode(text)[Keys.result] as Map<String, Object?>;
      expect(result[Keys.isError], true);
    });
  });

  group('rejects with 400 and HeaderMismatch', () {
    test('a sentinel with invalid base64 padding', () async {
      final (status, text) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': '=?base64?SGVsbG8?=',
      }, body('greet', arguments: {'region': 'Hello'}));
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('a malformed sentinel even when the body carries the same '
        'literal', () async {
      // A malformed sentinel is invalid characters in a recognized header,
      // not a literal which happens to match: the value claims an encoding,
      // so it is rejected before any comparison.
      final (status, text) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': '=?base64?SGVsbG8?=',
      }, body('greet', arguments: {'region': '=?base64?SGVsbG8?='}));
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('a sentinel with invalid base64 characters', () async {
      final (status, text) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': '=?base64?SGVs!!!bG8=?=',
      }, body('greet', arguments: {'region': 'Hello'}));
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('a header which does not match its argument', () async {
      final (status, text) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': 'us-east1',
      }, body('greet', arguments: {'region': 'us-west1'}));
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('an omitted header when the body carries the argument', () async {
      final (status, text) = await post(
        headers('greet'),
        body('greet', arguments: {'region': 'us-west1'}),
      );
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('a header for an argument the body does not carry', () async {
      final (status, text) = await post({
        ...headers('greet'),
        'Mcp-Param-Region': 'us-west1',
      }, body('greet', arguments: {}));
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('a boolean of the wrong case', () async {
      // Header values are case sensitive and the encoding renders booleans
      // in lowercase.
      final (status, text) = await post({
        ...headers('flag'),
        'Mcp-Param-Flag': 'True',
      }, body('flag', arguments: {'flag': true}));
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('an integer in a form the encoding rules do not produce', () async {
      final (status, text) = await post({
        ...headers('count'),
        'Mcp-Param-Count': '4e1',
      }, body('count', arguments: {'count': 40}));
      expect(status, 400);
      expect(errorCode(text), McpErrorCodes.headerMismatch);
    });

    test('a recognized header sent more than once', () async {
      final requestBody = jsonEncode(
        body('greet', arguments: {'region': 'us-west1'}),
      );
      final response = await rawRequest(
        'POST /mcp HTTP/1.1\r\n'
        'Host: ${httpServer.address.host}:${httpServer.port}\r\n'
        'Content-Type: application/json\r\n'
        'Accept: application/json, text/event-stream\r\n'
        'Mcp-Protocol-Version: $version\r\n'
        'Mcp-Method: $callTool\r\n'
        'Mcp-Name: greet\r\n'
        'Mcp-Param-Region: us-west1\r\n'
        'Mcp-Param-Region: us-east1\r\n'
        'Content-Length: ${requestBody.length}\r\n'
        'Connection: close\r\n'
        '\r\n'
        '$requestBody',
      );
      expect(response, startsWith('HTTP/1.1 400'));
      final json = response.substring(
        response.indexOf('{'),
        response.lastIndexOf('}') + 1,
      );
      expect(errorCode(json), McpErrorCodes.headerMismatch);
    });
  });

  test('a server without ToolsSupport recognizes no headers', () async {
    final bare = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => bare.close(force: true));
    bare.listen(
      (request) => handleStreamableHttpRequest(request, _BareServer.new),
    );
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.openUrl(
      'POST',
      Uri.http('${bare.address.host}:${bare.port}', '/mcp'),
    );
    final requestHeaders = {
      ...headers('greet'),
      'Mcp-Param-Region': 'mismatched',
    };
    requestHeaders.forEach(request.headers.set);
    request.write(jsonEncode(body('greet', arguments: {'region': 'other'})));
    final response = await request.close();
    // There is no registry to recognize the header against, so the request
    // reaches dispatch, where no tools/call handler exists either.
    final text = await utf8.decodeStream(response);
    expect(response.statusCode, isNot(400));
    expect(errorCode(text), isNot(McpErrorCodes.headerMismatch));
  });
}

/// A server whose tools cover the annotation shapes the tests probe.
base class _AnnotatedToolServer extends MCPServer with ToolsSupport {
  _AnnotatedToolServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'annotated tool server',
          version: '0.1.0',
        ),
      ) {
    registerTool(
      Tool(
        name: 'greet',
        inputSchema: ObjectSchema.fromMap({
          Keys.type: JsonType.object.typeName,
          Keys.properties: {
            'region': {
              Keys.type: JsonType.string.typeName,
              'x-mcp-header': 'Region',
            },
          },
        }),
      ),
      (request) => CallToolResult(
        content: [TextContent(text: '${request.arguments?['region']}')],
      ),
    );
    registerTool(
      Tool(
        name: 'count',
        inputSchema: ObjectSchema.fromMap({
          Keys.type: JsonType.object.typeName,
          Keys.properties: {
            'count': {
              Keys.type: JsonType.int.typeName,
              'x-mcp-header': 'Count',
            },
          },
        }),
      ),
      (_) => CallToolResult(content: [TextContent(text: 'counted')]),
    );
    registerTool(
      Tool(
        name: 'flag',
        inputSchema: ObjectSchema.fromMap({
          Keys.type: JsonType.object.typeName,
          Keys.properties: {
            'flag': {Keys.type: JsonType.bool.typeName, 'x-mcp-header': 'Flag'},
          },
        }),
      ),
      (_) => CallToolResult(content: [TextContent(text: 'flagged')]),
    );
    registerTool(
      Tool(
        name: 'nested',
        inputSchema: ObjectSchema.fromMap({
          Keys.type: JsonType.object.typeName,
          Keys.properties: {
            'outer': {
              Keys.type: JsonType.object.typeName,
              Keys.properties: {
                'inner': {
                  Keys.type: JsonType.string.typeName,
                  'x-mcp-header': 'Depth',
                },
              },
            },
          },
        }),
      ),
      (_) => CallToolResult(content: [TextContent(text: 'nested')]),
    );
    registerTool(
      Tool(
        name: 'invalid',
        inputSchema: ObjectSchema.fromMap({
          Keys.type: JsonType.object.typeName,
          Keys.properties: {
            'a': {
              Keys.type: JsonType.string.typeName,
              'x-mcp-header': 'Region',
            },
            'b': {
              Keys.type: JsonType.string.typeName,
              'x-mcp-header': 'region',
            },
          },
        }),
      ),
      (_) => CallToolResult(content: [TextContent(text: 'invalid')]),
    );
    registerTool(
      Tool(
        name: 'composed',
        inputSchema: ObjectSchema.fromMap({
          Keys.type: JsonType.object.typeName,
          Keys.properties: {
            'choice': {
              'oneOf': [
                {Keys.type: JsonType.string.typeName, 'x-mcp-header': 'Choice'},
              ],
            },
          },
        }),
      ),
      (_) => CallToolResult(content: [TextContent(text: 'composed')]),
    );
  }
}

/// A server with no [ToolsSupport], so no registry to read schemas from.
base class _BareServer extends MCPServer {
  _BareServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'bare server', version: '0.1.0'),
      );
}
