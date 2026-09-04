// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/streamable_http.dart';
import 'package:json_rpc_2/json_rpc_2.dart';

/// Runs the client fixture used by the MCP conformance suite.
///
/// The suite starts a server for one scenario, appends its endpoint to this
/// command and names the scenario and revision in the environment, along with
/// a context for the scenarios that need one. It runs a requirement set in
/// parallel. Compile this first and let each scenario spend its timeout on the
/// protocol instead of on startup.
///
/// ```sh
/// dart compile exe tool/conformance_client.dart -o /tmp/mcp_client
/// npx @modelcontextprotocol/conformance@0.2.0-alpha.11 \
///   client --command /tmp/mcp_client --requirements 2026-07-28
/// ```
///
/// The set also covers the `auth/` scenarios, which this package has no
/// authorization support for.
Future<void> main(List<String> arguments) async {
  final endpoint = Uri.parse(arguments.last);
  final environment = Platform.environment;
  final protocolVersion = _protocolVersion(environment);
  final client = _ConformanceClient();
  final connection = client.connectServer(
    streamableHttpClientChannel(
      endpoint,
      protocolVersion: protocolVersion,
      clientCapabilities: client.capabilities,
      clientInfo: client.implementation,
    ),
  );
  // Streamable HTTP names the revision on every request instead of settling it
  // in a handshake, so the field `initialize` would have filled is set here.
  connection.protocolVersion = protocolVersion;

  try {
    await _runScenario(
      environment[_scenarioVariable],
      connection,
      client,
      protocolVersion,
      environment[_contextVariable],
    );
  } finally {
    await client.shutdown();
  }
}

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

// http-invalid-tool-headers sends no context, so the one valid tool it serves
// takes its annotated argument from here.
const _headerArgument = 'us-west1';

/// The revision that these scenarios run at when the suite names none.
const _revision = ProtocolVersion.v2026_07_28;

ProtocolVersion _protocolVersion(Map<String, String> environment) {
  final requested = environment[_protocolVersionVariable];
  if (requested == null) return _revision;
  final version = ProtocolVersion.tryParse(requested);
  if (version == null) {
    throw ArgumentError.value(
      requested,
      _protocolVersionVariable,
      'is not a revision this package knows',
    );
  }
  return version;
}

Future<void> _runScenario(
  String? scenario,
  ServerConnection connection,
  _ConformanceClient client,
  ProtocolVersion protocolVersion,
  String? context,
) async {
  Future<DiscoverResult> discover() => connection.discover(
    protocolVersion: protocolVersion,
    capabilities: client.capabilities,
    clientInfo: client.implementation,
  );

  switch (scenario) {
    case _toolsCallScenario:
      await discover();
      await connection.listTools();
      await connection.callTool(
        CallToolRequest(name: _addNumbersTool, arguments: {'a': 2, 'b': 3}),
      );
    case _requestMetadataScenario:
      // The scenario answers the first request with -32022 to see whether the
      // client comes back on a version the server named.
      try {
        await discover();
      } on RpcException {
        // The retry is the request after this one.
      }
      await connection.listTools();
    case _requestStateScenario:
      await discover();
      await connection.listTools();
      // The unrelated call goes out while the echo flow is still open, which
      // is the isolation this scenario asks about.
      final echoState = connection.callTool(
        CallToolRequest(name: _echoStateTool),
      );
      await connection.callTool(CallToolRequest(name: _unrelatedTool));
      await echoState;
      await connection.callTool(CallToolRequest(name: _noStateTool));
      await connection.callTool(CallToolRequest(name: _noResultTypeTool));
    case _standardHeadersScenario:
      await discover();
      await _exerciseNamedMethods(connection);
    case _customHeadersScenario:
      await discover();
      // Mirrored headers come from annotations the client read in a
      // `tools/list` result, so the list has to go out before the calls.
      await connection.listTools();
      for (final request in _requestedToolCalls(context)) {
        await connection.callTool(request);
      }
    case _invalidToolHeadersScenario:
      await discover();
      // A tool the client rejected is gone from this result, so calling
      // everything left is what "keeps the valid tool" looks like.
      final tools = await connection.listTools();
      for (final tool in tools.tools) {
        await connection.callTool(
          CallToolRequest(
            name: tool.name,
            arguments: _requiredStringArguments(tool),
          ),
        );
      }
    case _refDereferenceScenario:
      await discover();
      // Listing is the whole flow. The scenario watches for a fetch of the
      // network `$ref` that the tool's input schema points at.
      await connection.listTools();
    default:
      throw ArgumentError.value(
        scenario,
        _scenarioVariable,
        'is not a scenario this fixture serves',
      );
  }
}

/// Sends one request for each method that carries `Mcp-Method`, and each of
/// the three that also carry `Mcp-Name`.
///
/// http-standard-headers checks a method only once, and reports the ones it
/// never saw as skipped. `initialize` and `notifications/initialized` are two
/// of those: 2026-07-28 took the handshake away.
Future<void> _exerciseNamedMethods(ServerConnection connection) async {
  final tools = await connection.listTools();
  for (final tool in tools.tools) {
    await connection.callTool(CallToolRequest(name: tool.name));
  }
  final resources = await connection.listResources();
  for (final resource in resources.resources) {
    await connection.readResource(ReadResourceRequest(uri: resource.uri));
  }
  final prompts = await connection.listPrompts();
  for (final prompt in prompts.prompts) {
    await connection.getPrompt(GetPromptRequest(name: prompt.name));
  }
}

/// Reads the calls http-custom-headers asks for out of [context].
///
/// Their arguments carry the values that scenario encodes into headers, one
/// of them null. The suite supplies them, not this file.
Iterable<CallToolRequest> _requestedToolCalls(String? context) sync* {
  if (context == null) {
    throw StateError(
      '$_customHeadersScenario names its calls in $_contextVariable, which '
      'was not set.',
    );
  }
  final decoded = jsonDecode(context) as Map<String, Object?>;
  for (final call in decoded['toolCalls'] as List) {
    final map = (call as Map).cast<String, Object?>();
    yield CallToolRequest(
      name: map['name'] as String,
      arguments: (map['arguments'] as Map?)?.cast<String, Object?>(),
    );
  }
}

/// Fills the string properties [tool] requires.
Map<String, Object?> _requiredStringArguments(Tool tool) {
  final schema = tool.inputSchema;
  final properties = schema.properties;
  return {
    for (final name in schema.required ?? const <String>[])
      if (properties?[name]?.type == JsonType.string) name: _headerArgument,
  };
}

/// The client the suite runs its scenarios against.
///
/// It declares the two capabilities it can serve. Roots answers a list and
/// form elicitation answers the confirmation the MRTR rounds in
/// sep-2322-client-request-state ask for between calls. request-metadata reads
/// both declarations back off `_meta`.
final class _ConformanceClient extends MCPClient
    with RootsSupport, ElicitationFormSupport {
  _ConformanceClient()
    : super(
        Implementation(name: 'dart_mcp conformance client', version: '0.1.0'),
      );

  @override
  FutureOr<ElicitResult> handleElicitation(
    ElicitRequest request,
    ServerConnection connection,
  ) => ElicitResult(
    action: ElicitationAction.accept,
    content: {
      for (final MapEntry(:key, :value)
          in request.requestedSchema?.properties?.entries ??
              const Iterable<MapEntry<String, Schema>>.empty())
        if (value.type == JsonType.bool) key: true,
    },
  );
}
