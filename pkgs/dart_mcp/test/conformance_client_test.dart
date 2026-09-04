// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Timeout.factor(4)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _scenarioVariable = 'MCP_CONFORMANCE_SCENARIO';
const _protocolVersionVariable = 'MCP_CONFORMANCE_PROTOCOL_VERSION';
const _contextVariable = 'MCP_CONFORMANCE_CONTEXT';

const _toolsCallScenario = 'tools_call';
const _requestMetadataScenario = 'request-metadata';
const _requestStateScenario = 'sep-2322-client-request-state';
const _standardHeadersScenario = 'http-standard-headers';
const _customHeadersScenario = 'http-custom-headers';
const _invalidToolHeadersScenario = 'http-invalid-tool-headers';
const _refDereferenceScenario = 'json-schema-ref-no-deref';

const _addNumbersTool = 'add_numbers';
const _echoStateTool = 'test_mrtr_echo_state';
const _noStateTool = 'test_mrtr_no_state';
const _unrelatedTool = 'test_mrtr_unrelated';
const _noResultTypeTool = 'test_mrtr_no_result_type';

// Named on the wire instead of through the package, so a change to both the
// client and its constants cannot make this agree with itself.
const _tool = 'probe_tool';
const _resource = 'test://probe/resource';
const _prompt = 'probe_prompt';

/// The requests http-standard-headers scores when it sees them.
///
/// A method it never saw is reported as skipped, not failed. A fixture
/// sending fewer of these still passes the scenario.
const _scoredRequests = {
  'tools/list',
  'tools/call',
  'resources/list',
  'resources/read',
  'prompts/list',
  'prompts/get',
};

/// The field request-metadata reads the client's capabilities out of.
const _capabilitiesField = 'io.modelcontextprotocol/clientCapabilities';

/// The capabilities the client declares, named on the wire for the same
/// reason as the fixtures above.
///
/// request-metadata scores each of these only if it is present. Dropping
/// one lowers that score there without failing the scenario.
const _declaredCapabilities = {'roots', 'elicitation'};

late final Directory _clientDirectory;
late final String _clientExecutable;

void main() {
  setUpAll(() async {
    _clientDirectory = await Directory.systemTemp.createTemp(
      'dart-mcp-conformance-client-',
    );
    _clientExecutable = '${_clientDirectory.path}/client';
    final compilation = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'tool/conformance_client.dart',
      '-o',
      _clientExecutable,
    ], workingDirectory: Directory.current.path);
    expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
  });

  tearDownAll(() => _clientDirectory.delete(recursive: true));

  group('conformance client', () {
    late HttpServer server;
    late List<String> methods;
    late List<Set<String>> declarations;
    late List<Map<String, Object?>> messages;
    late _Responder responder;

    setUp(() async {
      methods = [];
      declarations = [];
      messages = [];
      responder = _successResponse;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(
        (request) => unawaited(
          _answer(request, methods, declarations, messages, responder),
        ),
      );
    });

    tearDown(() async => server.close(force: true));

    test('sends every scored request', () async {
      await _runSuccessfully(server, _standardHeadersScenario);
      expect(methods, containsAll(_scoredRequests));
    });

    test('declares its capabilities on every request', () async {
      await _runSuccessfully(server, _standardHeadersScenario);
      expect(declarations, isNotEmpty);
      expect(declarations, everyElement(_declaredCapabilities));
    });

    test('rejects an unknown protocol revision', () async {
      final result = await _run(
        server,
        _refDereferenceScenario,
        protocolVersion: 'not-a-revision',
      );

      expect(result.exitCode, isNonZero);
      expect(result.errors, contains(_protocolVersionVariable));
      expect(methods, isEmpty);
    });

    test('runs the tools call flow', () async {
      await _runSuccessfully(server, _toolsCallScenario);

      expect(methods, ['server/discover', 'tools/list', 'tools/call']);
      expect(_params(messages.last), {
        'name': _addNumbersTool,
        'arguments': {'a': 2, 'b': 3},
        '_meta': isA<Map>(),
      });
    });

    test('retries request metadata after the server error', () async {
      responder = (message, requestNumber) {
        if (requestNumber == 1) {
          return {
            'error': {'code': -32022, 'message': 'unsupported revision'},
          };
        }
        return _successResponse(message, requestNumber);
      };

      final result = await _run(server, _requestMetadataScenario);
      expect(methods, ['server/discover', 'tools/list']);
      expect(result.exitCode, 0, reason: result.errors);
    });

    test('keeps request state flows separate', () async {
      final unrelatedSeen = Completer<void>();
      responder = (message, requestNumber) async {
        final params = _params(message);
        if (message['method'] == 'tools/call' &&
            params['name'] == _unrelatedTool) {
          unrelatedSeen.complete();
        }
        if (message['method'] == 'tools/call' &&
            params['name'] == _echoStateTool &&
            !params.containsKey('inputResponses')) {
          await unrelatedSeen.future;
          return {
            'result': {
              'resultType': 'input_required',
              'inputRequests': {
                'form': {
                  'method': 'elicitation/create',
                  'params': {
                    'mode': 'form',
                    'message': 'Confirm',
                    'requestedSchema': {
                      'type': 'object',
                      'properties': {
                        'confirmed': {'type': 'boolean'},
                        'label': {'type': 'string'},
                      },
                    },
                  },
                },
                'emptyForm': {
                  'method': 'elicitation/create',
                  'params': {'mode': 'form', 'message': 'Continue'},
                },
                'noProperties': {
                  'method': 'elicitation/create',
                  'params': {
                    'mode': 'form',
                    'message': 'Continue',
                    'requestedSchema': {'type': 'object'},
                  },
                },
                'roots': {'method': 'roots/list'},
              },
              'requestState': 'echo-state',
            },
          };
        }
        return _successResponse(message, requestNumber);
      };

      await _runSuccessfully(server, _requestStateScenario);

      final calls = [
        for (final message in messages)
          if (message['method'] == 'tools/call') _params(message),
      ];
      expect(calls.map((call) => call['name']), [
        _echoStateTool,
        _unrelatedTool,
        _echoStateTool,
        _noStateTool,
        _noResultTypeTool,
      ]);
      final retry = calls[2];
      expect(retry['requestState'], 'echo-state');
      final responses = retry['inputResponses'] as Map;
      expect(responses['form'], {
        'action': 'accept',
        'content': {'confirmed': true},
      });
      expect(responses['emptyForm'], {
        'action': 'accept',
        'content': <String, Object?>{},
      });
      expect(responses['noProperties'], {
        'action': 'accept',
        'content': <String, Object?>{},
      });
      expect(responses['roots'], {'roots': <Object?>[]});
    });

    test('runs calls from the custom header context', () async {
      final context = jsonEncode({
        'toolCalls': [
          {
            'name': 'with_arguments',
            'arguments': {'region': 'north'},
          },
          {'name': 'without_arguments'},
        ],
      });

      await _runSuccessfully(server, _customHeadersScenario, context: context);

      expect(methods, [
        'server/discover',
        'tools/list',
        'tools/call',
        'tools/call',
      ]);
      expect(_params(messages[2]), {
        'name': 'with_arguments',
        'arguments': {'region': 'north'},
        '_meta': isA<Map>(),
      });
      expect(_params(messages[3]), {
        'name': 'without_arguments',
        '_meta': isA<Map>(),
      });
    });

    test('names the missing custom header context', () async {
      final result = await _run(server, _customHeadersScenario);

      expect(result.exitCode, isNonZero);
      expect(result.errors, contains(_contextVariable));
      expect(methods, ['server/discover', 'tools/list']);
    });

    test('calls every valid tool with its required string arguments', () async {
      responder = (message, requestNumber) {
        if (message['method'] == 'tools/list') {
          return {
            'result': {
              'tools': [
                {
                  'name': 'typed',
                  'inputSchema': {
                    'type': 'object',
                    'required': ['region', 'count'],
                    'properties': {
                      'region': {'type': 'string'},
                      'count': {'type': 'integer'},
                    },
                  },
                },
                {
                  'name': 'no_required',
                  'inputSchema': {'type': 'object'},
                },
                {
                  'name': 'no_properties',
                  'inputSchema': {
                    'type': 'object',
                    'required': ['absent'],
                  },
                },
              ],
            },
          };
        }
        return _successResponse(message, requestNumber);
      };

      await _runSuccessfully(server, _invalidToolHeadersScenario);

      final calls = [
        for (final message in messages)
          if (message['method'] == 'tools/call') _params(message),
      ];
      expect(calls.map((call) => call['name']), [
        'typed',
        'no_required',
        'no_properties',
      ]);
      expect(calls.map((call) => call['arguments']), [
        {'region': 'us-west1'},
        <String, Object?>{},
        <String, Object?>{},
      ]);
    });

    test('runs the ref check flow', () async {
      await _runSuccessfully(server, _refDereferenceScenario);

      expect(methods, ['server/discover', 'tools/list']);
    });

    test('rejects a scenario it does not serve', () async {
      final result = await _run(server, 'unknown-scenario');

      expect(result.exitCode, isNonZero);
      expect(result.errors, contains(_scenarioVariable));
      expect(methods, isEmpty);
    });
    // `Platform.resolvedExecutable` is this test's own binary once it is
    // compiled, so it cannot start the client as it does on the VM.
  }, testOn: '!exe');
}

typedef _Responder =
    FutureOr<Map<String, Object?>> Function(
      Map<String, Object?> message,
      int requestNumber,
    );

/// Runs the client against [server] for [scenario] and expects it to succeed.
Future<void> _runSuccessfully(
  HttpServer server,
  String scenario, {
  String? context,
  String? protocolVersion,
}) async {
  final result = await _run(
    server,
    scenario,
    context: context,
    protocolVersion: protocolVersion,
  );
  expect(result.exitCode, 0, reason: result.errors);
}

/// Runs the client against [server] for [scenario] and waits for it to exit.
Future<({int exitCode, String errors})> _run(
  HttpServer server,
  String scenario, {
  String? context,
  String? protocolVersion,
}) async {
  final endpoint = Uri.http('${server.address.host}:${server.port}', '/');
  final process = await Process.start(
    _clientExecutable,
    ['$endpoint'],
    environment: {
      _scenarioVariable: scenario,
      if (context != null) _contextVariable: context,
      if (protocolVersion != null) _protocolVersionVariable: protocolVersion,
    },
    workingDirectory: Directory.current.path,
  );
  final errors = process.stderr.transform(utf8.decoder).join();
  var timedOut = false;
  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () async {
      timedOut = true;
      process.kill();
      return process.exitCode;
    },
  );
  final errorText = await errors;
  return (
    exitCode: exitCode,
    errors: timedOut ? '$errorText\nprocess timed out' : errorText,
  );
}

/// Answers [request] with the smallest result its method allows, adds the
/// method to [methods] and the capabilities it declared to [declarations].
Future<void> _answer(
  HttpRequest request,
  List<String> methods,
  List<Set<String>> declarations,
  List<Map<String, Object?>> messages,
  _Responder responder,
) async {
  final message =
      jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
  messages.add(message);
  final method = message['method'] as String;
  methods.add(method);
  final parameters = message['params'] as Map<String, Object?>? ?? const {};
  final meta = parameters['_meta'] as Map<String, Object?>? ?? const {};
  final capabilities =
      meta[_capabilitiesField] as Map<String, Object?>? ?? const {};
  declarations.add(capabilities.keys.toSet());
  final response = await responder(message, messages.length);
  request.response
    ..headers.contentType = ContentType.json
    ..write(jsonEncode({'jsonrpc': '2.0', 'id': message['id'], ...response}));
  await request.response.close();
}

Map<String, Object?> _successResponse(
  Map<String, Object?> message,
  int requestNumber,
) => {'result': _results[message['method']] ?? const <String, Object?>{}};

Map<String, Object?> _params(Map<String, Object?> message) =>
    (message['params'] as Map).cast<String, Object?>();

const _results = <String, Object?>{
  'tools/list': {
    'tools': [
      {
        'name': _tool,
        'inputSchema': {'type': 'object'},
      },
    ],
  },
  'tools/call': {'content': <Object?>[]},
  'resources/list': {
    'resources': [
      {'uri': _resource, 'name': 'probe resource'},
    ],
  },
  'resources/read': {'contents': <Object?>[]},
  'prompts/list': {
    'prompts': [
      {'name': _prompt},
    ],
  },
  'prompts/get': {'messages': <Object?>[]},
};
