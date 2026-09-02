// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
// Starting the client compiles it from source, and that lands inside the
// test.
@Timeout.factor(4)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _scenarioVariable = 'MCP_CONFORMANCE_SCENARIO';
const _standardHeadersScenario = 'http-standard-headers';

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
const _declaredCapabilities = {'roots', 'sampling', 'elicitation'};

void main() {
  group('conformance client', () {
    late HttpServer server;
    late List<String> methods;
    late List<Set<String>> declarations;

    setUp(() async {
      methods = [];
      declarations = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) => _answer(request, methods, declarations)),
      );
    });

    tearDown(() async => server.close(force: true));

    test('sends every scored request', () async {
      await _run(server, _standardHeadersScenario);
      expect(methods, containsAll(_scoredRequests));
    });

    test('declares its capabilities on every request', () async {
      await _run(server, _standardHeadersScenario);
      expect(declarations, isNotEmpty);
      expect(declarations, everyElement(containsAll(_declaredCapabilities)));
    });
    // `Platform.resolvedExecutable` is this test's own binary once it is
    // compiled, so it cannot start the client as it does on the VM.
  }, testOn: '!exe');
}

/// Runs the client against [server] for [scenario] and waits for it to exit.
Future<void> _run(HttpServer server, String scenario) async {
  final endpoint = Uri.http('${server.address.host}:${server.port}', '/');
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['tool/conformance_client.dart', '$endpoint'],
    environment: {_scenarioVariable: scenario},
    workingDirectory: Directory.current.path,
  );
  final errors = await process.stderr.transform(utf8.decoder).join();
  expect(await process.exitCode, 0, reason: errors);
}

/// Answers [request] with the smallest result its method allows, adds the
/// method to [methods] and the capabilities it declared to [declarations].
Future<void> _answer(
  HttpRequest request,
  List<String> methods,
  List<Set<String>> declarations,
) async {
  final message =
      jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
  final method = message['method'] as String;
  methods.add(method);
  final parameters = message['params'] as Map<String, Object?>? ?? const {};
  final meta = parameters['_meta'] as Map<String, Object?>? ?? const {};
  final capabilities =
      meta[_capabilitiesField] as Map<String, Object?>? ?? const {};
  declarations.add(capabilities.keys.toSet());
  request.response
    ..headers.contentType = ContentType.json
    ..write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': _results[method] ?? const <String, Object?>{},
      }),
    );
  await request.response.close();
}

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
