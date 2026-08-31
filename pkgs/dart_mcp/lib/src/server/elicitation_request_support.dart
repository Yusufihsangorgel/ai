// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'server.dart';

/// A mixin that adds support for making `elicitation/create` requests to a
/// [MCPServer].
base mixin ElicitationRequestSupport on LoggingSupport {
  /// Whether or not the connected client supports elicitation.
  ///
  /// Only safe to call after calling [initialize] on `super` since this
  /// is based on the client capabilities.
  bool get supportsElicitation => clientCapabilities.elicitation != null;

  /// Whether or not the connected client supports [ElicitationMode.form]
  /// requests.
  ///
  /// Only safe to call after calling [initialize] on `super` since this
  /// is based on the client capabilities.
  ///
  /// An empty `elicitation` object counts as form support, the backwards
  /// compatibility rule the 2025-11-25 revision added alongside the mode
  /// split. A client which named some other mode does not.
  bool get supportsFormElicitation =>
      clientCapabilities.supportsFormElicitation;

  /// Whether or not the connected client supports [ElicitationMode.url]
  /// requests.
  ///
  /// Only safe to call after calling [initialize] on `super` since this
  /// is based on the client capabilities.
  bool get supportsUrlElicitation => clientCapabilities.supportsUrlElicitation;

  @override
  FutureOr<void> initialize(MCPServerInitialization initialization) {
    initialized.then((_) {
      if (!supportsElicitation) {
        log(
          LoggingLevel.warning,
          'Client does not support the elicitation capability, some '
          'functionality may be disabled.',
        );
      }
    });
    return super.initialize(initialization);
  }

  /// Asks the client to elicit [request] from its user.
  ///
  /// Throws an [RpcException] when [protocolVersion] is older than
  /// 2025-06-18, which is when `elicitation/create` was added.
  ///
  /// Otherwise this only succeeds if the client has advertised the mode the
  /// request asks for, as [supportsFormElicitation] and
  /// [supportsUrlElicitation] read it, and throws an [RpcException] with
  /// [McpErrorCodes.missingRequiredClientCapability] when the client has not,
  /// naming the capability it is missing under `data.requiredCapabilities`.
  ///
  /// On 2025-06-18 and 2025-11-25 this sends `elicitation/create` and awaits
  /// the answer, like any other request to the client.
  ///
  /// 2026-07-28 took that request out and carries an [ElicitRequest] in an
  /// [InputRequiredResult] instead, so from inside a `tools/call`,
  /// `prompts/get` or `resources/read` handler this asks by ending that
  /// exchange with one: the first call a handler makes to this, to
  /// [MCPServer.listRoots] or to [MCPServer.createMessage] throws
  /// internally, which [ToolsSupport.callTool], [PromptsSupport.getPrompt]
  /// and [ResourcesSupport.readResource] catch, so nothing here blocks. A
  /// retry that already answers this call, at the position it holds among
  /// every such call the handler makes, returns that answer instead of
  /// asking again. Calling this from anywhere else on that revision throws
  /// an [RpcException], since nothing outside those three requests can carry
  /// an [InputRequiredResult] back.
  ///
  /// [ToolsSupport.callTool] rethrows an [RpcException] instead of folding it
  /// into a [CallToolResult], so a tool which elicits reaches the client as
  /// that error rather than as a result whose text is a Dart stack trace.
  Future<ElicitResult> elicit(ElicitRequest request) async {
    if (protocolVersion < ProtocolVersion.v2026_07_28) {
      _rejectRemovedMethod(ElicitRequest.methodName, protocolVersion);
    }
    final raw = request.rawMode;
    if (raw != null && !ElicitationMode.values.any((m) => m.name == raw)) {
      throw RpcException.invalidParams(
        'The elicitation mode was "$raw", which is not one of: '
        '${ElicitationMode.values.map((m) => m.name).join(', ')}',
      );
    }
    switch (request.mode) {
      case ElicitationMode.url:
        if (!supportsUrlElicitation) {
          throw _missingUrlElicitation;
        }
      case ElicitationMode.form:
        if (!supportsFormElicitation) {
          throw _missingFormElicitation;
        }
    }
    if (protocolVersion >= ProtocolVersion.v2026_07_28) {
      return _resolveInputRequired(InputRequest.elicit(request));
    }
    return sendRequest(ElicitRequest.methodName, request);
  }

  /// Notifies the client that a URL elicitation has completed.
  void notifyElicitationComplete(
    ElicitationCompleteNotification notification,
  ) => sendNotification(
    ElicitationCompleteNotification.methodName,
    notification,
  );
}
