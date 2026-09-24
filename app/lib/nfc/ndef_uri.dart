import 'dart:convert';
import 'dart:typed_data';

import 'package:nfc_manager/ndef_record.dart';

import '../core/config.dart';

/// NFC Forum URI record prefixes (first payload byte).
const _prefixes = [
  '', 'http://www.', 'https://www.', 'http://', 'https://', 'tel:', 'mailto:', //
];

NdefMessage cardMessage(String url) {
  var code = 0;
  var rest = url;
  for (var i = _prefixes.length - 1; i > 0; i--) {
    if (url.startsWith(_prefixes[i])) {
      code = i;
      rest = url.substring(_prefixes[i].length);
      break;
    }
  }
  return NdefMessage(records: [
    NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList([0x55]), // 'U'
      identifier: Uint8List(0),
      payload: Uint8List.fromList([code, ...utf8.encode(rest)]),
    ),
  ]);
}

String? uriOf(NdefRecord record) {
  if (record.typeNameFormat != TypeNameFormat.wellKnown) return null;
  if (record.type.length != 1 || record.type[0] != 0x55 || record.payload.isEmpty) return null;
  final code = record.payload[0];
  final prefix = code < _prefixes.length ? _prefixes[code] : '';
  return prefix + utf8.decode(record.payload.sublist(1), allowMalformed: true);
}

/// `https://fantikpay.ru/c/<token>` -> token.
String? tokenFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !Config.cardHosts.contains(uri.host)) return null;
  final segments = uri.pathSegments;
  if (segments.length == 2 && segments[0] == 'c' && RegExp(r'^[A-Za-z0-9]{6,32}$').hasMatch(segments[1])) {
    return segments[1];
  }
  return null;
}

String? tokenFromMessage(NdefMessage? message) {
  if (message == null) return null;
  for (final record in message.records) {
    final uri = uriOf(record);
    final token = uri == null ? null : tokenFromUrl(uri);
    if (token != null) return token;
  }
  return null;
}

String hexUid(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
