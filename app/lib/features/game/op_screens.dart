import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/bank.dart';
import '../../ui/widgets.dart';
import 'pin_screen.dart';

/// "Операция проведена": result, remaining balance, optional comment, undo.
class OpResultScreen extends ConsumerStatefulWidget {
  const OpResultScreen({super.key, required this.done});

  final OpDone done;

  @override
  ConsumerState<OpResultScreen> createState() => _OpResultScreenState();
}

class _OpResultScreenState extends ConsumerState<OpResultScreen> {
  final _comment = TextEditingController();

  Future<void> _close() async {
    final text = _comment.text.trim();
    if (text.isNotEmpty) await ref.read(bankProvider).setComment(widget.done.txId, text);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _undo() async {
    if (!await askPin(context, ref)) return;
    try {
      await ref.read(bankProvider).undo(widget.done.txId);
      if (!mounted) return;
      toast(context, 'Операция отменена');
      Navigator.pop(context);
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.done;
    final (title, sign, opName) = switch (d.type) {
      'credit' => ('Начислено ${dative(d.player.name)}', '+', 'Начисление'),
      'transfer' => ('${d.player.name} → ${d.toPlayer?.name ?? ''}', '', 'Перевод'),
      _ => ('Списано у ${genitive(d.player.name)}', '−', 'Оплата'),
    };
    final online = ref.watch(onlineProvider).value ?? true;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 40, 20, 16), children: [
              const Center(child: StatusHero(icon: Icons.check_rounded, color: C.green, halo: C.greenPale)),
              const SizedBox(height: 18),
              Text(title, textAlign: TextAlign.center, style: T.bodyBold.copyWith(color: C.text2, fontSize: 16)),
              const SizedBox(height: 10),
              Center(child: FittedBox(child: Text('$sign${money(d.amount)}', style: T.amountXL.copyWith(fontSize: 64)))),
              const SizedBox(height: 24),
              Panel(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _row(d.type == 'transfer' ? 'Остаток у ${genitive(d.player.name)}' : 'Остаток', money(d.balance)),
                  const Divider(),
                  _row('Операция', opName),
                  const Divider(),
                  const SizedBox(height: 12),
                  Text('Комментарий', style: T.secondary.copyWith(fontSize: 15)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _comment,
                    maxLength: 140,
                    decoration: const InputDecoration(hintText: 'Например: покупка улицы', fillColor: C.bg, counterText: ''),
                  ),
                ]),
              ),
              if (d.queued || !online) ...[const SizedBox(height: 18), const Center(child: OfflinePill())],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(children: [
              Btn('Готово', onPressed: _close),
              const SizedBox(height: 10),
              Btn('Отменить операцию', kind: BtnKind.danger, onPressed: _undo),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(children: [
          Expanded(child: Text(label, style: T.secondary.copyWith(fontSize: 15))),
          Text(value, style: T.bodyBold),
        ]),
      );
}

/// Not enough coins. Pops with the amount to charge instead (all the player has) or null.
class InsufficientScreen extends StatelessWidget {
  const InsufficientScreen({super.key, required this.name, required this.balance, required this.amount});

  final String name;
  final int balance;
  final int amount;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 40, 20, 16), children: [
                const Center(
                  child: StatusHero(icon: Icons.priority_high_rounded, color: C.coin, halo: C.coinPale, iconColor: C.ink),
                ),
                const SizedBox(height: 18),
                const Text('Не хватает монет', textAlign: TextAlign.center, style: T.h2),
                const SizedBox(height: 10),
                Text('У ${genitive(name)} ${money(balance)}, а нужно ${money(amount)}. Ничего не списано.',
                    textAlign: TextAlign.center, style: T.secondary.copyWith(fontSize: 16)),
                const SizedBox(height: 24),
                InfoRows([
                  ('Баланс', Text(money(balance), style: T.bodyBold)),
                  ('Сумма', Text(money(amount), style: T.bodyBold)),
                  ('Не хватает', Text(money(amount - balance), style: T.bodyBold.copyWith(color: C.red))),
                ]),
                const SizedBox(height: 16),
                const Note('По правилам игры можно продать имущество или взять кредит у банка. Кредит ведущий начисляет вручную.'),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(children: [
                Btn('Изменить сумму', kind: BtnKind.dark, onPressed: () => Navigator.pop(context)),
                if (balance > 0) ...[
                  const SizedBox(height: 10),
                  Btn('Списать ${money(balance)} — всё, что есть', kind: BtnKind.outline, onPressed: () => Navigator.pop(context, balance)),
                ],
              ]),
            ),
          ]),
        ),
      );
}

/// A card that cannot be used. Pops with true if the operator wants to pick a player instead.
class CardRejectedScreen extends StatelessWidget {
  const CardRejectedScreen({super.key, required this.code, this.details = const {}});

  final String code;
  final Map<String, dynamic> details;

  @override
  Widget build(BuildContext context) {
    final (title, text) = switch (code) {
      'card_blocked' => ('Карта заблокирована', 'Родитель отметил эту карту как потерянную. Операция не проведена.'),
      'card_not_in_session' => ('Игрок не в этой игре', '${details['player'] ?? 'Этот игрок'} не участвует в игре. Добавить его можно из списка игроков.'),
      'card_unlinked' => ('Карта отвязана', 'Карта ни к кому не привязана. Привяжите её в профиле ребёнка.'),
      'session_not_active' => ('Игра на паузе', 'Продолжите игру, чтобы проводить операции.'),
      _ => ('Карта не распознана', 'Это не карта ФантикПэй, карта другой семьи или лагеря — или подделка.'),
    };
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 40, 20, 16), children: [
              const Center(child: StatusHero(icon: Icons.lock_outline_rounded, color: C.red, halo: C.redPale)),
              const SizedBox(height: 18),
              Text(title, textAlign: TextAlign.center, style: T.h2),
              const SizedBox(height: 10),
              Text(text, textAlign: TextAlign.center, style: T.secondary.copyWith(fontSize: 16)),
              const SizedBox(height: 24),
              const Text('Другие причины, по которым карта не проходит', style: T.label),
              const SizedBox(height: 10),
              Panel(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                child: Column(children: const [
                  _Reason('Игрок не в этой игре', 'Добавить его можно из списка игроков'),
                  Divider(),
                  _Reason('Карта из другой семьи или лагеря', 'Её нужно привязать к игроку этой семьи'),
                  Divider(),
                  _Reason('Карта не распознана', 'Не наша карта или подделка'),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(children: [
              Btn('Понятно', kind: BtnKind.dark, onPressed: () => Navigator.pop(context, false)),
              const SizedBox(height: 10),
              Btn('Выбрать игрока из списка', kind: BtnKind.outline, onPressed: () => Navigator.pop(context, true)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason(this.title, this.text);

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: T.bodyBold),
          const SizedBox(height: 2),
          Text(text, style: T.small),
        ]),
      );
}
