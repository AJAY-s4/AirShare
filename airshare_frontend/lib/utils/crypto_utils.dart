import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';

class CryptoUtils {
  static Key _getKey(String pin) {
    // Pad PIN to 32 chars for AES-256
    final paddedPin = pin.padRight(32, '0');
    return Key.fromUtf8(paddedPin);
  }

  static IV _getIV(String pin) {
    // Pad PIN to 16 chars for IV
    final paddedPin = pin.padRight(16, '1');
    return IV.fromUtf8(paddedPin);
  }

  static Encrypter _getEncrypter(String pin) {
    return Encrypter(AES(_getKey(pin), mode: AESMode.cbc));
  }

  static Uint8List encryptChunk(Uint8List chunk, String pin) {
    final encrypter = _getEncrypter(pin);
    final encrypted = encrypter.encryptBytes(chunk, iv: _getIV(pin));
    return encrypted.bytes;
  }

  static Uint8List decryptChunk(Uint8List encryptedBytes, String pin) {
    final encrypter = _getEncrypter(pin);
    final decrypted = encrypter.decryptBytes(Encrypted(encryptedBytes), iv: _getIV(pin));
    return Uint8List.fromList(decrypted);
  }
}
