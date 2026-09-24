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
import 'op_screens.dart';
import 'pin_screen.dart';

enum Mode { debit, credit, transfer }

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  Mode _mode = Mode.debit;
  String _amount = '';
  bool _busy = false;

  int get _value => int.tryParse(_amount) ?? 0;

  void _digit(String d) {
    if (_amount.length + d.length > 7) return;
    setState(() => _amount = (_amount + d).replaceFirst(RegExp(r'^0+'), ''));
  }

  Bank get _bank => ref.read(bankProvider);
  CardReader get _reader => ref.read(servicesProvider).reader;

  /// Read a card and resolve it to a player in this game, or pick one from the list.
  Future<Holder?> _readHolder(String prompt) async {
    try {
      final tap = await _reader.read(prompt: prompt);
      return await _bank.identify(tap, sessionId: widget.sessionId);
    } on NfcCancelled {
      return null;
    } on NfcUnavailable catch (e) {
      if (mounted) toast(context, e.disabled ? 'Включите NFC в настройках телефона' : 'На этом телефоне нет NFC');
      return _pickPlayer();
    } on ApiError catch (e) {
      HapticFeedback.heavyImpact();
      if (!mounted) return null;
      final pick = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => CardRejectedScreen(code: e.code, details: e.details)),
      );
      return pick == true ? _pickPlayer() : null;
    }
  }

  Future<Holder?> _pickPlayer() async {
    final db = ref.read(servicesProvider).db;
    final rows = await (db.select(db.participants)..where((p) => p.sessionId.equals(widget.sessionId))).get();
    final players = [for (final r in rows) ?await db.playerById(r.playerId)];
    if (!mounted) return null;
    final picked = await showModalBottomSheet<Player>(
      context: context,
      builder: (context) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 24), children: [
        const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Выберите игрока', style: T.h3)),
        for (final p in players)
          ListTile(leading: PlayerAvatar(p, size: 36), title: Text(p.name, style: T.bodyBold), onTap: () => Navigator.pop(context, p)),
      ]),
    );
    return picked == null ? null : _bank.holderFor(picked, sessionId: widget.sessionId);
  }

  Future<void> _go() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_value == 0) {
        final holder = await _readHolder('Поднесите карту — покажем баланс');
        if (holder != null && mounted) {
          await showModalBottomSheet<void>(context: context, builder: (_) => BalanceSheet(holder: holder));
        }
        return;
      }
      final verb = switch (_mode) { Mode.debit => 'списать', Mode.credit => 'начислить', Mode.transfer => 'перевести' };
      final subject = await _readHolder(_mode == Mode.transfer ? 'Карта отправителя' : 'Поднесите карту — $verb ${money(_value)}');
      if (subject == null) return;
      Holder? receiver;
      if (_mode == Mode.transfer) {
        receiver = await _readHolder('${subject.player.name} → кому? Карта получателя');
        if (receiver == null) return;
      }
      await _operate(subject, receiver, _value);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _operate(Holder subject, Holder? receiver, int amount) async {
    try {
      final done = await _bank.operate(
        type: _mode.name,
        amount: amount,
        subject: subject,
        receiver: receiver,
        sessionId: widget.sessionId,
      );
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OpResultScreen(done: done)));
      if (mounted) setState(() => _amount = '');
    } on ApiError catch (e) {
      HapticFeedback.heavyImpact();
      if (!mounted) return;
      if (e.code == 'insufficient_funds') {
        final choice = await Navigator.of(context).push<int>(MaterialPageRoute(
          builder: (_) => InsufficientScreen(name: subject.player.name, balance: e.details['balance'] as int? ?? 0, amount: amount),
        ));
        if (choice != null && choice > 0) await _operate(subject, receiver, choice);
      } else {
        toast(context, e.message);
      }
    }
  }

  Future<void> _exit() async {
    if (await askPin(context, ref) && mounted) context.go('/');
  }

  Future<void> _finish() async {
    if (!await confirm(context, 'Завершить игру?', 'Покажем итоги. Операции в этой игре станут недоступны.', ok: 'Завершить')) return;
    if (!mounted || !await askPin(context, ref, reason: 'Нужен, чтобы завершить игру')) return;
    if (mounted) context.pushReplacement('/game/${widget.sessionId}/results');
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(servicesProvider).db;
    final byId = {for (final p in ref.watch(playersProvider).value ?? const <Player>[]) p.id: p};
    final balances = ref.watch(balancesProvider).value ?? const <String, int>{};
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: StreamBuilder<GameSession?>(
        stream: db.watchSession(widget.sessionId),
        builder: (context, sessionSnap) {
          final session = sessionSnap.data;
          if (session == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          final quick = QuickButton.parse(session.quickButtons);
          return StreamBuilder<List<Participant>>(
            stream: db.watchParticipants(widget.sessionId),
            builder: (context, snap) {
              final joined = snap.data ?? const <Participant>[];
              return Scaffold(
                body: SafeArea(
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Банк', style: T.h2),
                            Text('${session.name} · ${players(joined.length)}', style: T.small.copyWith(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                        _HeaderButton('Завершить', onTap: _finish),
                        const SizedBox(width: 8),
                        CircleIconButton(icon: Icons.lock_outline_rounded, onPressed: _exit),
                      ]),
                    ),
                    if (session.status == 'paused')
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Btn('Пауза — продолжить игру', kind: BtnKind.dark, height: 44,
                            onPressed: () => _bank.setStatus(widget.sessionId, 'active')),
                      ),
                    SizedBox(
                      height: 64,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        children: [
                          for (final p in joined)
                            if (byId[p.playerId] != null)
                              Container(
                                width: 112,
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: C.surface,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: C.border),
                                ),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(byId[p.playerId]!.name, style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text(money(balances[p.walletId] ?? 0), style: T.bodyBold.copyWith(fontSize: 16)),
                                ]),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _Segments(value: _mode, onChanged: (m) => setState(() => _mode = m)),
                    ),
                    const SizedBox(height: 14),
                    const Text('Сумма', style: T.secondary),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(_amount.isEmpty ? '0' : money(_value), style: T.amountXL.copyWith(color: _amount.isEmpty ? C.borderStrong : C.ink)),
                      const SizedBox(width: 12),
                      const Coin(size: 30),
                    ]),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        children: [
                          for (final b in quick)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: PillButton(b.label, onPressed: () => setState(() {
                                _amount = '${b.amount}';
                                _mode = b.type == 'credit' ? Mode.credit : Mode.debit;
                              })),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      child: Keypad(
                        onDigit: _digit,
                        onBackspace: () => setState(() => _amount = _amount.isEmpty ? '' : _amount.substring(0, _amount.length - 1)),
                      ),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Btn(
                        _actionLabel(),
                        kind: BtnKind.dark,
                        icon: Icons.contactless_outlined,
                        busy: _busy,
                        onPressed: session.status == 'active' ? _go : null,
                      ),
                    ),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _actionLabel() {
    if (_value == 0) return 'Приложите карту — баланс';
    return switch (_mode) {
      Mode.debit => 'Приложите карту — списать ${money(_value)}',
      Mode.credit => 'Приложите карту — начислить ${money(_value)}',
      Mode.transfer => 'Перевод ${money(_value)}: карта отправителя',
    };
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        shape: const StadiumBorder(side: BorderSide(color: C.border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(label, style: T.label.copyWith(fontSize: 14)),
          ),
        ),
      );
}

class _Segments extends StatelessWidget {
  const _Segments({required this.value, required this.onChanged});

  final Mode value;
  final ValueChanged<Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = {Mode.debit: 'Оплата', Mode.credit: 'Начислить', Mode.transfer: 'Перевод'};
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: C.surfaceSand, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        for (final m in Mode.values)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: m == value ? C.ink : Colors.transparent, borderRadius: BorderRadius.circular(12)),
                child: Text(labels[m]!, style: T.label.copyWith(fontSize: 14, color: m == value ? Colors.white : C.ink)),
              ),
            ),
          ),
      ]),
    );
  }
}

class BalanceSheet extends StatelessWidget {
  const BalanceSheet({super.key, required this.holder});

  final Holder holder;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          PlayerAvatar(holder.player, size: 64),
          const SizedBox(height: 12),
          Text(holder.player.name, style: T.h3),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(money(holder.balance), style: T.amountL),
            const SizedBox(width: 10),
            const Coin(size: 26),
          ]),
        ]),
      );
}
