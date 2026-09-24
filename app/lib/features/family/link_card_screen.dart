import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/bank.dart';
import '../../data/db.dart';
import '../../nfc/card_reader.dart';
import '../../ui/widgets.dart';

/// Link a card to a child. A card from a factory batch already carries a link: it is just
/// activated (maybe with the code from the pack). A blank card gets a new link written.
class LinkCardScreen extends ConsumerStatefulWidget {
  const LinkCardScreen({super.key, required this.playerId});

  final String playerId;

  @override
  ConsumerState<LinkCardScreen> createState() => _LinkCardScreenState();
}

class _LinkCardScreenState extends ConsumerState<LinkCardScreen> {
  final _code = TextEditingController();
  String _status = '';
  bool _busy = false;
  CardTap? _pendingTap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_busy) return;
    final s = ref.read(servicesProvider);
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      var tap = await s.reader.read(prompt: 'Поднесите новую карту');
      if (tap.token == null) {
        // Blank card: get a token from the server and write the link onto the card.
        setState(() => _status = 'Записываем карту… держите её у телефона');
        final prepared = await s.api.post('/cards/prepare') as Map<String, dynamic>;
        final written = await s.reader.write(prepared['url'] as String, prompt: 'Держите карту у телефона — записываем');
        tap = CardTap(token: prepared['token'] as String, uid: written.uid ?? tap.uid);
      }
      await _activate(tap);
    } on NfcCancelled {
      setState(() => _status = '');
    } on NfcUnavailable catch (e) {
      setState(() => _status = e.disabled ? 'Включите NFC в настройках телефона' : 'На этом телефоне нет NFC');
    } on NfcWriteError catch (e) {
      setState(() => _status = e.message);
    } on Exception catch (e) {
      setState(() => _status = describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(CardTap tap) async {
    final s = ref.read(servicesProvider);
    try {
      await s.api.post('/cards/activate', {
        'token': tap.token,
        if (tap.uid != null) 'uid': tap.uid,
        'player_id': widget.playerId,
        if (_code.text.trim().isNotEmpty) 'activation_code': _code.text.trim().replaceAll('-', ''),
      });
    } on ApiError catch (e) {
      if (e.code == 'invalid_activation_code') {
        _pendingTap = tap;
        setState(() => _status = _code.text.isEmpty ? 'Введите код с упаковки карты' : e.message);
        return;
      }
      rethrow;
    }
    await s.sync.sync();
    if (!mounted) return;
    toast(context, 'Карта привязана');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final player = (ref.watch(playersProvider).value ?? const <Player>[]).where((p) => p.id == widget.playerId).firstOrNull;
    final name = player?.name ?? '';
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
          Row(children: [const CircleBack(), const SizedBox(width: 12), Text('Привязка карты', style: T.small.copyWith(fontSize: 14))]),
          const SizedBox(height: 24),
          Text('Новая карта для ${name.isEmpty ? 'ребёнка' : genitive(name)}', style: T.h1),
          const SizedBox(height: 28),
          const Center(child: _CardArt()),
          const SizedBox(height: 28),
          const Text('Приложите карту к задней панели телефона', textAlign: TextAlign.center, style: T.h3),
          const SizedBox(height: 8),
          const Text('Держите, пока телефон не завибрирует. На iPhone — к верхнему краю.',
              textAlign: TextAlign.center, style: T.secondary),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(_status, textAlign: TextAlign.center, style: T.bodyBold.copyWith(color: C.red)),
          ],
          const SizedBox(height: 24),
          const Text('Код с упаковки, если он есть', style: T.label),
          const SizedBox(height: 8),
          TextField(controller: _code, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(hintText: 'XXXX-XXXX')),
          const SizedBox(height: 24),
          if (_pendingTap != null)
            Btn('Привязать с кодом', busy: _busy, onPressed: () => _activate(_pendingTap!).catchError((Object e) {
                  if (mounted) setState(() => _status = describe(e));
                }))
          else
            Btn(_busy ? 'Ждём карту…' : 'Приложить ещё раз', busy: _busy, onPressed: _start),
          const SizedBox(height: 10),
          Btn('Отмена', kind: BtnKind.outline, onPressed: () {
            ref.read(servicesProvider).reader.stop();
            Navigator.pop(context);
          }),
        ]),
      ),
    );
  }
}

class _CardArt extends StatelessWidget {
  const _CardArt();

  @override
  Widget build(BuildContext context) => Container(
        width: 260,
        height: 260,
        decoration: const BoxDecoration(color: C.surfaceSand, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Container(
          width: 190,
          height: 190,
          decoration: const BoxDecoration(color: C.border, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Transform.rotate(
            angle: -0.12,
            child: Container(
              width: 180,
              height: 112,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: C.green,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [BoxShadow(color: Color(0x2E1F2430), blurRadius: 20, offset: Offset(0, 10))],
              ),
              child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('ФантикПэй', style: TextStyle(fontFamily: 'Unbounded', color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13))),
                  NfcBadge(size: 18),
                ]),
                Spacer(),
                Coin(size: 26),
              ]),
            ),
          ),
        ),
      );
}
