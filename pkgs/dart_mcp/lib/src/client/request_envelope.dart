// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Builds the per-request `_meta` envelope and the standard HTTP headers a
/// 2026-07-28 Streamable HTTP client request must carry.
///
/// Every field this library produces has a counterpart check in
/// `handleStreamableHttpRequest` (`streamable_http.dart`): the same protocol
/// version and method appear in both the body and the headers, and for
/// `tools/call`, `prompts/get`, and `resources/read` the `name`/`uri`
/// argument is mirrored into `Mcp-Name` as well. This library only builds
/// those values from the material a caller already has (the negotiated
/// version, the client's own capabilities/info, and the request being sent);
/// it never opens a connection, reads a response, or holds client state, so
/// it can be tested against the real server parser without a transport.
library;

import 'dart:convert';

import '../api/api.dart';
import '../utils/constants.dart';

/// The per-request `_meta` envelope and HTTP headers one outgoing
/// 2026-07-28 request must carry, built together so they cannot drift
/// apart from each other.
final class RequestEnvelope {
  const RequestEnvelope({required this.meta, required this.headers});

  /// The `io.modelcontextprotocol/*` keys to merge into the request's
  /// `params[Keys.meta]` object before it is encoded.
  ///
  /// These are the spec's own reserved `_meta` keys for a request
  /// (`basic/index`'s "Reserved keys" table), and `protocolVersion` and
  /// `clientCapabilities` are marked required there: a request missing
  /// either is malformed and the server MUST reject it with `-32602`. A
  /// caller that could overwrite one of them through its own `_meta` could
  /// produce exactly that malformed request, so a caller with keys of its
  /// own to send should spread them first and this map last. This map's
  /// entries always win over a caller-supplied key of the same name, and
  /// any other key the caller sends (a progress token, for instance) is
  /// untouched, since this builder never writes it. `ServerConnection.discover`
  /// merges its own reserved keys the same way (`client.dart`).
  final Map<String, Object?> meta;

  /// The HTTP headers to send alongside the request body: `Content-Type`,
  /// `Accept`, `MCP-Protocol-Version`, `Mcp-Method`, and, for the three
  /// methods [mcpNameParams] names, `Mcp-Name`.
  final Map<String, String> headers;
}

/// The methods whose `Mcp-Name` header mirrors a body parameter, and which
/// parameter it mirrors: `tools/call` and `prompts/get` mirror [Keys.name],
/// `resources/read` mirrors [Keys.uri].
///
/// Duplicates the private `_mcpNameParams` map `streamable_http.dart`
/// checks incoming requests against. Dart privacy is per-library (per
/// file), so the client side of this header and the server side that
/// validates it cannot share one declaration across files even within this
/// package.
const mcpNameParams = <String, String>{
  CallToolRequest.methodName: Keys.name,
  GetPromptRequest.methodName: Keys.name,
  ReadResourceRequest.methodName: Keys.uri,
};

/// Builds the [RequestEnvelope] for one outgoing [method] call.
///
/// [params] is the request's own `params` object, read only to find the
/// [mcpNameParams] value to mirror into `Mcp-Name`. This function never
/// mutates it, and the returned [RequestEnvelope.meta] is a separate object
/// a caller merges in on top.
///
/// Throws an [ArgumentError] if [method] is one of [mcpNameParams] and
/// [params] does not carry a `String` value for the parameter that method
/// mirrors: a request in that shape cannot reach the server successfully
/// regardless of its envelope, so the mismatch is surfaced here rather than
/// as a `-32020` `HeaderMismatch` response several layers away.
RequestEnvelope buildRequestEnvelope({
  required String method,
  required ProtocolVersion protocolVersion,
  required ClientCapabilities clientCapabilities,
  Implementation? clientInfo,
  LoggingLevel? logLevel,
  Map<String, Object?>? params,
}) {
  final meta = <String, Object?>{
    Keys.protocolVersionMeta: protocolVersion.versionString,
    Keys.clientCapabilitiesMeta: Map<String, Object?>.of(
      clientCapabilities as Map<String, Object?>,
    ),
    if (clientInfo != null)
      Keys.clientInfoMeta: Map<String, Object?>.of(
        clientInfo as Map<String, Object?>,
      ),
    if (logLevel != null) Keys.logLevelMeta: logLevel.name,
  };

  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'MCP-Protocol-Version': protocolVersion.versionString,
    'Mcp-Method': method,
    ..._mcpNameHeader(method, params),
  };

  return RequestEnvelope(meta: meta, headers: headers);
}

/// The `Mcp-Name` header entry for [method], or empty when [method] is not
/// in [mcpNameParams].
Map<String, String> _mcpNameHeader(
  String method,
  Map<String, Object?>? params,
) {
  final key = mcpNameParams[method];
  if (key == null) return const {};
  final value = params?[key];
  if (value is! String) {
    final got = value == null ? 'nothing' : value.runtimeType;
    throw ArgumentError(
      'A "$method" request requires a String "$key" param to mirror into '
      'the Mcp-Name header; got $got.',
    );
  }
  return {'Mcp-Name': encodeMcpNameValue(value)};
}

/// The `=?base64?…?=` sentinel prefix `Mcp-Name` and `Mcp-Param-*` headers
/// share, and the point [encodeMcpNameValue] wraps a value at.
const _sentinelPrefix = '=?base64?';
const _sentinelSuffix = '?=';

/// Encodes [value] for the `Mcp-Name` header: wraps it in the
/// `=?base64?…?=` sentinel whenever it cannot survive as a plain HTTP
/// header field value: empty, already sentinel-shaped, carrying
/// leading/trailing whitespace, or containing any character outside
/// visible ASCII (`0x21`–`0x7E`), space, or horizontal tab, and passes it
/// through unchanged otherwise.
///
/// Mirrors `_decodeSentinel` in `streamable_http.dart`, which this
/// function's output must round-trip through, and the emsal
/// `typescript-sdk`'s `encodeMcpParamValue`/`needsBase64`
/// (`core-internal/src/shared/mcpParamHeaders.ts`), which defines the same
/// encoding for the sibling `Mcp-Param-*` headers SEP-2243 introduced
/// alongside `Mcp-Name`.
String encodeMcpNameValue(String value) =>
    _needsSentinel(value)
        ? '$_sentinelPrefix${base64.encode(utf8.encode(value))}$_sentinelSuffix'
        : value;

bool _needsSentinel(String value) {
  if (value.isEmpty) return true;
  if (value.startsWith(_sentinelPrefix) && value.endsWith(_sentinelSuffix)) {
    return true;
  }
  if (value.trim() != value) return true;
  for (final rune in value.runes) {
    // Horizontal tab, or visible ASCII / space.
    if (rune == 0x09 || (rune >= 0x20 && rune <= 0x7e)) continue;
    return true;
  }
  return false;
}
