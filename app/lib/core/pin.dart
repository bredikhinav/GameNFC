import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256, the same parameters as the server, so the PIN works offline.
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations, [int length = 32]) {
  final hmac = Hmac(sha256, password);
  final out = BytesBuilder();
  var block = 1;
  while (out.length < length) {
    final blockIndex = ByteData(4)..setUint32(0, block);
    var u = hmac.convert([...salt, ...blockIndex.buffer.asUint8List()]).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
    block++;
  }
  return out.toBytes().sublist(0, length);
}

class PinHash {
  const PinHash({required this.salt, required this.hash, required this.iterations});

  final String salt;
  final String hash;
  final int iterations;

  factory PinHash.fromJson(Map<String, dynamic> j) =>
      PinHash(salt: j['salt'] as String, hash: j['hash'] as String, iterations: j['iterations'] as int);

  Map<String, dynamic> toJson() => {'salt': salt, 'hash': hash, 'iterations': iterations};

  bool verify(String pin) {
    final digest = pbkdf2(utf8.encode(pin), base64.decode(salt), iterations);
    return base64.encode(digest) == hash;
  }
}
