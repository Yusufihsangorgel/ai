// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Adds integrity protection to multi round-trip `requestState` values.
///
/// A client sends these values back without reading them. A server must still
/// treat the returned value as untrusted input. The [seal] method adds an
/// HMAC-SHA256 tag and [open] rejects modified, expired, or incorrectly bound
/// values.
///
/// Callers can bind a value to the authenticated caller and the original
/// request with `associatedData`. Pass the same bytes to [seal] and [open].
/// They affect the tag but are not stored in the result.
///
/// The payload is signed, not encrypted. Do not put secrets in it.
///
/// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr#server-requirements-basic-workflow
final class RequestStateCodec {
  /// Creates a codec backed by [key].
  ///
  /// The key is copied and must contain at least [minimumKeyLength] bytes.
  /// It must be kept secret and generated with a cryptographically secure
  /// random number generator.
  /// The default [timeToLive] is ten minutes. Pass `null` to omit expiry.
  /// The default [maxStateLength] is four MiB. The default [clock] reads the
  /// current system time. Pass a function to control time in tests.
  RequestStateCodec(
    List<int> key, {
    this.timeToLive = const Duration(minutes: 10),
    this.maxStateLength = 4 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (key.length < minimumKeyLength) {
      throw RangeError.range(key.length, minimumKeyLength, null, 'key.length');
    }
    if (timeToLive?.isNegative == true) {
      throw ArgumentError.value(timeToLive, 'timeToLive');
    }
    RangeError.checkNotNegative(maxStateLength, 'maxStateLength');
    _hmac = Hmac(sha256, List<int>.unmodifiable(key));
  }

  /// The minimum accepted HMAC key length in bytes.
  static const minimumKeyLength = 32;

  /// How long a value remains valid, or `null` for no expiry.
  final Duration? timeToLive;

  /// The maximum accepted or produced `requestState` length.
  final int maxStateLength;

  late final Hmac _hmac;
  final DateTime Function() _clock;

  static const _version = 'rs1';

  /// The message used for every wire or verification failure.
  static const invalidMessage = 'Invalid or expired requestState';

  static final _base64Url = RegExp(r'^[A-Za-z0-9_-]+$');
  static final _domain = utf8.encode('dart_mcp/requestState/rs1');

  /// Seals [payload] into the opaque string to return as `requestState`.
  String seal(String payload, {List<int> associatedData = const []}) {
    final ttl = timeToLive;
    final expiresAt =
        ttl == null
            ? null
            : _clock().millisecondsSinceEpoch + ttl.inMilliseconds;
    final body = _encode(
      utf8.encode(
        jsonEncode({'p': payload, if (expiresAt != null) 'e': expiresAt}),
      ),
    );
    final tag = _encode(_mac(body, associatedData).bytes);
    final state = '$_version.$body.$tag';
    if (state.length > maxStateLength) {
      throw ArgumentError(
        'The sealed requestState exceeds maxStateLength.',
        'payload',
      );
    }
    return state;
  }

  /// Verifies [state] and returns the payload passed to [seal].
  ///
  /// A [FormatException] with a fixed message is thrown for every wire or
  /// verification failure.
  String open(String state, {List<int> associatedData = const []}) {
    try {
      if (state.length > maxStateLength) {
        throw const FormatException();
      }
      final sections = state.split('.');
      if (sections.length != 3 ||
          sections[0] != _version ||
          sections[1].isEmpty ||
          sections[2].length != 43) {
        throw const FormatException();
      }
      final body = sections[1];
      if (_mac(body, associatedData) != Digest(_decode(sections[2]))) {
        throw const FormatException();
      }
      final decoded = jsonDecode(utf8.decode(_decode(body)));
      if (decoded is! Map || decoded['p'] is! String) {
        throw const FormatException();
      }
      final expiresAt = decoded['e'];
      if (expiresAt != null &&
          (expiresAt is! int || expiresAt <= _clock().millisecondsSinceEpoch)) {
        throw const FormatException();
      }
      return decoded['p'] as String;
    } on FormatException {
      throw const FormatException(invalidMessage);
    }
  }

  Digest _mac(String body, List<int> associatedData) => _hmac.convert([
    ..._domain,
    0,
    ...utf8.encode(body),
    0,
    ...associatedData,
  ]);

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static List<int> _decode(String value) {
    if (!_base64Url.hasMatch(value) || value.length % 4 == 1) {
      throw const FormatException();
    }
    final padding = (4 - value.length % 4) % 4;
    final decoded = base64Url.decode(
      value.padRight(value.length + padding, '='),
    );
    return decoded;
  }
}
