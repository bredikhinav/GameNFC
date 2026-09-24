import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';
import '../game/pin_screen.dart';

final spaceHistoryProvider = StreamProvider<List<Tx>>((ref) {
  final s = ref.watch(servicesProvider);
  return s.db.watchSpaceHistory(ref.watch(spaceProvider).id, limit: 200);
});

final walletOwnersProvider = StreamProvider<Map<String, String>>((ref) {
  final s = ref.watch(servicesProvider);
  final spaceId = ref.watch(spaceProvider).id;
  final wallets = s.db.select(s.db.wallets)..where((w) => w.spaceId.equals(spaceId));
  return wallets.watch().map((rows) => {for (final w in rows) if (w.playerId != null) w.id: w.playerId!});
});

String txTitle(Tx t) => switch (t.type) {
      'credit' => t.comment ?? 'Начисление',
      'debit' => t.comment ?? 'Оплата',
      'transfer' => t.comment ?? 'Перевод',
      'purchase' => t.comment ?? 'Покупка',
      'reversal' => 'Отмена операции',
      'session_start' => 'Старт игры${t.comment != null ? ' «${t.comment}»' : ''}',
      'prize' => 'Приз за победу',
      'allowance' => t.comment ?? 'Регулярное начисление',
      _ => t.type,
    };

class HistoryTab extends ConsumerWidget {
  const HistoryTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txs = ref.watch(spaceHistoryProvider).value ?? const <Tx>[];
    final owners = ref.watch(walletOwnersProvider).value ?? const <String, String>{};
    final names = {for (final p in ref.watch(playersProvider).value ?? const <Player>[]) p.id: p.name};
    final reversed = {for (final t in txs) if (t.reversesId != null) t.reversesId!};
    final groups = <String, List<Tx>>{};
    for (final t in txs) {
      groups.putIfAbsent(dayTitle(t.createdAt), () => []).add(t);
    }
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('История', style: T.h1),
      const SizedBox(height: 16),
      if (txs.isEmpty) const Note('Операций пока нет.'),
      for (final entry in groups.entries) ...[
        Text(entry.key, style: T.caps),
        const SizedBox(height: 8),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(children: [
            for (var i = 0; i < entry.value.length; i++) ...[
              if (i > 0) const Divider(),
              _TxRow(tx: entry.value[i], owners: owners, names: names, reversed: reversed.contains(entry.value[i].id)),
            ],
          ]),
        ),
        const SizedBox(height: 16),
      ],
    ]);
  }
}

class _TxRow extends ConsumerWidget {
  const _TxRow({required this.tx, required this.owners, required this.names, required this.reversed});

  final Tx tx;
  final Map<String, String> owners;
  final Map<String, String> names;
  final bool reversed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final from = names[owners[tx.fromWallet]];
    final to = names[owners[tx.toWallet]];
    final who = switch ((from, to)) {
      (String f, String t) => '$f → $t',
      (String f, null) => f,
      (null, String t) => t,
      _ => '',
    };
    final incoming = to != null && from == null;
    final amountText = from != null && to != null ? money(tx.amount) : (incoming ? '+${money(tx.amount)}' : '−${money(tx.amount)}');
    return InkWell(
      onLongPress: tx.type == 'reversal' || reversed ? null : () => _cancel(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: incoming ? C.greenPale : C.redPale, shape: BoxShape.circle),
            child: Icon(incoming ? Icons.south_west_rounded : Icons.north_east_rounded, size: 18, color: incoming ? C.green : C.red),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(txTitle(tx), style: T.bodyBold.copyWith(
                decoration: reversed ? TextDecoration.lineThrough : null,
              )),
              Text('$who · ${time(tx.createdAt)}${tx.pending ? ' · не отправлено' : ''}', style: T.small),
            ]),
          ),
          Text(amountText, style: T.bodyBold.copyWith(color: incoming ? C.green : (from != null && to != null ? C.ink : C.red))),
        ]),
      ),
    );
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    if (!await confirm(context, 'Отменить операцию?', 'Будет создана обратная операция на ${money(tx.amount)}.', ok: 'Отменить', danger: true)) return;
    if (!context.mounted || !await askPin(context, ref)) return;
    try {
      await ref.read(bankProvider).undo(tx.id);
      if (context.mounted) toast(context, 'Операция отменена');
    } on Exception catch (e) {
      if (context.mounted) toast(context, describe(e));
    }
  }
}
