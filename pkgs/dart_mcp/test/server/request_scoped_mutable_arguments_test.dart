// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:json_rpc_2/error_code.dart' as error_code;
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test(
    'binds state before a handler mutates arguments on each round',
    () async {
      final codec = RequestStateCodec(List<int>.generate(32, (index) => index));
      final states = <String?>[];

      Future<Map<String, Object?>?> dispatch(
        Map<String, Object?> arguments, {
        String? state,
      }) => handleRequestScopedMessage(
        {
          Keys.jsonrpc: '2.0',
          Keys.id: 1,
          Keys.method: CallToolRequest.methodName,
          Keys.params: {
            Keys.name: 'state',
            Keys.arguments: arguments,
            if (state != null) Keys.requestState: state,
          },
        },
        MCPServerInitialization(
          protocolVersion: ProtocolVersion.v2026_07_28,
          clientCapabilities: ClientCapabilities(),
        ),
        (channel) => _MutatingServer(channel, states),
        requestStateCodec: codec,
      );

      Map<String, Object?> arguments() => {
        'x': 1,
        'nested': {
          'values': [1],
        },
      };

      String? state;
      for (var round = 0; round < 3; round++) {
        final original = arguments();
        final response = await dispatch(original, state: state);
        expect(response, isNot(contains(Keys.error)));
        expect(original['x'], 2);
        expect((original['nested'] as Map)['values'], [2]);
        expect(states, [
          null,
          if (round >= 1) 'first',
          if (round >= 2) 'second',
        ]);

        final result = response![Keys.result] as Map<String, Object?>;
        if (round == 2) {
          expect(result[Keys.resultType], ResultTypes.complete);
          break;
        }
        expect(result[Keys.resultType], ResultTypes.inputRequired);
        state = result[Keys.requestState] as String;

        final rejected = await dispatch(arguments()..['x'] = 2, state: state);
        final error = rejected![Keys.error] as Map<String, Object?>;
        expect(error[Keys.code], error_code.INVALID_PARAMS);
        expect(error[Keys.message], RequestStateCodec.invalidMessage);
        expect(states, hasLength(round + 1));
      }
    },
  );
}

final class _MutatingServer extends TestMCPServer with ToolsSupport {
  _MutatingServer(super.channel, this.states);

  final List<String?> states;

  @override
  FutureOr<void> initialize(MCPServerInitialization initialization) {
    registerTool(Tool(name: 'state', inputSchema: ObjectSchema()), (request) {
      final state = request.requestState;
      states.add(state);
      request.arguments!['x'] = 2;
      final nested = request.arguments!['nested'] as Map;
      (nested['values'] as List)[0] = 2;
      return switch (state) {
        null => InputRequiredResult(requestState: 'first'),
        'first' => InputRequiredResult(requestState: 'second'),
        _ => CallToolResult(content: [TextContent(text: state)]),
      };
    });
    return super.initialize(initialization);
  }
}
