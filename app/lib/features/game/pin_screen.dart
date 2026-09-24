import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/pin.dart';
import '../../core/storage.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// Ask for the adult PIN. Returns true if it matches or if no PIN has been set yet.
Future<bool> askPin(BuildContext context, WidgetRef ref, {String reason = 'Нужен, чтобы выйти из режима банка или отменить операцию'}) async {
  final raw = await ref.read(servicesProvider).store.read(Keys.pin);
  if (raw == null) return true;
  if (!context.mounted) return false;
  final pin = PinHash.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => PinScreen(pin: pin, reason: reason)),
  );
  return ok ?? false;
}

class PinScreen extends StatefulWidget {
  const PinScreen({super.key, required this.pin, required this.reason});

  final PinHash pin;
  final String reason;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _entered = '';
  int _attempts = 0;
  DateTime? _lockedUntil;
  bool _wrong = false;

  static const _length = 4;

  void _digit(String d) {
    if (_lockedUntil != null && DateTime.now().isBefore(_lockedUntil!)) return;
    if (_entered.length >= _length) return;
    setState(() {
      _wrong = false;
      _entered += d;
    });
    if (_entered.length == _length) _check();
  }

  Future<void> _check() async {
    // PBKDF2 takes a moment; let the last dot render first.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (widget.pin.verify(_entered)) {
      if (mounted) Navigator.pop(context, true);
      return;
    }
    HapticFeedback.heavyImpact();
    _attempts++;
    setState(() {
      _wrong = true;
      _entered = '';
      if (_attempts % 5 == 0) _lockedUntil = DateTime.now().add(const Duration(seconds: 30));
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockedUntil != null && DateTime.now().isBefore(_lockedUntil!);
    return Scaffold(
      backgroundColor: C.ink,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            const SizedBox(height: 48),
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(color: Color(0xFF2E3444), shape: BoxShape.circle),
              child: const Icon(Icons.lock_outline_rounded, color: Colors.white),
            ),
            const SizedBox(height: 20),
            Text('Код взрослого', style: T.h2.copyWith(color: Colors.white)),
            const SizedBox(height: 8),
            Text(
              locked ? 'Слишком много попыток. Подождите 30 секунд' : (_wrong ? 'Неверный код' : widget.reason),
              textAlign: TextAlign.center,
              style: T.secondary.copyWith(color: _wrong || locked ? C.coin : const Color(0xFFC9C6BF)),
            ),
            const SizedBox(height: 28),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < _length; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 9),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _entered.length ? C.coin : Colors.transparent,
                    border: Border.all(color: i < _entered.length ? C.coin : const Color(0xFF6B7080), width: 2),
                  ),
                ),
            ]),
            const Spacer(),
            Keypad(
              dark: true,
              doubleZero: false,
              keyHeight: 64,
              onDigit: _digit,
              onBackspace: () => setState(() => _entered = _entered.isEmpty ? '' : _entered.substring(0, _entered.length - 1)),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Вернуться в игру', style: T.bodyBold.copyWith(color: C.coin, decoration: TextDecoration.underline, decorationColor: C.coin)),
            ),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
  }
}
