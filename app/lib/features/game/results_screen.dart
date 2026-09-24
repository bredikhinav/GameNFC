import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/bank.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';

final standingsProvider = FutureProvider.family<List<Standing>, String>((ref, sessionId) async {
  ref.watch(balancesProvider);
  return ref.read(bankProvider).standings(sessionId);
});

/// "Итоги игры": ranking, optional prize for the winner, close the game.
class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  bool _prize = false;
  final _prizeAmount = TextEditingController(text: '20');
  bool _busy = false;

  Future<void> _close(Standing? winner) async {
    setState(() => _busy = true);
    final amount = int.tryParse(_prizeAmount.text) ?? 0;
    await ref.read(bankProvider).finish(
          widget.sessionId,
          prizes: _prize && winner != null && amount > 0 ? {winner.player.id: amount} : const {},
        );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _again(GameSession session) async {
    final id = await ref.read(bankProvider).createSession(
          name: session.name,
          moneyMode: session.moneyMode,
          startingCapital: session.startingCapital,
          quickButtons: QuickButton.parse(session.quickButtons),
        );
    if (mounted) context.pushReplacement('/game/$id/lobby');
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(servicesProvider).db;
    final standings = ref.watch(standingsProvider(widget.sessionId)).value ?? const <Standing>[];
    final space = ref.watch(spaceProvider);
    return StreamBuilder<GameSession?>(
      stream: db.watchSession(widget.sessionId),
      builder: (context, snap) {
        final session = snap.data;
        if (session == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final finished = session.status == 'finished';
        final winner = standings.firstOrNull;
        final reset = session.moneyMode == 'reset';
        final took = session.startedAt == null ? null : (session.finishedAt ?? DateTime.now()).difference(session.startedAt!);
        return Scaffold(
          body: SafeArea(
            child: Column(children: [
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 16), children: [
                  Row(children: [
                    if (finished) ...[const CircleBack(), const SizedBox(width: 12)],
                    const Text('Итоги игры', style: T.h1),
                  ]),
                  const SizedBox(height: 4),
                  Text([session.name, if (took != null) duration(took)].join(' · '), style: T.small.copyWith(fontSize: 14)),
                  const SizedBox(height: 18),
                  if (winner != null)
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(color: C.ink, borderRadius: BorderRadius.circular(24)),
                      child: Column(children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(color: C.coin, shape: BoxShape.circle),
                          child: const Icon(Icons.emoji_events_outlined, color: C.ink),
                        ),
                        const SizedBox(height: 12),
                        Text('Победитель', style: T.secondary.copyWith(color: const Color(0xFFC9C6BF))),
                        const SizedBox(height: 6),
                        Text(winner.player.name, style: T.h1.copyWith(color: Colors.white, fontSize: 32)),
                        const SizedBox(height: 8),
                        Text(reset ? coins(winner.balance) : '${signed(winner.net)} за игру',
                            style: T.bodyBold.copyWith(color: C.coin, fontSize: 18)),
                      ]),
                    ),
                  const SizedBox(height: 14),
                  for (final s in standings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Panel(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                        child: Row(children: [
                          SizedBox(width: 30, child: Text('${s.place}', style: T.bodyBold.copyWith(color: C.text2))),
                          Expanded(child: Text(s.player.name, style: T.title)),
                          Text(reset ? money(s.balance) : signed(s.net), style: T.bodyBold),
                        ]),
                      ),
                    ),
                  if (!finished && winner != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: C.surfaceSand, borderRadius: BorderRadius.circular(18)),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Приз в копилку победителя', style: T.bodyBold),
                            const SizedBox(height: 4),
                            Row(children: [
                              const Text('+', style: T.small),
                              SizedBox(
                                width: 56,
                                child: TextField(
                                  controller: _prizeAmount,
                                  keyboardType: TextInputType.number,
                                  style: T.small,
                                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                                ),
                              ),
                              Flexible(
                                child: Text(' ${space.currencyName} на постоянный счёт ${genitive(winner.player.name)}', style: T.small),
                              ),
                            ]),
                          ]),
                        ),
                        Checkbox(value: _prize, onChanged: (v) => setState(() => _prize = v ?? false)),
                      ]),
                    ),
                  ],
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(children: [
                  if (!finished)
                    Btn('Закрыть игру', busy: _busy, onPressed: () => _close(winner))
                  else
                    Btn('На главную', onPressed: () => context.go('/')),
                  const SizedBox(height: 10),
                  Btn('Сыграть ещё раз', kind: BtnKind.outline, onPressed: finished ? () => _again(session) : null),
                  if (!finished) ...[
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => context.pushReplacement('/game/${widget.sessionId}/terminal'),
                      child: const Text('Вернуться в игру'),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}
