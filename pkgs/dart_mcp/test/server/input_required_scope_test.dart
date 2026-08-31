// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/src/utils/constants.dart';
import 'package:json_rpc_2/error_code.dart' as error_code;
import 'package:test/test.dart';

/// A server whose tools, a prompt and a resource ask for input through
/// [ElicitationRequestSupport.elicit], [MCPServer.listRoots] and
/// [MCPServer.createMessage], and whose `resources/subscribe` handler calls
/// [ElicitationRequestSupport.elicit] from outside the three requests that
/// carry an [InputRequiredResult].
final class _ScopeServer extends MCPServer
    with
        LoggingSupport,
        ToolsSupport,
        PromptsSupport,
        ResourcesSupport,
        ElicitationRequestSupport {
  _ScopeServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'test', version: '0.1.0'),
      ) {
    registerTool(Tool(name: 'elicit_once', inputSchema: ObjectSchema()), (
      _,
    ) async {
      final answer = await elicit(
        ElicitRequest(message: 'name?', requestedSchema: ObjectSchema()),
      );
      return CallToolResult(content: [TextContent(text: answer.action.name)]);
    });

    registerTool(Tool(name: 'elicit_twice', inputSchema: ObjectSchema()), (
      _,
    ) async {
      final first = await elicit(
        ElicitRequest(message: 'first?', requestedSchema: ObjectSchema()),
      );
      final second = await elicit(
        ElicitRequest(message: 'second?', requestedSchema: ObjectSchema()),
      );
      return CallToolResult(
        content: [
          TextContent(text: '${first.action.name}/${second.action.name}'),
        ],
      );
    });

    registerTool(Tool(name: 'sample_once', inputSchema: ObjectSchema()), (
      _,
    ) async {
      final answer = await createMessage(
        CreateMessageRequest(messages: [], maxTokens: 1),
      );
      return CallToolResult(content: [TextContent(text: answer.model)]);
    });

    registerTool(Tool(name: 'roots_once', inputSchema: ObjectSchema()), (
      _,
    ) async {
      final answer = await listRoots();
      return CallToolResult(
        content: [TextContent(text: '${answer.roots.length}')],
      );
    });

    addPrompt(Prompt(name: 'elicit_prompt'), (_) async {
      final answer = await elicit(
        ElicitRequest(
          message: 'prompt input?',
          requestedSchema: ObjectSchema(),
        ),
      );
      return GetPromptResult(
        messages: [
          PromptMessage(
            role: Role.user,
            content: TextContent(text: answer.action.name),
          ),
        ],
      );
    });

    addResource(Resource(uri: 'test://elicits', name: 'elicits'), (_) async {
      final answer = await elicit(
        ElicitRequest(
          message: 'resource input?',
          requestedSchema: ObjectSchema(),
        ),
      );
      return ReadResourceResult(
        contents: [
          TextResourceContents(uri: 'test://elicits', text: answer.action.name),
        ],
      );
    });

    // `resources/subscribe` is not one of the three requests 2026-07-28
    // permits an `InputRequiredResult` on, so no scope is set here.
    addResource(Resource(uri: 'test://plain', name: 'plain'), (_) async {
      throw StateError('not read in this test');
    });
  }

  @override
  Future<EmptyResult> subscribeResource(SubscribeRequest request) async {
    await elicit(
      ElicitRequest(message: 'unreachable', requestedSchema: ObjectSchema()),
    );
    return await super.subscribeResource(request);
  }
}

Future<Map<String, Object?>?> _callTool(
  String name, {
  Map<String, Result>? inputResponses,
  String? requestState,
}) => handleRequestScopedMessage(
  {
    Keys.jsonrpc: '2.0',
    Keys.id: 1,
    Keys.method: CallToolRequest.methodName,
    Keys.params: {
      Keys.name: name,
      if (inputResponses != null) Keys.inputResponses: inputResponses,
      if (requestState != null) Keys.requestState: requestState,
    },
  },
  MCPServerInitialization(
    protocolVersion: ProtocolVersion.v2026_07_28,
    clientCapabilities: ClientCapabilities(
      elicitation: ElicitationCapability(form: {}),
      sampling: {},
      roots: RootsCapabilities(),
    ),
  ),
  _ScopeServer.new,
);

Future<Map<String, Object?>?> _getPrompt({
  Map<String, Result>? inputResponses,
}) => handleRequestScopedMessage(
  {
    Keys.jsonrpc: '2.0',
    Keys.id: 1,
    Keys.method: GetPromptRequest.methodName,
    Keys.params: {
      Keys.name: 'elicit_prompt',
      if (inputResponses != null) Keys.inputResponses: inputResponses,
    },
  },
  MCPServerInitialization(
    protocolVersion: ProtocolVersion.v2026_07_28,
    clientCapabilities: ClientCapabilities(
      elicitation: ElicitationCapability(form: {}),
    ),
  ),
  _ScopeServer.new,
);

Future<Map<String, Object?>?> _readResource(
  String uri, {
  Map<String, Result>? inputResponses,
}) => handleRequestScopedMessage(
  {
    Keys.jsonrpc: '2.0',
    Keys.id: 1,
    Keys.method: ReadResourceRequest.methodName,
    Keys.params: {
      Keys.uri: uri,
      if (inputResponses != null) Keys.inputResponses: inputResponses,
    },
  },
  MCPServerInitialization(
    protocolVersion: ProtocolVersion.v2026_07_28,
    clientCapabilities: ClientCapabilities(
      elicitation: ElicitationCapability(form: {}),
    ),
  ),
  _ScopeServer.new,
);

Future<Map<String, Object?>?> _subscribe() => handleRequestScopedMessage(
  {
    Keys.jsonrpc: '2.0',
    Keys.id: 1,
    Keys.method: SubscribeRequest.methodName,
    Keys.params: {Keys.uri: 'test://plain'},
  },
  MCPServerInitialization(
    protocolVersion: ProtocolVersion.v2026_07_28,
    clientCapabilities: ClientCapabilities(
      elicitation: ElicitationCapability(form: {}),
    ),
  ),
  _ScopeServer.new,
);

Map<String, Object?> _result(Map<String, Object?> response) =>
    response[Keys.result] as Map<String, Object?>;

Map<String, Object?> _error(Map<String, Object?> response) =>
    response[Keys.error] as Map<String, Object?>;

void main() {
  test('a first call has no answer and ends with input_required', () async {
    final response = await _callTool('elicit_once');

    expect(response![Keys.error], isNull);
    final result = _result(response);
    expect(result[Keys.resultType], 'input_required');
    final requests = result[Keys.inputRequests] as Map<String, Object?>;
    expect(requests.keys, ['0']);
    final entry = requests['0'] as Map<String, Object?>;
    expect(entry[Keys.method], ElicitRequest.methodName);
    expect((entry[Keys.params] as Map<String, Object?>)[Keys.message], 'name?');
  });

  test(
    'a retry with the matching answer runs the tool to completion',
    () async {
      final response = await _callTool(
        'elicit_once',
        inputResponses: {'0': ElicitResult(action: ElicitationAction.accept)},
      );

      expect(response![Keys.error], isNull);
      final result = _result(response);
      expect(result[Keys.resultType], isNot('input_required'));
      expect(
        (result[Keys.content] as List).cast<Map<String, Object?>>().single[Keys
            .text],
        'accept',
      );
    },
  );

  test('createMessage asks and resolves the same way elicit does', () async {
    final asked = await _callTool('sample_once');
    expect(_result(asked!)[Keys.resultType], 'input_required');
    final requests = _result(asked)[Keys.inputRequests] as Map<String, Object?>;
    expect(
      (requests['0'] as Map<String, Object?>)[Keys.method],
      CreateMessageRequest.methodName,
    );

    final answered = await _callTool(
      'sample_once',
      inputResponses: {
        '0': CreateMessageResult(
          role: Role.assistant,
          content: TextContent(text: 'hi'),
          model: 'test-model',
        ),
      },
    );
    expect(_result(answered!)[Keys.resultType], isNot('input_required'));
    expect(
      (_result(answered)[Keys.content] as List)
          .cast<Map<String, Object?>>()
          .single[Keys.text],
      'test-model',
    );
  });

  test('listRoots asks and resolves the same way elicit does', () async {
    final asked = await _callTool('roots_once');
    expect(_result(asked!)[Keys.resultType], 'input_required');
    final requests = _result(asked)[Keys.inputRequests] as Map<String, Object?>;
    expect(
      (requests['0'] as Map<String, Object?>)[Keys.method],
      ListRootsRequest.methodName,
    );

    final answered = await _callTool(
      'roots_once',
      inputResponses: {
        '0': ListRootsResult(
          roots: [Root(uri: 'file:///a'), Root(uri: 'file:///b')],
        ),
      },
    );
    expect(_result(answered!)[Keys.resultType], isNot('input_required'));
    expect(
      (_result(answered)[Keys.content] as List)
          .cast<Map<String, Object?>>()
          .single[Keys.text],
      '2',
    );
  });

  test('a second call keeps asking at the next key, not the first', () async {
    // Neither call answered yet: the handler stops at the first one, and
    // only that one is named.
    final firstAsk = await _callTool('elicit_twice');
    final firstRequests =
        _result(firstAsk!)[Keys.inputRequests] as Map<String, Object?>;
    expect(firstRequests.keys, ['0']);

    // The first call is answered, the second is not: the handler runs past
    // the first and stops at the second, asking under key "1", not "0"
    // again.
    final secondAsk = await _callTool(
      'elicit_twice',
      inputResponses: {'0': ElicitResult(action: ElicitationAction.accept)},
    );
    final secondResult = _result(secondAsk!);
    expect(secondResult[Keys.resultType], 'input_required');
    final secondRequests =
        secondResult[Keys.inputRequests] as Map<String, Object?>;
    expect(secondRequests.keys, ['1']);
    expect(
      (secondRequests['1'] as Map<String, Object?>)[Keys.params]
          as Map<String, Object?>,
      containsPair(Keys.message, 'second?'),
    );

    // Both answered: the tool call completes.
    final done = await _callTool(
      'elicit_twice',
      inputResponses: {
        '0': ElicitResult(action: ElicitationAction.accept),
        '1': ElicitResult(action: ElicitationAction.decline),
      },
    );
    final doneResult = _result(done!);
    expect(doneResult[Keys.resultType], isNot('input_required'));
    expect(
      (doneResult[Keys.content] as List)
          .cast<Map<String, Object?>>()
          .single[Keys.text],
      'accept/decline',
    );
  });

  test('getPrompt asks and resolves through the same scope', () async {
    final asked = await _getPrompt();
    expect(_result(asked!)[Keys.resultType], 'input_required');

    final answered = await _getPrompt(
      inputResponses: {'0': ElicitResult(action: ElicitationAction.accept)},
    );
    expect(_result(answered!)[Keys.resultType], isNot('input_required'));
    final messages = _result(answered)[Keys.messages] as List;
    final message =
        (messages.single as Map<String, Object?>)[Keys.content]
            as Map<String, Object?>;
    expect(message[Keys.text], 'accept');
  });

  test('readResource asks and resolves through the same scope', () async {
    final asked = await _readResource('test://elicits');
    expect(_result(asked!)[Keys.resultType], 'input_required');

    final answered = await _readResource(
      'test://elicits',
      inputResponses: {'0': ElicitResult(action: ElicitationAction.decline)},
    );
    expect(_result(answered!)[Keys.resultType], isNot('input_required'));
    final contents = _result(answered)[Keys.contents] as List;
    expect((contents.single as Map<String, Object?>)[Keys.text], 'decline');
  });

  test('elicit outside a tools/call, prompts/get or resources/read handler '
      'refuses instead of hanging', () async {
    final response = await _subscribe();

    final error = _error(response!);
    expect(error[Keys.code], error_code.INTERNAL_ERROR);
    expect(
      error[Keys.message],
      allOf(
        contains('outside of a'),
        contains(CallToolRequest.methodName),
        contains(GetPromptRequest.methodName),
        contains(ReadResourceRequest.methodName),
      ),
    );
  });

  test('an unrelated key in inputResponses answers nothing', () async {
    final response = await _callTool(
      'elicit_once',
      inputResponses: {
        'not-the-right-key': ElicitResult(action: ElicitationAction.accept),
      },
    );

    expect(_result(response!)[Keys.resultType], 'input_required');
    final requests =
        _result(response)[Keys.inputRequests] as Map<String, Object?>;
    expect(requests.keys, ['0']);
  });
}
