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
/// A method it never saw is reported as skipped, not failed, so a fixture
/// sending fewer of these still passes the scenario.
const _scoredRequests = {
  'tools/list',
  'tools/call',
  'resources/list',
  'resources/read',
  'prompts/list',
  'prompts/get',
};

void main() {
  group('conformance client', () {
    late HttpServer server;
    late List<String> methods;

    setUp(() async {
      methods = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(server.forEach((request) => _answer(request, methods)));
    });

    tearDown(() async => server.close(force: true));

    test('sends the requests http-standard-headers scores', () async {
      final endpoint = Uri.http('${server.address.host}:${server.port}', '/');
      final process = await Process.start(
        Platform.resolvedExecutable,
        ['tool/conformance_client.dart', '$endpoint'],
        environment: {_scenarioVariable: _standardHeadersScenario},
        workingDirectory: Directory.current.path,
      );
      final errors = await process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 0, reason: errors);
      expect(methods, containsAll(_scoredRequests));
    });
    // `Platform.resolvedExecutable` is this test's own binary once it is
    // compiled, so it cannot start the client the way it does on the VM.
  }, testOn: '!exe');
}

/// Answers [request] with the smallest result its method allows, and adds the
/// method to [methods].
Future<void> _answer(HttpRequest request, List<String> methods) async {
  final message =
      jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
  final method = message['method'] as String;
  methods.add(method);
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
