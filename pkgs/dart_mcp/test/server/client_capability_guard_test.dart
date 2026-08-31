// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:test/test.dart';

final class _RequestingServer extends MCPServer
    with LoggingSupport, ToolsSupport {
  _RequestingServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'test', version: '0.1.0'),
      ) {
    registerTool(Tool(name: 'test/sample', inputSchema: ObjectSchema()), (
      _,
    ) async {
      await createMessage(CreateMessageRequest(messages: [], maxTokens: 1));
      return CallToolResult(content: [TextContent(text: 'sampled')]);
    });
    registerTool(Tool(name: 'test/roots', inputSchema: ObjectSchema()), (
      _,
    ) async {
      await listRoots(ListRootsRequest());
      return CallToolResult(content: [TextContent(text: 'listed')]);
    });
  }
}

/// Calls [name] on [protocolVersion]. It defaults to a revision with the
/// requests these tools send, so a capability test reaches the capability
/// check.
Future<Map<String, Object?>?> _callTool(
  String name,
  ClientCapabilities capabilities, {
  ProtocolVersion protocolVersion = ProtocolVersion.v2025_11_25,
}) => handleRequestScopedMessage(
  {
    Keys.jsonrpc: '2.0',
    Keys.id: 1,
    Keys.method: CallToolRequest.methodName,
    Keys.params: {Keys.name: name},
  },
  MCPServerInitialization(
    protocolVersion: protocolVersion,
    clientCapabilities: capabilities,
  ),
  _RequestingServer.new,
);

void main() {
  test('a tool which samples fails with the missing capability code', () async {
    final result = await _callTool('test/sample', ClientCapabilities());

    final error = result![Keys.error] as Map<String, Object?>;
    expect(error[Keys.code], McpErrorCodes.missingRequiredClientCapability);
    // In memory the data skips the JSON round trip, so it is an untyped map.
    final data = error[Keys.data] as Map;
    expect(data[Keys.requiredCapabilities], {
      Keys.sampling: <String, Object?>{},
    });
    expect(result[Keys.result], isNull);
  });

  test(
    'a tool which lists roots fails with the missing capability code',
    () async {
      final result = await _callTool('test/roots', ClientCapabilities());

      final error = result![Keys.error] as Map<String, Object?>;
      expect(error[Keys.code], McpErrorCodes.missingRequiredClientCapability);
      final data = error[Keys.data] as Map;
      expect(data[Keys.requiredCapabilities], {
        Keys.roots: <String, Object?>{},
      });
      expect(result[Keys.result], isNull);
    },
  );

  test(
    '2026-07-28 still refuses sampling with no sampling capability',
    () async {
      final result = await _callTool(
        'test/sample',
        ClientCapabilities(),
        protocolVersion: ProtocolVersion.v2026_07_28,
      );

      final error = result![Keys.error] as Map<String, Object?>;
      expect(error[Keys.code], McpErrorCodes.missingRequiredClientCapability);
      final data = error[Keys.data] as Map;
      expect(data[Keys.requiredCapabilities], {
        Keys.sampling: <String, Object?>{},
      });
    },
  );

  test('2026-07-28 still refuses roots with no roots capability', () async {
    final result = await _callTool(
      'test/roots',
      ClientCapabilities(),
      protocolVersion: ProtocolVersion.v2026_07_28,
    );

    final error = result![Keys.error] as Map<String, Object?>;
    expect(error[Keys.code], McpErrorCodes.missingRequiredClientCapability);
    final data = error[Keys.data] as Map;
    expect(data[Keys.requiredCapabilities], {Keys.roots: <String, Object?>{}});
  });

  test('2026-07-28 asks sampling by ending the tool call with an '
      'input-required result', () async {
    final result = await _callTool(
      'test/sample',
      ClientCapabilities(sampling: {}),
      protocolVersion: ProtocolVersion.v2026_07_28,
    );

    expect(result![Keys.error], isNull);
    final value = result[Keys.result] as Map<String, Object?>;
    expect(value[Keys.resultType], 'input_required');
    final requests = value[Keys.inputRequests] as Map<String, Object?>;
    expect(requests.keys, ['0']);
    final entry = requests['0'] as Map<String, Object?>;
    expect(entry[Keys.method], CreateMessageRequest.methodName);
  });

  test('2026-07-28 asks roots by ending the tool call with an input-required '
      'result', () async {
    final result = await _callTool(
      'test/roots',
      ClientCapabilities(roots: RootsCapabilities()),
      protocolVersion: ProtocolVersion.v2026_07_28,
    );

    expect(result![Keys.error], isNull);
    final value = result[Keys.result] as Map<String, Object?>;
    expect(value[Keys.resultType], 'input_required');
    final requests = value[Keys.inputRequests] as Map<String, Object?>;
    expect(requests.keys, ['0']);
    final entry = requests['0'] as Map<String, Object?>;
    expect(entry[Keys.method], ListRootsRequest.methodName);
  });
}
