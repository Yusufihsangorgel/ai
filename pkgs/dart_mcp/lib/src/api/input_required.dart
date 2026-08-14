// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'api.dart';

/// A request an [InputRequiredResult] carries, written the way the schema
/// writes it: the method name next to the request it applies to.
///
/// The schema names [ElicitRequest], [CreateMessageRequest] and
/// [ListRootsRequest] here and nothing else, which is what the three
/// constructors cover. Reading one back, dispatch on [method] and then read
/// [params] as the matching type.
///
/// From the 2026-07-28 revision.
extension type InputRequest.fromMap(Map<String, Object?> _value) {
  factory InputRequest.elicit(ElicitRequest request) => InputRequest.fromMap({
    Keys.method: ElicitRequest.methodName,
    Keys.params: request,
  });

  factory InputRequest.sample(CreateMessageRequest request) =>
      InputRequest.fromMap({
        Keys.method: CreateMessageRequest.methodName,
        Keys.params: request,
      });

  factory InputRequest.listRoots(ListRootsRequest request) =>
      InputRequest.fromMap({
        Keys.method: ListRootsRequest.methodName,
        Keys.params: request,
      });

  /// The method this request is made under.
  String? get method => _value[Keys.method] as String?;

  /// The request itself, which [method] says how to read.
  Request? get params => _value[Keys.params] as Request?;
}

/// Sent by a server in place of the result a request asked for, when it needs
/// something from the client first.
///
/// The schema answers with one on `tools/call`, `prompts/get` and
/// `resources/read`, and [Result.resultType] reads
/// [ResultTypes.inputRequired] on it. The client answers the [inputRequests]
/// and then sends the original request again, with the answers and the
/// [requestState] attached. That retry is a new request, so this result ends
/// the exchange it belongs to.
///
/// The schema wants at least one of [inputRequests] and [requestState], since
/// a result carrying neither asks for nothing and hands back nothing to retry
/// with. The constructor asserts it; [InputRequiredResult.fromMap] reads
/// whatever a server sent.
///
/// From the 2026-07-28 revision.
extension type InputRequiredResult.fromMap(Map<String, Object?> _value)
    implements Result {
  factory InputRequiredResult({
    Map<String, InputRequest>? inputRequests,
    String? requestState,
  }) {
    assert(
      inputRequests != null || requestState != null,
      'The schema requires at least one of `inputRequests` and `requestState`.',
    );
    return InputRequiredResult.fromMap({
      Keys.resultType: ResultTypes.inputRequired,
      if (inputRequests != null) Keys.inputRequests: inputRequests,
      if (requestState != null) Keys.requestState: requestState,
    });
  }

  /// The requests the server issued, keyed by the name the client answers each
  /// one under.
  ///
  /// The keys are the server's own identifiers, and the answers go back under
  /// the same ones.
  Map<String, InputRequest>? get inputRequests =>
      (_value[Keys.inputRequests] as Map?)?.cast<String, InputRequest>();

  /// State the server wants back when the client retries the request.
  ///
  /// This is opaque to the client, which sends it on unread.
  String? get requestState => _value[Keys.requestState] as String?;
}
