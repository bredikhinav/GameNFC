import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/bank.dart';
import '../../data/db.dart';
import '../../nfc/card_reader.dart';
import '../../ui/widgets.dart';

/// Players tap their cards one by one; each gets a game wallet with the starting capital.
class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  StreamSubscription<CardTap>? _taps;
  String? _message;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  @override
  void dispose() {
    _taps?.cancel();
    super.dispose();
  }

  void _listen() {
    _taps?.cancel();
    setState(() {
      _reading = true;
      _message = null;
    });
    _taps = ref.read(servicesProvider).reader.readMany().listen(
      _onTap,
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _reading = false;
          _message = switch (e) {
            NfcUnavailable(disabled: true) => 'Включите NFC в настройках телефона',
            NfcUnavailable() => 'На этом телефоне нет NFC — добавляйте игроков из списка',
            NfcCancelled() => null,
            _ => 'Не удалось прочитать карту',
          };
        });
      },
      onDone: () => mounted ? setState(() => _reading = false) : null,
    );
  }

  Future<void> _onTap(CardTap tap) async {
    final bank = ref.read(bankProvider);
    try {
      final holder = await bank.identify(tap);
      await _add(holder);
    } on ApiError catch (e) {
      HapticFeedback.heavyImpact();
      setState(() => _message = e.message);
    }
  }

  Future<void> _add(Holder holder) async {
    final joined = await ref.read(bankProvider).join(widget.sessionId, holder);
    HapticFeedback.mediumImpact();
    setState(() => _message = joined ? null : '${holder.player.name} уже в игре');
  }

  Future<void> _pickFromList(List<Participant> inGame) async {
    final players = ref.read(playersProvider).value ?? const <Player>[];
    final ids = {for (final p in inGame) p.playerId};
    final free = players.where((p) => !ids.contains(p.id)).toList();
    final picked = await showModalBottomSheet<Player>(
      context: context,
      builder: (context) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 24), children: [
        const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Добавить без карты', style: T.h3)),
        if (free.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('Все игроки уже в игре', style: T.secondary)),
        for (final p in free)
          ListTile(leading: PlayerAvatar(p, size: 36), title: Text(p.name, style: T.bodyBold), onTap: () => Navigator.pop(context, p)),
      ]),
    );
    if (picked != null) await _add(await ref.read(bankProvider).holderFor(picked));
  }

  Future<void> _start(int count) async {
    await _taps?.cancel();
    await ref.read(bankProvider).setStatus(widget.sessionId, 'active');
    if (mounted) context.pushReplacement('/game/${widget.sessionId}/terminal');
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(servicesProvider).db;
    final names = {for (final p in ref.watch(playersProvider).value ?? const <Player>[]) p.id: p};
    final balances = ref.watch(balancesProvider).value ?? const <String, int>{};
    return StreamBuilder<GameSession?>(
      stream: db.watchSession(widget.sessionId),
      builder: (context, sessionSnap) {
        final session = sessionSnap.data;
        if (session == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final reset = session.moneyMode == 'reset';
        return StreamBuilder<List<Participant>>(
          stream: db.watchParticipants(widget.sessionId),
          builder: (context, snap) {
            final joined = snap.data ?? const <Participant>[];
            return Scaffold(
              body: SafeArea(
                child: Column(children: [
                  ScreenHeader('Сбор игроков',
                      subtitle: reset ? '${session.name} · старт ${money(session.startingCapital)}' : '${session.name} · на копилки'),
                  Expanded(
                    child: ListView(padding: const EdgeInsets.symmetric(horizontal: 20), children: [
                      _TapPanel(
                        reading: _reading,
                        text: reset
                            ? 'Каждый получит ${money(session.startingCapital)} на старте. Копилки игроков не изменятся.'
                            : 'Играем на накопленные монеты из копилок.',
                        onRetry: _listen,
                      ),
                      if (_message != null) ...[
                        const SizedBox(height: 12),
                        Text(_message!, textAlign: TextAlign.center, style: T.bodyBold.copyWith(color: C.red)),
                      ],
                      const SizedBox(height: 18),
                      Text('В игре: ${joined.length}', style: T.label),
                      const SizedBox(height: 10),
                      for (final p in joined)
                        if (names[p.playerId] != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Panel(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              child: Row(children: [
                                PlayerAvatar(names[p.playerId]!, size: 42),
                                const SizedBox(width: 12),
                                Expanded(child: Text(names[p.playerId]!.name, style: T.title)),
                                Text(money(balances[p.walletId] ?? 0), style: T.bodyBold),
                                const SizedBox(width: 10),
                                const Icon(Icons.check_rounded, color: C.green),
                              ]),
                            ),
                          ),
                      DashedBox(
                        onTap: () => _pickFromList(joined),
                        child: Text(_reading ? 'Ждём следующую карту…  или выбрать из списка' : 'Выбрать игрока из списка',
                            style: T.label.copyWith(color: C.text2)),
                      ),
                      const SizedBox(height: 16),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Btn(
                      joined.isEmpty ? 'Начать игру' : 'Начать игру · ${players(joined.length)}',
                      onPressed: joined.isEmpty ? null : () => _start(joined.length),
                    ),
                  ),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

class _TapPanel extends StatelessWidget {
  const _TapPanel({required this.reading, required this.text, required this.onRetry});

  final bool reading;
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        decoration: BoxDecoration(color: C.green, borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2)),
            alignment: Alignment.center,
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), shape: BoxShape.circle),
              child: const NfcBadge(size: 30),
            ),
          ),
          const SizedBox(height: 16),
          Text('Прикладывайте карты по очереди', textAlign: TextAlign.center, style: T.title.copyWith(color: Colors.white, fontSize: 18)),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: T.secondary.copyWith(color: Colors.white.withValues(alpha: 0.85))),
          if (!reading) ...[
            const SizedBox(height: 14),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.white.withValues(alpha: 0.16)),
              child: const Text('Читать карты'),
            ),
          ],
        ]),
      );
}
