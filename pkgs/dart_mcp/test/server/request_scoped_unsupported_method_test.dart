// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('unsupported method state bypasses request-state decoding', () async {
    final response = await handleRequestScopedMessage(
      {
        Keys.jsonrpc: '2.0',
        Keys.id: 1,
        Keys.method: ListToolsRequest.methodName,
        Keys.params: {Keys.requestState: 'plain'},
      },
      MCPServerInitialization(
        protocolVersion: ProtocolVersion.v2026_07_28,
        clientCapabilities: ClientCapabilities(),
      ),
      _ToolsServer.new,
      requestStateCodec: RequestStateCodec(
        List<int>.generate(32, (index) => index),
      ),
    );

    expect(response, isNot(contains(Keys.error)));
    expect(response![Keys.result], containsPair(Keys.tools, isEmpty));
  });
}

final class _ToolsServer extends TestMCPServer with ToolsSupport {
  _ToolsServer(super.channel);
}
