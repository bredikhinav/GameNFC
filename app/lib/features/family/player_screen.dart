import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/ids.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';
import 'history_tab.dart';

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key, required this.playerId});

  final String playerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.read(servicesProvider);
    final space = ref.watch(spaceProvider);
    final player = (ref.watch(playersProvider).value ?? const <Player>[]).where((p) => p.id == playerId).firstOrNull;
    if (player == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final balance = ref.watch(balancesProvider).value?[persistentWalletId(player.id)] ?? 0;
    final walletIds = [persistentWalletId(player.id)];

    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          ScreenHeader(player.name, trailing: space.isAdmin
              ? PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (v) => v == 'rename' ? _rename(context, ref, player) : _delete(context, ref, player),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                    PopupMenuItem(value: 'delete', child: Text('Удалить профиль', style: TextStyle(color: C.red))),
                  ],
                )
              : null),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _PiggyCard(player: player, balance: balance),
              const SizedBox(height: 16),
              if (space.isAdmin) ...[
                Row(children: [
                  Expanded(child: Btn('Начислить', height: 50, onPressed: () => _quick(context, ref, player, 'credit'))),
                  const SizedBox(width: 10),
                  Expanded(child: Btn('Списать', kind: BtnKind.outline, height: 50, onPressed: () => _quick(context, ref, player, 'debit'))),
                ]),
                const SizedBox(height: 24),
              ],
              const Text('КАРТЫ', style: T.caps),
              const SizedBox(height: 8),
              StreamBuilder<List<LocalCard>>(
                stream: s.db.watchCards(player.id),
                builder: (context, snap) => Column(children: [
                  for (final c in snap.data ?? const <LocalCard>[])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Panel(
                        child: Row(children: [
                          Icon(Icons.credit_card_rounded, color: c.status == 'active' ? C.green : C.red),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(c.label ?? 'Карта ${c.uid != null ? '…${c.uid!.substring(c.uid!.length - 4)}' : ''}', style: T.bodyBold),
                              Text(c.status == 'active' ? 'Активна' : 'Заблокирована', style: T.small),
                            ]),
                          ),
                          if (space.isAdmin)
                            PopupMenuButton<String>(
                              onSelected: (action) => _cardAction(context, ref, c, action),
                              itemBuilder: (_) => [
                                if (c.status == 'active') const PopupMenuItem(value: 'block', child: Text('Заблокировать (потеряна)')),
                                const PopupMenuItem(value: 'unlink', child: Text('Отвязать (отдать другому)')),
                              ],
                            ),
                        ]),
                      ),
                    ),
                  if (space.isAdmin)
                    DashedBox(
                      onTap: () => context.push('/player/${player.id}/card'),
                      child: const Text('+ Привязать карту', style: T.bodyBold),
                    ),
                ]),
              ),
              if (space.isAdmin) ...[
                const SizedBox(height: 24),
                const Text('ТЕЛЕФОН РЕБЁНКА', style: T.caps),
                const SizedBox(height: 8),
                Panel(
                  onTap: () => context.push('/player/${player.id}/device'),
                  child: Row(children: [
                    const Icon(Icons.qr_code_2_rounded, color: C.ink),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        player.linkedDevices > 0 ? 'Телефон привязан · подключить ещё' : 'Показать QR-код для телефона ребёнка',
                        style: T.body,
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: C.text2),
                  ]),
                ),
              ],
              const SizedBox(height: 24),
              const Text('ИСТОРИЯ', style: T.caps),
              const SizedBox(height: 8),
              StreamBuilder<List<Tx>>(
                stream: s.db.watchWalletHistory(walletIds, limit: 30),
                builder: (context, snap) {
                  final txs = snap.data ?? const <Tx>[];
                  if (txs.isEmpty) return const Note('Операций пока нет.');
                  return Panel(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Column(children: [
                      for (var i = 0; i < txs.length; i++) ...[
                        if (i > 0) const Divider(),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(txTitle(txs[i]), style: T.bodyBold),
                                Text('${dayTitle(txs[i].createdAt).toLowerCase()}, ${time(txs[i].createdAt)}', style: T.small),
                              ]),
                            ),
                            Text(
                              walletIds.contains(txs[i].toWallet) ? '+${money(txs[i].amount)}' : '−${money(txs[i].amount)}',
                              style: T.bodyBold.copyWith(color: walletIds.contains(txs[i].toWallet) ? C.green : C.red),
                            ),
                          ]),
                        ),
                      ],
                    ]),
                  );
                },
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _quick(BuildContext context, WidgetRef ref, Player player, String type) async {
    final amount = TextEditingController();
    final comment = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(type == 'credit' ? 'Начислить ${player.name}' : 'Списать у ${genitive(player.name)}', style: T.h2),
          const SizedBox(height: 16),
          TextField(controller: amount, autofocus: true, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Сколько')),
          const SizedBox(height: 12),
          TextField(controller: comment, decoration: const InputDecoration(hintText: 'За что, например «уборка в комнате»')),
          const SizedBox(height: 16),
          Btn('Готово', onPressed: () => Navigator.pop(context, true)),
        ]),
      ),
    );
    final value = int.tryParse(amount.text) ?? 0;
    if (ok != true || value <= 0) return;
    try {
      final bank = ref.read(bankProvider);
      await bank.operate(
        type: type,
        amount: value,
        subject: await bank.holderFor(player),
        comment: comment.text.trim().isEmpty ? null : comment.text.trim(),
      );
    } on Exception catch (e) {
      if (context.mounted) toast(context, describe(e));
    }
  }

  Future<void> _cardAction(BuildContext context, WidgetRef ref, LocalCard card, String action) async {
    final text = action == 'block'
        ? 'Карта перестанет работать. Монеты останутся у ребёнка — просто привяжите новую карту.'
        : 'Карту можно будет привязать другому ребёнку. История останется у прежнего владельца.';
    if (!await confirm(context, action == 'block' ? 'Заблокировать карту?' : 'Отвязать карту?', text, danger: true)) return;
    try {
      final s = ref.read(servicesProvider);
      await s.api.post('/cards/${card.id}/$action');
      await s.sync.sync();
    } on Exception catch (e) {
      if (context.mounted) toast(context, describe(e));
    }
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Player player) async {
    final name = TextEditingController(text: player.name);
    final ok = await confirmField(context, 'Имя или прозвище', name);
    if (!ok) return;
    try {
      final s = ref.read(servicesProvider);
      await s.api.patch('/players/${player.id}', {'name': name.text.trim()});
      await s.sync.sync();
    } on Exception catch (e) {
      if (context.mounted) toast(context, describe(e));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Player player) async {
    if (!await confirm(context, 'Удалить профиль?', 'Имя ребёнка будет удалено, карты отвязаны. История операций останется обезличенной.', ok: 'Удалить', danger: true)) return;
    try {
      final s = ref.read(servicesProvider);
      await s.api.delete('/players/${player.id}');
      await s.sync.sync();
      if (context.mounted) Navigator.pop(context);
    } on Exception catch (e) {
      if (context.mounted) toast(context, describe(e));
    }
  }
}

Future<bool> confirmField(BuildContext context, String title, TextEditingController controller) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: C.bg,
        title: Text(title, style: T.h3),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Сохранить')),
        ],
      ),
    ) ??
    false;

class _PiggyCard extends ConsumerWidget {
  const _PiggyCard({required this.player, required this.balance});

  final Player player;
  final int balance;

  @override
  Widget build(BuildContext context, WidgetRef ref) => GoalCard(
        balance: balance,
        goalTitle: player.goalTitle,
        goalTarget: player.goalTarget,
        onEditGoal: ref.read(spaceProvider).isAdmin ? () => _editGoal(context, ref) : null,
      );

  Future<void> _editGoal(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController(text: player.goalTitle);
    final target = TextEditingController(text: player.goalTarget?.toString());
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Цель накопления', style: T.h2),
          const SizedBox(height: 16),
          TextField(controller: title, decoration: const InputDecoration(hintText: 'Например, самокат')),
          const SizedBox(height: 12),
          TextField(controller: target, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Сколько монет нужно')),
          const SizedBox(height: 16),
          Btn('Сохранить', onPressed: () => Navigator.pop(context, true)),
        ]),
      ),
    );
    if (ok != true) return;
    try {
      final s = ref.read(servicesProvider);
      await s.api.put('/players/${player.id}/goal', {'title': title.text.trim(), 'target_amount': int.parse(target.text)});
      await s.sync.sync();
    } on Exception catch (e) {
      if (context.mounted) toast(context, describe(e));
    }
  }
}

/// Green "Моя копилка" card with a goal progress bar (shared with the child's home).
class GoalCard extends StatelessWidget {
  const GoalCard({super.key, required this.balance, this.goalTitle, this.goalTarget, this.onEditGoal, this.title = 'Копилка'});

  final int balance;
  final String? goalTitle;
  final int? goalTarget;
  final VoidCallback? onEditGoal;
  final String title;

  @override
  Widget build(BuildContext context) {
    final target = goalTarget ?? 0;
    final progress = target > 0 ? (balance / target).clamp(0.0, 1.0) : 0.0;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: C.green, borderRadius: BorderRadius.circular(24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: T.body.copyWith(color: Colors.white.withValues(alpha: 0.85))),
        const SizedBox(height: 10),
        Row(children: [
          Flexible(child: FittedBox(child: Text(money(balance), style: T.amountXL.copyWith(color: Colors.white)))),
          const SizedBox(width: 12),
          const Coin(size: 34),
        ]),
        const SizedBox(height: 18),
        if (goalTitle != null && target > 0) ...[
          Row(children: [
            Expanded(
              child: Text('Цель: $goalTitle · ${money(balance)} из ${money(target)}',
                  style: T.small.copyWith(color: Colors.white.withValues(alpha: 0.85))),
            ),
            Text('${(progress * 100).round()}%', style: T.small.copyWith(color: Colors.white.withValues(alpha: 0.85))),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              color: C.coin,
              backgroundColor: Colors.white.withValues(alpha: 0.22),
            ),
          ),
        ] else if (onEditGoal != null)
          Text('Поставить цель', style: T.small.copyWith(color: Colors.white, decoration: TextDecoration.underline, decorationColor: Colors.white)),
        if (onEditGoal != null)
          Align(alignment: Alignment.centerRight, child: IconButton(onPressed: onEditGoal, icon: const Icon(Icons.edit_outlined, color: Colors.white70))),
      ]),
    );
  }
}
