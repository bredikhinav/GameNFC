import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import '../data/bank.dart';
import 'ndef_uri.dart';

class NfcUnavailable implements Exception {
  const NfcUnavailable(this.disabled);

  /// True if the phone has NFC but it is switched off.
  final bool disabled;
}

class NfcCancelled implements Exception {
  const NfcCancelled();
}

class NfcWriteError implements Exception {
  const NfcWriteError(this.message);

  final String message;
}

/// Reading and writing FantikPay cards. On iPhone every read shows the system
/// "hold near reader" sheet, so screens start a read only when the operator is ready.
abstract class CardReader {
  Future<void> ensureAvailable();

  /// One tap.
  Future<CardTap> read({String prompt = 'Поднесите карту к телефону'});

  /// Taps one after another until [stop] (lobby: players join by turns).
  Stream<CardTap> readMany({String prompt = 'Прикладывайте карты по очереди'});

  /// Write `url` to a blank card; returns the chip UID.
  Future<CardTap> write(String url, {String prompt = 'Поднесите новую карту'});

  Future<void> stop({String? message, String? error});
}

class NfcCardReader implements CardReader {
  final _nfc = NfcManager.instance;

  @override
  Future<void> ensureAvailable() async {
    final availability = await _nfc.checkAvailability();
    if (availability == NfcAvailability.enabled) return;
    throw NfcUnavailable(availability == NfcAvailability.disabled);
  }

  static String? _uid(NfcTag tag) {
    if (Platform.isAndroid) {
      final t = NfcTagAndroid.from(tag);
      return t == null ? null : hexUid(t.id);
    }
    final mifare = MiFareIos.from(tag);
    return mifare == null ? null : hexUid(mifare.identifier);
  }

  static Future<String?> _token(NfcTag tag) async {
    if (Platform.isAndroid) {
      final ndef = NdefAndroid.from(tag);
      return tokenFromMessage(ndef?.cachedNdefMessage ?? await ndef?.getNdefMessage());
    }
    final ndef = NdefIos.from(tag);
    return tokenFromMessage(ndef?.cachedNdefMessage ?? await ndef?.readNdef());
  }

  static Future<CardTap> _tap(NfcTag tag) async {
    String? token;
    try {
      token = await _token(tag);
    } on Exception {
      token = null; // card moved away too early, or no NDEF: fall back to the UID
    }
    return CardTap(token: token, uid: _uid(tag));
  }

  void _start({
    required String prompt,
    required bool many,
    required Future<void> Function(NfcTag tag) onTag,
    required void Function(Object error) onError,
  }) {
    _nfc.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      alertMessageIos: prompt,
      invalidateAfterFirstReadIos: !many,
      onSessionErrorIos: (e) => onError(
        e.code == NfcReaderErrorCodeIos.readerSessionInvalidationErrorUserCanceled ? const NfcCancelled() : e,
      ),
      onDiscovered: (tag) => onTag(tag).catchError(onError),
    );
  }

  @override
  Future<CardTap> read({String prompt = 'Поднесите карту к телефону'}) async {
    await ensureAvailable();
    final done = Completer<CardTap>();
    _start(
      prompt: prompt,
      many: false,
      onTag: (tag) async {
        final tap = await _tap(tag);
        if (!done.isCompleted) done.complete(tap);
        await _nfc.stopSession(alertMessageIos: 'Готово');
      },
      onError: (e) {
        if (!done.isCompleted) done.completeError(e);
      },
    );
    return done.future;
  }

  @override
  Stream<CardTap> readMany({String prompt = 'Прикладывайте карты по очереди'}) {
    late StreamController<CardTap> controller;
    String? last;
    var lastAt = DateTime(0);
    controller = StreamController<CardTap>(
      onListen: () async {
        try {
          await ensureAvailable();
        } on NfcUnavailable catch (e) {
          controller.addError(e);
          return;
        }
        _start(
          prompt: prompt,
          many: true,
          onTag: (tag) async {
            final tap = await _tap(tag);
            final key = tap.token ?? tap.uid;
            // The same card lying on the phone is reported again and again.
            if (key == last && DateTime.now().difference(lastAt).inSeconds < 3) return;
            last = key;
            lastAt = DateTime.now();
            controller.add(tap);
          },
          onError: controller.addError,
        );
      },
      onCancel: () => _nfc.stopSession(),
    );
    return controller.stream;
  }

  @override
  Future<CardTap> write(String url, {String prompt = 'Поднесите новую карту'}) async {
    await ensureAvailable();
    final done = Completer<CardTap>();
    final message = cardMessage(url);
    _start(
      prompt: prompt,
      many: false,
      onTag: (tag) async {
        try {
          await _writeTag(tag, message);
          if (!done.isCompleted) done.complete(CardTap(token: tokenFromUrl(url), uid: _uid(tag)));
          await _nfc.stopSession(alertMessageIos: 'Карта записана');
        } on NfcWriteError catch (e) {
          if (!done.isCompleted) done.completeError(e);
          await _nfc.stopSession(errorMessageIos: e.message);
        }
      },
      onError: (e) {
        if (!done.isCompleted) done.completeError(e);
      },
    );
    return done.future;
  }

  static Future<void> _writeTag(NfcTag tag, NdefMessage message) async {
    if (Platform.isAndroid) {
      final ndef = NdefAndroid.from(tag);
      if (ndef != null) {
        if (!ndef.isWritable) throw const NfcWriteError('Карта защищена от записи');
        if (ndef.maxSize < message.byteLength) throw const NfcWriteError('Карта слишком маленькая');
        await ndef.writeNdefMessage(message);
        return;
      }
      final formatable = NdefFormatableAndroid.from(tag);
      if (formatable != null) {
        await formatable.format(message);
        return;
      }
      throw const NfcWriteError('Эта карта не поддерживает NDEF');
    }
    final ndef = NdefIos.from(tag);
    if (ndef == null) throw const NfcWriteError('Эта карта не поддерживает NDEF');
    final status = await ndef.queryNdefStatus();
    if (status.status == NdefStatusIos.readOnly) throw const NfcWriteError('Карта защищена от записи');
    if (status.status == NdefStatusIos.notSupported) throw const NfcWriteError('Эта карта не поддерживает NDEF');
    if (status.capacity < message.byteLength) throw const NfcWriteError('Карта слишком маленькая');
    await ndef.writeNdef(message);
  }

  @override
  Future<void> stop({String? message, String? error}) =>
      _nfc.stopSession(alertMessageIos: message, errorMessageIos: error);
}

/// For emulators and demos without cards: the operator types or picks a card token.
class DebugCardReader implements CardReader {
  DebugCardReader(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  StreamController<CardTap>? _many;

  Future<CardTap> _ask(String prompt, {String? preset}) async {
    final context = navigatorKey.currentContext;
    if (context == null) throw const NfcCancelled();
    final controller = TextEditingController(text: preset);
    final token = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(prompt),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Токен карты или UID'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Приложить')),
        ],
      ),
    );
    if (token == null || token.isEmpty) throw const NfcCancelled();
    final isUid = RegExp(r'^[0-9A-Fa-f]{14}$').hasMatch(token);
    return isUid ? CardTap(uid: token.toUpperCase()) : CardTap(token: token);
  }

  @override
  Future<void> ensureAvailable() async {}

  @override
  Future<CardTap> read({String prompt = 'Поднесите карту к телефону'}) => _ask(prompt);

  @override
  Stream<CardTap> readMany({String prompt = 'Прикладывайте карты по очереди'}) {
    final controller = StreamController<CardTap>();
    _many = controller;
    Future<void> loop() async {
      while (!controller.isClosed) {
        try {
          controller.add(await _ask(prompt));
        } on NfcCancelled {
          await controller.close();
        }
      }
    }

    controller.onListen = loop;
    return controller.stream;
  }

  @override
  Future<CardTap> write(String url, {String prompt = 'Поднесите новую карту'}) async {
    await _ask('$prompt (эмуляция записи)', preset: tokenFromUrl(url));
    return CardTap(token: tokenFromUrl(url));
  }

  @override
  Future<void> stop({String? message, String? error}) async {
    await _many?.close();
  }
}
