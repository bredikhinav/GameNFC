import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';

/// Shows a one-time QR code that turns a child's phone into "Игрок" mode for this child.
class DeviceLinkScreen extends ConsumerStatefulWidget {
  const DeviceLinkScreen({super.key, required this.playerId});

  final String playerId;

  @override
  ConsumerState<DeviceLinkScreen> createState() => _DeviceLinkScreenState();
}

class _DeviceLinkScreenState extends ConsumerState<DeviceLinkScreen> {
  Map<String, dynamic>? _link;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _create();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    try {
      final link = await ref.read(servicesProvider).api.post('/players/${widget.playerId}/device-link');
      setState(() {
        _link = link as Map<String, dynamic>;
        _error = null;
      });
    } on Exception catch (e) {
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = (ref.watch(playersProvider).value ?? const <Player>[]).where((p) => p.id == widget.playerId).firstOrNull;
    final space = ref.watch(spaceProvider);
    final expires = _link == null ? null : DateTime.parse(_link!['expires_at'] as String);
    final left = expires?.difference(DateTime.now());
    final expired = left != null && left.isNegative;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          ScreenHeader('Телефон ${player == null ? 'ребёнка' : genitive(player.name)}'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text(
                'Установите «ФантикПэй» на телефон ребёнка, выберите «У меня QR-код от родителя» и наведите камеру.',
                style: T.secondary,
              ),
              const SizedBox(height: 16),
              Panel(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  if (_error != null)
                    Text(describe(_error!), style: T.bodyBold.copyWith(color: C.red))
                  else if (_link == null)
                    const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()))
                  else if (expired)
                    Btn('Показать новый код', onPressed: _create)
                  else ...[
                    QrImageView(data: _link!['qr_payload'] as String, size: 220, eyeStyle: const QrEyeStyle(color: C.ink, eyeShape: QrEyeShape.square), dataModuleStyle: const QrDataModuleStyle(color: C.ink)),
                    const SizedBox(height: 12),
                    Text(_link!['code'] as String, style: T.h3.copyWith(letterSpacing: 4)),
                    const SizedBox(height: 4),
                    Text('Код действует ещё ${left!.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}', style: T.label),
                  ],
                ]),
              ),
              const SizedBox(height: 20),
              const Text('Что сможет ребёнок', style: T.title),
              const SizedBox(height: 10),
              InfoRows([
                ('Видеть баланс и историю', const Icon(Icons.check_rounded, color: C.green)),
                (
                  space.dailyTransferLimit == null ? 'Переводить без дневного лимита' : 'Переводить до ${space.dailyTransferLimit} в день',
                  const Icon(Icons.check_rounded, color: C.green),
                ),
                if (space.approvalThreshold != null)
                  ('Больше ${space.approvalThreshold} — с вашим подтверждением', const Icon(Icons.check_rounded, color: C.green)),
              ]),
              const SizedBox(height: 8),
              const Text('Лимиты меняются в «Настройки → Правила и начисления».', style: T.small),
            ]),
          ),
        ]),
      ),
    );
  }
}
