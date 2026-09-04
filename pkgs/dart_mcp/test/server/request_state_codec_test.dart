// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

final _key = List<int>.generate(32, (index) => index);

void main() {
  group('RequestStateCodec', () {
    test('round trips a payload with matching associated data', () {
      final codec = RequestStateCodec(_key);
      final binding = utf8.encode('caller-a\u0000tools/call\u0000weather');
      final state = codec.seal('{"step":2}', associatedData: binding);

      expect(codec.open(state, associatedData: binding), '{"step":2}');
    });

    test('copies the signing key', () {
      final key = [..._key];
      final codec = RequestStateCodec(key);
      final state = codec.seal('kept');
      key.fillRange(0, key.length, 255);

      expect(codec.open(state), 'kept');
    });

    test('rejects invalid constructor arguments', () {
      expect(() => RequestStateCodec(_key.sublist(1)), throwsRangeError);
      expect(
        () => RequestStateCodec(
          _key,
          timeToLive: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
      expect(
        () => RequestStateCodec(_key, maxStateLength: -1),
        throwsRangeError,
      );
    });

    test('rejects a modified payload or tag', () {
      final codec = RequestStateCodec(_key);
      final state = codec.seal('kept');
      final sections = state.split('.');
      final changedBody = _changeFirst(sections[1]);
      final changedTag = _changeFirst(sections[2]);

      expect(
        () => codec.open('${sections[0]}.$changedBody.${sections[2]}'),
        throwsFormatException,
      );
      expect(
        () => codec.open('${sections[0]}.${sections[1]}.$changedTag'),
        throwsFormatException,
      );
    });

    test('rejects a non-canonical tag encoding', () {
      final codec = RequestStateCodec(_key);
      final sections = codec.seal('kept').split('.');
      final alias = _changePadBits(sections[2]);

      expect(
        () => codec.open('${sections[0]}.${sections[1]}.$alias'),
        throwsFormatException,
      );
    });

    test('rejects the wrong associated data', () {
      final codec = RequestStateCodec(_key);
      final state = codec.seal(
        'kept',
        associatedData: utf8.encode('caller-a\u0000tools/call'),
      );

      expect(
        () => codec.open(
          state,
          associatedData: utf8.encode('caller-b\u0000tools/call'),
        ),
        throwsFormatException,
      );
    });

    test('accepts before expiry', () {
      final issuedAt = DateTime.utc(2026);
      var now = issuedAt;
      final codec = RequestStateCodec(
        _key,
        timeToLive: const Duration(milliseconds: 10),
        clock: () => now,
      );
      final state = codec.seal('kept');

      now = issuedAt.add(const Duration(milliseconds: 9));
      expect(codec.open(state), 'kept');
    });

    test('rejects at the expiry boundary', () {
      final issuedAt = DateTime.utc(2026);
      var now = issuedAt;
      final codec = RequestStateCodec(
        _key,
        timeToLive: const Duration(milliseconds: 10),
        clock: () => now,
      );
      final state = codec.seal('kept');

      now = issuedAt.add(const Duration(milliseconds: 10));
      expect(() => codec.open(state), throwsFormatException);
    });

    test('accepts state at the length limit', () {
      final now = DateTime.utc(2026);
      final state = _sealedAt(now);
      final exact = RequestStateCodec(
        _key,
        maxStateLength: state.length,
        clock: () => now,
      );

      expect(exact.seal('kept'), state);
      expect(exact.open(state), 'kept');
    });

    test('rejects state beyond the length limit', () {
      final now = DateTime.utc(2026);
      final state = _sealedAt(now);
      final tooSmall = RequestStateCodec(
        _key,
        maxStateLength: state.length - 1,
        clock: () => now,
      );

      expect(() => tooSmall.seal('kept'), throwsArgumentError);
      expect(() => tooSmall.open(state), throwsFormatException);
    });

    test('rejects malformed values with one message', () {
      final codec = RequestStateCodec(_key);
      for (final state in ['', 'rs2.body.tag', 'rs1.body', 'rs1.%%%.tag']) {
        expect(
          () => codec.open(state),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Invalid or expired requestState.',
            ),
          ),
        );
      }
    });
  });

  test('state survives a client and server round trip', () async {
    final environment = TestEnvironment(
      TestMCPClient(),
      _RequestStateServer.new,
    );
    await environment.initializeServer();
    environment.serverConnection.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.server.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.serverConnection.inputRequiredRetryDelay = Duration.zero;

    final result = await environment.serverConnection.callTool(
      CallToolRequest(name: _RequestStateServer.tool.name),
    );

    expect((result.content.single as TextContent).text, 'phase=complete');
    expect(environment.server.calls, 2);
  });

  test('server rejects state modified at the channel boundary', () async {
    final environment = TestEnvironment(
      TestMCPClient(),
      (channel) => _RequestStateServer(
        channel.transformStream(
          StreamTransformer.fromHandlers(
            handleData: (message, sink) {
              final params = message['params'];
              final state = params is Map ? params['requestState'] : null;
              if (state is String) {
                sink.add(
                  {
                    ...message,
                    'params': {
                      ...params as Map,
                      'requestState': _changeFirst(state),
                    },
                  }.cast<String, Object?>(),
                );
              } else {
                sink.add(message);
              }
            },
          ),
        ),
      ),
    );
    await environment.initializeServer();
    environment.serverConnection.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.server.protocolVersion = ProtocolVersion.v2026_07_28;
    environment.serverConnection.inputRequiredRetryDelay = Duration.zero;

    expect(
      environment.serverConnection.callTool(
        CallToolRequest(name: _RequestStateServer.tool.name),
      ),
      throwsA(
        isA<RpcException>().having(
          (error) => error.message,
          'message',
          'Invalid requestState.',
        ),
      ),
    );
  });
}

String _changeFirst(String value) =>
    '${value[0] == 'A' ? 'B' : 'A'}${value.substring(1)}';

String _sealedAt(DateTime now) =>
    RequestStateCodec(_key, clock: () => now).seal('kept');

String _changePadBits(String value) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final index = alphabet.indexOf(value[value.length - 1]);
  return '${value.substring(0, value.length - 1)}${alphabet[index + 1]}';
}

final class _RequestStateServer extends TestMCPServer with ToolsSupport {
  _RequestStateServer(super.channel);

  static final tool = Tool(name: 'state', inputSchema: ObjectSchema());

  final _codec = RequestStateCodec(_key);
  final _binding = utf8.encode('tools/call\u0000state');
  int calls = 0;

  @override
  FutureOr<void> initialize(MCPServerInitialization initialization) {
    registerTool(tool, _call);
    return super.initialize(initialization);
  }

  CallToolResponse _call(CallToolRequest request) {
    calls++;
    final state = request.requestState;
    if (state == null) {
      return InputRequiredResult(
        requestState: _codec.seal('phase=complete', associatedData: _binding),
      );
    }
    try {
      return CallToolResult(
        content: [
          TextContent(text: _codec.open(state, associatedData: _binding)),
        ],
      );
    } on FormatException {
      throw RpcException.invalidParams('Invalid requestState.');
    }
  }
}
