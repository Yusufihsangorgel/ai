// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../utils/analytics.dart';
import '../utils/names.dart';

/// A mixin which intercepts various MCP calls to track analytics.
base mixin AnalyticsEvents
    on ToolsSupport, PromptsSupport, ResourcesSupport, LoggingSupport
    implements AnalyticsSupport {
  @override
  /// Tracks [initialize] calls, so we can detect clients that connect but
  /// never interact with the server directly.
  Future<void> initialize(MCPServerInitialization initialization) async {
    // This comes first, so the event carries the client implementation.
    await super.initialize(initialization);
    final event = _createDartMCPEvent(
      type: AnalyticsEvent.initialize.name,
      additionalData: InitializeMetrics(
        supportsElicitation:
            initialization.clientCapabilities.elicitation != null,
        supportsRoots: initialization.clientCapabilities.roots != null,
        supportsSampling: initialization.clientCapabilities.sampling != null,
      ),
    );
    if (event != null) analytics?.send(event);
  }

  @override
  FutureOr<ListPromptsResult> listPrompts([ListPromptsRequest? request]) {
    trySendAnalyticsEvent(
      _createDartMCPEvent(type: AnalyticsEvent.listPrompts.name),
    );
    return super.listPrompts(request);
  }

  @override
  Future<GetPromptResponse> getPrompt(GetPromptRequest request) async {
    final watch = Stopwatch()..start();
    GetPromptResponse? response;
    try {
      return response = await super.getPrompt(request);
    } finally {
      watch.stop();
      // A response asking for input carries no messages, so it counts the way
      // a thrown error does.
      final result = response == null || response.isInputRequired
          ? null
          : response as GetPromptResult;
      trySendAnalyticsEvent(
        _createDartMCPEvent(
          type: AnalyticsEvent.getPrompt.name,
          additionalData: GetPromptMetrics(
            name: request.name,
            success: result != null && result.messages.isNotEmpty,
            elapsedMilliseconds: watch.elapsedMilliseconds,
            withArguments: request.arguments?.isNotEmpty == true,
          ),
        ),
      );
    }
  }

  @override
  FutureOr<ListResourcesResult> listResources([ListResourcesRequest? request]) {
    trySendAnalyticsEvent(
      _createDartMCPEvent(type: AnalyticsEvent.listResources.name),
    );
    return super.listResources(request);
  }

  @override
  FutureOr<ListResourceTemplatesResult> listResourceTemplates([
    ListResourceTemplatesRequest? request,
  ]) {
    trySendAnalyticsEvent(
      _createDartMCPEvent(type: AnalyticsEvent.listResourceTemplates.name),
    );
    return super.listResourceTemplates(request);
  }

  @override
  Future<ListToolsResult> listTools([ListToolsRequest? request]) async {
    trySendAnalyticsEvent(
      _createDartMCPEvent(type: AnalyticsEvent.listTools.name),
    );
    return super.listTools(request);
  }

  @override
  /// We override this with our own validation and error handling for analytics
  /// purposes.
  void registerTool(
    Tool tool,
    FutureOr<CallToolResponse> Function(CallToolRequest) impl, {
    bool validateArguments = true,
  }) {
    super.registerTool(tool, (request) async {
      final watch = Stopwatch()..start();
      CallToolResponse? response;
      if (validateArguments) {
        final errors = tool.inputSchema.validate(
          request.arguments ?? const <String, Object?>{},
        );
        if (errors.isNotEmpty) {
          response = CallToolResult(
            content: [
              Content.text(
                text:
                    'Invalid tool arguments, make sure to read the schema '
                    'and try again:',
              ),
              for (final error in errors)
                Content.text(text: error.toErrorString()),
            ],
            isError: true,
          )..failureReason = CallToolFailureReason.argumentError;
        }
      }
      String? errorType;
      try {
        // Only call the tool if we don't already have an error result.
        return response ??= await impl(request);
      } catch (e) {
        errorType = e.runtimeType.toString();
        rethrow;
      } finally {
        watch.stop();
        var toolName = request.name;
        if (request.arguments?[ParameterNames.command]
            case final String command) {
          toolName += '.$command';
        }
        // A response asking for input has not finished the call, so it counts
        // the way a thrown error does.
        final result = response == null || response.isInputRequired
            ? null
            : response as CallToolResult;
        trySendAnalyticsEvent(
          _createDartMCPEvent(
            type: AnalyticsEvent.callTool.name,
            additionalData: CallToolMetrics(
              tool: toolName,
              success: result != null && result.isError != true,
              elapsedMilliseconds: watch.elapsedMilliseconds,
              failureReason:
                  result?.failureReason ??
                  (errorType != null
                      ? CallToolFailureReason.unhandledError
                      : null),
              extraToolMetrics: result?.customMetrics,
              errorType: errorType,
            ),
          ),
        );
      }
    }, validateArguments: false);
  }

  /// The analytics event for [type], or `null` when the client declared no
  /// implementation.
  ///
  /// `client` and `clientVersion` are required fields of
  /// [Event.dartMCPEvent], so an event for a client that named itself nothing
  /// would have to invent both. It is dropped instead.
  Event? _createDartMCPEvent({
    required String type,
    CustomMetrics? additionalData,
  }) {
    final info = clientInfo;
    if (info == null) return null;
    return Event.dartMCPEvent(
      client: info.name,
      clientVersion: info.version,
      serverVersion: implementation.version,
      type: type,
      agentPlugin: agentPlugin,
      additionalData: additionalData,
    );
  }

  /// Sends [event], if there is one, and logs rather than throws on failure.
  void trySendAnalyticsEvent(Event? event) {
    if (event == null) return;
    try {
      analytics?.send(event);
    } catch (e) {
      log(LoggingLevel.warning, 'Error sending analytics event: $e');
    }
  }
}
