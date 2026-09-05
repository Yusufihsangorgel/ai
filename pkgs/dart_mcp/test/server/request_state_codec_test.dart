// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:json_rpc_2/error_code.dart' as error_code;
import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

final _key = List<int>.generate(32, (index) => index);

void main() {
  group('RequestStateCodec', () {
    test('round trips a payload with matching associated data', () {
      final codec = RequestStateCodec(_key);
      final binding = utf8.encode('caller-a\u0000tools/call\u0000weather');
      final state = codec.seal('{"step":2}', associatedData: binding);

      expect(codec.open(state, associatedData: binding), '{"step":2}');
    });

    test('copies the signing key', () {
      final key = [..._key];
      final codec = RequestStateCodec(key);
      final state = codec.seal('kept');
      key.fillRange(0, key.length, 255);

      expect(codec.open(state), 'kept');
    });

    test('rejects invalid constructor arguments', () {
      expect(() => RequestStateCodec(_key.sublist(1)), throwsRangeError);
      expect(
        () => RequestStateCodec(
          _key,
          timeToLive: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
      expect(
        () => RequestStateCodec(_key, maxStateLength: -1),
        throwsRangeError,
      );
    });

    test('rejects a modified payload or tag', () {
      final codec = RequestStateCodec(_key);
      final state = codec.seal('kept');
      final sections = state.split('.');
      final changedBody = _changeAt(sections[1], 0);
      final changedTag = _changeAt(sections[2], 0);
      final changedTagTail = _changeAt(sections[2], sections[2].length - 8);

      expect(
        () => codec.open('${sections[0]}.$changedBody.${sections[2]}'),
        throwsFormatException,
      );
      expect(
        () => codec.open('${sections[0]}.${sections[1]}.$changedTag'),
        throwsFormatException,
      );
      expect(
        () => codec.open('${sections[0]}.${sections[1]}.$changedTagTail'),
        throwsFormatException,
      );
    });

    test('rejects a non-canonical tag encoding', () {
      final codec = RequestStateCodec(_key);
      final sections = codec.seal('kept').split('.');
      final alias = _changePadBits(sections[2]);

      expect(
        () => codec.open('${sections[0]}.${sections[1]}.$alias'),
        throwsFormatException,
      );
    });

    test('rejects the wrong associated data', () {
      final codec = RequestStateCodec(_key);
      final state = codec.seal(
        'kept',
        associatedData: utf8.encode('caller-a\u0000tools/call'),
      );

      expect(
        () => codec.open(
          state,
          associatedData: utf8.encode('caller-b\u0000tools/call'),
        ),
        throwsFormatException,
      );
    });

    test('accepts before expiry', () {
      final issuedAt = DateTime.utc(2026);
      var now = issuedAt;
      final codec = RequestStateCodec(
        _key,
        timeToLive: const Duration(milliseconds: 10),
        clock: () => now,
      );
      final state = codec.seal('kept');

      now = issuedAt.add(const Duration(milliseconds: 9));
      expect(codec.open(state), 'kept');
    });

    test('rejects at the expiry boundary', () {
      final issuedAt = DateTime.utc(2026);
      var now = issuedAt;
      final codec = RequestStateCodec(
        _key,
        timeToLive: const Duration(milliseconds: 10),
        clock: () => now,
      );
      final state = codec.seal('kept');

      now = issuedAt.add(const Duration(milliseconds: 10));
      expect(() => codec.open(state), throwsFormatException);
    });

    test('accepts state without expiry', () {
      final issuedAt = DateTime.utc(2026);
      var now = issuedAt;
      final codec = RequestStateCodec(_key, timeToLive: null, clock: () => now);
      final state = codec.seal('kept');

      now = issuedAt.add(const Duration(days: 365));
      expect(codec.open(state), 'kept');
    });

    test('accepts state at the length limit', () {
      final now = DateTime.utc(2026);
      final state = _sealedAt(now);
      final exact = RequestStateCodec(
        _key,
        maxStateLength: state.length,
        clock: () => now,
      );

      expect(exact.seal('kept'), hasLength(state.length));
      expect(exact.open(state), 'kept');
    });

    test('rejects state beyond the length limit', () {
      final now = DateTime.utc(2026);
      final state = _sealedAt(now);
      final tooSmall = RequestStateCodec(
        _key,
        maxStateLength: state.length - 1,
        clock: () => now,
      );

      expect(() => tooSmall.seal('kept'), throwsArgumentError);
      expect(() => tooSmall.open(state), throwsFormatException);
    });

    test('rejects malformed values with one message', () {
      final codec = RequestStateCodec(_key);
      for (final state in ['', 'rs2.body.tag', 'rs1.body', 'rs1.%%%.tag']) {
        expect(
          () => codec.open(state),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Invalid or expired requestState',
            ),
          ),
        );
      }
    });
  });

  test('state survives a client and server round trip', () async {
    final environment = TestEnvironment(
      TestMCPClient(),
      _RequestStateServer.new,
    );
    await environment.initializeServer();
    environment.serverConnection.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.server.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.serverConnection.inputRequiredRetryDelay = Duration.zero;

    final result = await environment.serverConnection.callTool(
      CallToolRequest(name: _RequestStateServer.tool.name),
    );

    expect((result.content.single as TextContent).text, 'phase=complete');
    expect(environment.server.calls, 2);
  });

  test('server rejects state modified at the channel boundary', () async {
    final environment = TestEnvironment(
      TestMCPClient(),
      (channel) => _RequestStateServer(
        channel.transformStream(
          StreamTransformer.fromHandlers(
            handleData: (message, sink) {
              final params = message['params'];
              final state = params is Map ? params['requestState'] : null;
              if (state is String) {
                sink.add(
                  {
                    ...message,
                    'params': {
                      ...params as Map,
                      'requestState': _changeAt(state, 0),
                    },
                  }.cast<String, Object?>(),
                );
              } else {
                sink.add(message);
              }
            },
          ),
        ),
      ),
    );
    await environment.initializeServer();
    environment.serverConnection.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.server.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.serverConnection.inputRequiredRetryDelay = Duration.zero;

    expect(
      environment.serverConnection.callTool(
        CallToolRequest(name: _RequestStateServer.tool.name),
      ),
      throwsA(
        isA<RpcException>().having(
          (error) => error.message,
          'message',
          'Invalid requestState.',
        ),
      ),
    );
  });

  group('request-scoped protection', () {
    test('seals and opens state for every multi round-trip method', () async {
      final codec = RequestStateCodec(_key, clock: () => DateTime.utc(2026));
      final context = utf8.encode('caller-a');
      final cases = [
        (
          method: CallToolRequest.methodName,
          params: <String, Object?>{Keys.name: 'state'},
        ),
        (
          method: GetPromptRequest.methodName,
          params: <String, Object?>{Keys.name: 'state'},
        ),
        (
          method: ReadResourceRequest.methodName,
          params: <String, Object?>{Keys.uri: 'state:///value'},
        ),
      ];

      for (final testCase in cases) {
        final states = <String>[];
        final first = await _dispatchStateRequest(
          testCase.method,
          testCase.params,
          states,
          codec: codec,
          context: context,
        );
        final firstResult = first![Keys.result] as Map<String, Object?>;
        final protectedState = firstResult[Keys.requestState] as String;

        expect(protectedState, isNot('phase=complete'));
        expect(states, ['${testCase.method}:initial']);

        final second = await _dispatchStateRequest(
          testCase.method,
          {...testCase.params, Keys.requestState: protectedState},
          states,
          codec: codec,
          context: context,
          id: 2,
        );

        expect(second, isNot(contains(Keys.error)));
        expect(states, [
          '${testCase.method}:initial',
          '${testCase.method}:phase=complete',
        ]);
      }
    });

    test('rejects modified state before dispatch', () async {
      final states = <String>[];
      final codec = RequestStateCodec(_key);
      final first = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {Keys.name: 'state'},
        states,
        codec: codec,
      );
      final result = first![Keys.result] as Map<String, Object?>;
      final protectedState = result[Keys.requestState] as String;

      final rejected = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {Keys.name: 'state', Keys.requestState: _changeAt(protectedState, 0)},
        states,
        codec: codec,
        id: 2,
      );
      final error = rejected![Keys.error] as Map<String, Object?>;

      expect(error[Keys.code], error_code.INVALID_PARAMS);
      expect(error[Keys.message], RequestStateCodec.invalidMessage);
      expect(states, ['${CallToolRequest.methodName}:initial']);
    });

    test('rejects non-string state before dispatch', () async {
      final states = <String>[];
      final rejected = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {Keys.name: 'state', Keys.requestState: 1},
        states,
        codec: RequestStateCodec(_key),
      );
      final error = rejected![Keys.error] as Map<String, Object?>;

      expect(error[Keys.code], error_code.INVALID_PARAMS);
      expect(error[Keys.message], RequestStateCodec.invalidMessage);
      expect(states, isEmpty);
    });

    test('binds state to the caller context and original request', () async {
      final states = <String>[];
      final codec = RequestStateCodec(_key);
      final first = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {Keys.name: 'state'},
        states,
        codec: codec,
        context: const [1],
      );
      final result = first![Keys.result] as Map<String, Object?>;
      final protectedState = result[Keys.requestState] as String;

      for (final request in [
        (params: {Keys.name: 'state'}, context: const [2]),
        (params: {Keys.name: 'other'}, context: const [1]),
        (
          params: {
            Keys.name: 'state',
            Keys.arguments: {'changed': true},
          },
          context: const [1],
        ),
      ]) {
        final rejected = await _dispatchStateRequest(
          CallToolRequest.methodName,
          {...request.params, Keys.requestState: protectedState},
          states,
          codec: codec,
          context: request.context,
          id: 2,
        );
        final error = rejected![Keys.error] as Map<String, Object?>;

        expect(error[Keys.code], error_code.INVALID_PARAMS);
        expect(error[Keys.message], RequestStateCodec.invalidMessage);
      }
      expect(states, ['${CallToolRequest.methodName}:initial']);

      final reorderedStates = <String>[];
      final ordered = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {
          Keys.name: 'state',
          Keys.arguments: {'b': 2, 'a': 1},
        },
        reorderedStates,
        codec: codec,
        context: const [1],
      );
      final orderedResult = ordered![Keys.result] as Map<String, Object?>;
      final orderedState = orderedResult[Keys.requestState] as String;
      final reordered = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {
          Keys.name: 'state',
          Keys.arguments: {'a': 1, 'b': 2},
          Keys.requestState: orderedState,
        },
        reorderedStates,
        codec: codec,
        context: const [1],
        id: 2,
      );

      expect(reordered, isNot(contains(Keys.error)));
      expect(reorderedStates, [
        '${CallToolRequest.methodName}:initial',
        '${CallToolRequest.methodName}:phase=complete',
      ]);
    });

    test('binds state to its request method', () async {
      final states = <String>[];
      final codec = RequestStateCodec(_key);
      final first = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {Keys.name: 'state'},
        states,
        codec: codec,
      );
      final result = first![Keys.result] as Map<String, Object?>;
      final protectedState = result[Keys.requestState] as String;

      final rejected = await _dispatchStateRequest(
        GetPromptRequest.methodName,
        {Keys.name: 'state', Keys.requestState: protectedState},
        states,
        codec: codec,
        id: 2,
      );

      expect(rejected, contains(Keys.error));
      expect(states, ['${CallToolRequest.methodName}:initial']);
    });

    test('ignores retry inputs and metadata when binding state', () async {
      final states = <String>[];
      final codec = RequestStateCodec(_key);
      final first = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {Keys.name: 'state'},
        states,
        codec: codec,
      );
      final result = first![Keys.result] as Map<String, Object?>;
      final protectedState = result[Keys.requestState] as String;

      final retried = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {
          Keys.name: 'state',
          Keys.inputResponses: <String, Object?>{},
          Keys.requestState: protectedState,
          Keys.meta: {'trace': 'changed'},
        },
        states,
        codec: codec,
        id: 2,
      );

      expect(retried, isNot(contains(Keys.error)));
      expect(states, [
        '${CallToolRequest.methodName}:initial',
        '${CallToolRequest.methodName}:phase=complete',
      ]);
    });

    test('leaves state unchanged when protection is not configured', () async {
      final states = <String>[];
      final response = await _dispatchStateRequest(CallToolRequest.methodName, {
        Keys.name: 'state',
        Keys.requestState: 'plain',
      }, states);

      expect(response, isNot(contains(Keys.error)));
      expect(states, ['${CallToolRequest.methodName}:plain']);
    });

    test('leaves state unchanged before the protocol revision', () async {
      final states = <String>[];
      final response = await _dispatchStateRequest(
        CallToolRequest.methodName,
        {Keys.name: 'state', Keys.requestState: 'plain'},
        states,
        codec: RequestStateCodec(_key),
        protocolVersion: ProtocolVersion.v2025_11_25,
      );

      expect(response, isNot(contains(Keys.error)));
      expect(states, ['${CallToolRequest.methodName}:plain']);
    });
  });
}

String _changeAt(String value, int index) =>
    value.replaceRange(index, index + 1, value[index] == 'A' ? 'B' : 'A');

String _sealedAt(DateTime now) =>
    RequestStateCodec(_key, clock: () => now).seal('kept');

String _changePadBits(String value) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final index = alphabet.indexOf(value[value.length - 1]);
  return '${value.substring(0, value.length - 1)}${alphabet[index + 1]}';
}

final class _RequestStateServer extends TestMCPServer with ToolsSupport {
  _RequestStateServer(super.channel);

  static final tool = Tool(name: 'state', inputSchema: ObjectSchema());

  final _codec = RequestStateCodec(_key);
  final _binding = utf8.encode('tools/call\u0000state');
  int calls = 0;

  @override
  FutureOr<void> initialize(MCPServerInitialization initialization) {
    registerTool(tool, _call);
    return super.initialize(initialization);
  }

  CallToolResponse _call(CallToolRequest request) {
    calls++;
    final state = request.requestState;
    if (state == null) {
      return InputRequiredResult(
        requestState: _codec.seal('phase=complete', associatedData: _binding),
      );
    }
    try {
      return CallToolResult(
        content: [
          TextContent(text: _codec.open(state, associatedData: _binding)),
        ],
      );
    } on FormatException {
      throw RpcException.invalidParams('Invalid requestState.');
    }
  }
}

Future<Map<String, Object?>?> _dispatchStateRequest(
  String method,
  Map<String, Object?> params,
  List<String> states, {
  RequestStateCodec? codec,
  List<int> context = const [],
  Object id = 1,
  ProtocolVersion protocolVersion = ProtocolVersion.v2026_07_28,
}) => handleRequestScopedMessage(
  {Keys.jsonrpc: '2.0', Keys.id: id, Keys.method: method, Keys.params: params},
  MCPServerInitialization(
    protocolVersion: protocolVersion,
    clientCapabilities: ClientCapabilities(),
  ),
  (channel) => _RequestScopedStateServer(channel, states),
  requestStateCodec: codec,
  requestStateContext: context,
);

final class _RequestScopedStateServer extends TestMCPServer {
  _RequestScopedStateServer(super.channel, this.states);

  final List<String> states;

  @override
  FutureOr<void> initialize(MCPServerInitialization initialization) {
    registerRequestHandler<CallToolRequest, CallToolResponse>(
      CallToolRequest.methodName,
      _callTool,
    );
    registerRequestHandler<GetPromptRequest, GetPromptResponse>(
      GetPromptRequest.methodName,
      _getPrompt,
    );
    registerRequestHandler<ReadResourceRequest, ReadResourceResponse>(
      ReadResourceRequest.methodName,
      _readResource,
    );
    return super.initialize(initialization);
  }

  CallToolResponse _callTool(CallToolRequest request) {
    final state = request.requestState;
    _record(CallToolRequest.methodName, state);
    return state == null
        ? InputRequiredResult(requestState: 'phase=complete')
        : CallToolResult(content: [TextContent(text: state)]);
  }

  GetPromptResponse _getPrompt(GetPromptRequest request) {
    final state = request.requestState;
    _record(GetPromptRequest.methodName, state);
    return state == null
        ? InputRequiredResult(requestState: 'phase=complete')
        : GetPromptResult(
          messages: [
            PromptMessage(role: Role.user, content: TextContent(text: state)),
          ],
        );
  }

  ReadResourceResponse _readResource(ReadResourceRequest request) {
    final state = request.requestState;
    _record(ReadResourceRequest.methodName, state);
    return state == null
        ? InputRequiredResult(requestState: 'phase=complete')
        : ReadResourceResult(
          contents: [TextResourceContents(uri: request.uri, text: state)],
        );
  }

  void _record(String method, String? state) {
    states.add('$method:${state ?? 'initial'}');
  }
}
