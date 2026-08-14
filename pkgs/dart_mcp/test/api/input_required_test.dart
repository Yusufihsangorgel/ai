// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_mcp/client.dart';
import 'package:test/test.dart';

void main() {
  group('InputRequest', () {
    test('writes the method next to the request', () {
      final request = CreateMessageRequest(messages: [], maxTokens: 1);

      expect(InputRequest.sample(request) as Map<String, Object?>, {
        'method': 'sampling/createMessage',
        'params': request,
      });
    });

    test('names the method each kind is made under', () {
      expect(InputRequest.listRoots(ListRootsRequest()).method, 'roots/list');
      expect(
        InputRequest.sample(
          CreateMessageRequest(messages: [], maxTokens: 1),
        ).method,
        'sampling/createMessage',
      );
      expect(
        InputRequest.elicit(
          ElicitRequest.form(
            message: 'What is your name?',
            requestedSchema: ObjectSchema(
              properties: {'name': StringSchema()},
              required: ['name'],
            ),
          ),
        ).method,
        'elicitation/create',
      );
    });

    test('reads back a request a server sent', () {
      final request = InputRequest.fromMap({
        'method': 'roots/list',
        'params': <String, Object?>{},
      });

      expect(request.method, 'roots/list');
      expect(request.params as Map<String, Object?>?, isEmpty);
    });
  });

  group('InputRequiredResult', () {
    test('marks itself as the interim result type', () {
      expect(
        InputRequiredResult(requestState: 'opaque').resultType,
        'input_required',
      );
    });

    test('writes only the fields it is given', () {
      expect(
        InputRequiredResult(requestState: 'opaque') as Map<String, Object?>,
        {'resultType': 'input_required', 'requestState': 'opaque'},
      );
      expect(
        InputRequiredResult(
              inputRequests: {
                'roots': InputRequest.listRoots(ListRootsRequest()),
              },
            )
            as Map<String, Object?>,
        {
          'resultType': 'input_required',
          'inputRequests': {
            'roots': {'method': 'roots/list', 'params': <String, Object?>{}},
          },
        },
      );
    });

    test('reads back the requests a server sent', () {
      final result = InputRequiredResult.fromMap({
        'resultType': 'input_required',
        'inputRequests': {
          'roots': {'method': 'roots/list', 'params': <String, Object?>{}},
        },
        'requestState': 'opaque',
      });

      expect(result.inputRequests, hasLength(1));
      expect(result.inputRequests!['roots']!.method, 'roots/list');
      expect(result.requestState, 'opaque');
    });

    test('leaves both fields null when a server omits them', () {
      final result = InputRequiredResult.fromMap({
        'resultType': 'input_required',
      });

      expect(result.inputRequests, isNull);
      expect(result.requestState, isNull);
    });

    test('rejects a result which carries neither field', () {
      expect(InputRequiredResult.new, throwsA(isA<AssertionError>()));
      // A compiled executable has asserts stripped, so there is nothing to
      // catch there.
    }, testOn: '!exe');
  });
}
