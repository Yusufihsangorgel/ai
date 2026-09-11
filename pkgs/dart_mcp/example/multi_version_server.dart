// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A server that serves one tool to clients on the 2026-07-28 revision and to
/// clients on the revisions before it, from one [MCPServer] subclass.
///
/// Run `dart run example/multi_version_server.dart` for stdio, where the older
/// revisions are: [ProtocolVersion.latestSupported] on a connected transport
/// is 2025-11-25. Add `--http` and the same class is served over Streamable
/// HTTP, the transport 2026-07-28 added, and it prints two `curl` commands
/// that drive it.
///
/// [MCPServerWithInputRequired] is written once, for 2026-07-28: a tool that
/// needs something from the user answers with an [InputRequiredResult] and
/// reads the answer back out of the call it gets again. On stdio this package
/// sends that request as the `elicitation/create` an older revision has and
/// reruns the handler with the answer under the same key. The handler never
/// reads [MCPServer.protocolVersion].
library;

import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:dart_mcp/streamable_http.dart';

void main(List<String> args) async {
  if (args.contains('--http')) return _serveStreamableHttp();
  // One long-lived server for the one connection stdio has.
  MCPServerWithInputRequired(stdioChannel(input: io.stdin, output: io.stdout));
}

/// Serves [MCPServerWithInputRequired] over Streamable HTTP on a free port.
///
/// `example/streamable_http_server.dart` is the example for this transport and
/// explains the host's part of it. The path and `Origin` checks are the same,
/// and the handler leaves both to its embedder.
Future<void> _serveStreamableHttp() async {
  const path = '/mcp';
  final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
  final endpoint = 'http://${server.address.host}:${server.port}$path';

  server.listen((request) async {
    final wrongPath = request.uri.path != path;
    if (wrongPath || request.headers['origin'] != null) {
      request.response
        ..statusCode =
            wrongPath ? io.HttpStatus.notFound : io.HttpStatus.forbidden
        ..contentLength = 0;
      await request.response.close();
      return;
    }
    try {
      // Every POST gets its own server. The tool keeps nothing between its
      // two calls; the second one carries the answer.
      await handleStreamableHttpRequest(
        request,
        MCPServerWithInputRequired.new,
      );
    } catch (error) {
      io.stderr.writeln('request failed: $error');
    }
  });

  print('''
Listening on $endpoint

# `greet` asks who to greet. This first call answers `input_required`.
${_callGreet(endpoint, '')}
# The client answers and calls again, under the key the result asked on. A
# stdio client is asked for the same thing as an `elicitation/create` request.
${_callGreet(endpoint, '\n      "inputResponses": {"name": $_accepted},')}''');
}

/// An accepted form elicitation, as a client sends one back.
const _accepted = '{"action": "accept", "content": {"name": "world"}}';

/// The `curl` command calling `greet` on [endpoint] with [inputResponses].
///
/// The `_meta` envelope replaces the `initialize` handshake on this revision,
/// and the capabilities it carries have to cover what the tool asks for.
String _callGreet(String endpoint, String inputResponses) => '''
curl -sS $endpoint \\
  -H 'Content-Type: application/json' \\
  -H 'Accept: application/json, text/event-stream' \\
  -H 'MCP-Protocol-Version: 2026-07-28' \\
  -H 'Mcp-Method: tools/call' -H 'Mcp-Name: greet' \\
  -d '{
    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
    "params": {
      "name": "greet",$inputResponses
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "curl", "version": "0"},
        "io.modelcontextprotocol/clientCapabilities": {"elicitation": {}}
      }
    }
  }'
''';

/// A server with one tool that needs a value from the user before it can
/// answer.
base class MCPServerWithInputRequired extends MCPServer with ToolsSupport {
  MCPServerWithInputRequired(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'An example dart server which serves several revisions',
          version: '0.1.0',
        ),
        instructions: 'Call `greet` and answer what it asks for',
      ) {
    registerTool(greetTool, _greet);
  }

  /// A tool that greets a name it asks the client to collect.
  final greetTool = Tool(
    name: 'greet',
    description: 'greets a name it asks the client to collect',
    inputSchema: Schema.object(),
  );

  /// The implementation of the `greet` tool, asking for a name on the first
  /// call and greeting the answer the second call carries.
  CallToolResponse _greet(CallToolRequest request) {
    if (request.elicitResponse('name') case final answer?) {
      // `decline` and `cancel` both leave the tool without a name.
      final accepted = answer.action == ElicitationAction.accept;
      final name = accepted ? answer.content!['name'] : null;
      return CallToolResult(
        content: [
          Content.text(text: accepted ? 'Hello, $name!' : 'Nothing to greet.'),
        ],
        isError: !accepted,
      );
    }
    final askForAName = ElicitRequest.form(
      message: 'Who should I greet?',
      requestedSchema: Schema.object(
        properties: {'name': Schema.string()},
        required: ['name'],
      ),
    );
    return InputRequiredResult(
      inputRequests: {'name': InputRequest.elicit(askForAName)},
    );
  }
}
