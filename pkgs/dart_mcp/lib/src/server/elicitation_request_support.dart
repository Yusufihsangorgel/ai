part of 'server.dart';

/// A mixin that adds support for making `elicitation/create` requests to a
/// [MCPServer].
base mixin ElicitationRequestSupport on LoggingSupport {
  /// Whether or not the connected client supports elicitation.
  ///
  /// Only safe to call after calling [initialize] on `super` since this
  /// is based on the client capabilities.
  ///
  /// A client can declare this and still turn down one of the two modes.
  /// [elicit] reads [supportsFormElicitation] or [supportsUrlElicitation] for a
  /// mode it knows, and this one for a mode it does not.
  bool get supportsElicitation => clientCapabilities.elicitation != null;

  /// Whether the connected client accepts [ElicitationMode.form] requests.
  ///
  /// Only safe to call after calling [initialize] on `super` since this
  /// is based on the client capabilities.
  ///
  /// A client that names neither mode counts as form support, which is how the
  /// 2025-11-25 revision reads clients that predate the mode split.
  bool get supportsFormElicitation {
    final elicitation = clientCapabilities.elicitation;
    if (elicitation == null) return false;
    return elicitation.form != null || elicitation.url == null;
  }

  /// Whether the connected client accepts [ElicitationMode.url] requests.
  ///
  /// Only safe to call after calling [initialize] on `super` since this
  /// is based on the client capabilities.
  bool get supportsUrlElicitation =>
      clientCapabilities.elicitation?.url != null;

  @override
  FutureOr<ServerCapabilities> initialize(
    MCPServerInitialization initialization,
  ) {
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

  /// Sends an `elicitation/create` request to the client.
  ///
  /// This method will only succeed if the client has advertised the mode the
  /// request asks for, `elicitation.form` or `elicitation.url`. A client that
  /// advertised `elicitation` without naming either mode counts as taking form
  /// requests. A mode this version does not know is held to `elicitation`,
  /// since there is no sub-capability to name for it.
  ///
  /// Throws an [RpcException] with
  /// [McpErrorCodes.missingRequiredClientCapability] when the client has not,
  /// naming the capability it is missing under `data.requiredCapabilities`,
  /// which the 2026-07-28 revision requires of that error.
  ///
  /// [ToolsSupport.callTool] rethrows an [RpcException] instead of folding it
  /// into a [CallToolResult], so a tool which elicits reaches the client as
  /// that error rather than as a result whose text is a Dart stack trace.
  Future<ElicitResult> elicit(ElicitRequest request) async {
    // The raw value, because `ElicitRequest.mode` throws on a mode this
    // version does not know and that would land in a caller as a state error.
    final mode = (request as Map<String, Object?>)[Keys.mode];
    if (mode == null || mode == ElicitationMode.form.name) {
      if (!supportsFormElicitation) {
        throw _missingClientCapability(
          'elicitation.form',
          ClientCapabilities(elicitation: ElicitationCapability(form: {})),
        );
      }
    } else if (mode == ElicitationMode.url.name) {
      if (!supportsUrlElicitation) {
        throw _missingClientCapability(
          'elicitation.url',
          ClientCapabilities(elicitation: ElicitationCapability(url: {})),
        );
      }
    } else if (!supportsElicitation) {
      throw _missingClientCapability(
        'elicitation',
        ClientCapabilities(elicitation: ElicitationCapability()),
      );
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
