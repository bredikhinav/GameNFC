import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// Child's phone: scan the QR code shown on the parent's phone.
class ClaimScreen extends ConsumerStatefulWidget {
  const ClaimScreen({super.key});

  @override
  ConsumerState<ClaimScreen> createState() => _ClaimScreenState();
}

class _ClaimScreenState extends ConsumerState<ClaimScreen> {
  final _code = TextEditingController();
  bool _busy = false;

  static String? codeFrom(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.scheme == 'fantikpay' && uri.host == 'link') return uri.queryParameters['code'];
    final plain = raw.trim().toUpperCase().replaceAll('-', '');
    return RegExp(r'^[A-Z0-9]{8}$').hasMatch(plain) ? plain : null;
  }

  Future<void> _claim(String code) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).claim(code);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(children: [
            const ScreenHeader('Телефон ребёнка'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text(
                  'Попросите родителя открыть профиль ребёнка → «Телефон ребёнка» и наведите камеру на QR-код.',
                  style: T.secondary,
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: SizedBox(
                    height: 300,
                    child: MobileScanner(
                      onDetect: (capture) {
                        for (final barcode in capture.barcodes) {
                          final code = codeFrom(barcode.rawValue ?? '');
                          if (code != null) {
                            _claim(code);
                            return;
                          }
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Или введите код с экрана родителя', style: T.label),
                const SizedBox(height: 8),
                TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(hintText: 'XXXXXXXX'),
                ),
                const SizedBox(height: 16),
                Btn('Подключить', busy: _busy, onPressed: () {
                  final code = codeFrom(_code.text);
                  if (code == null) {
                    toast(context, 'Код — 8 букв и цифр');
                  } else {
                    _claim(code);
                  }
                }),
              ]),
            ),
          ]),
        ),
      );
}
