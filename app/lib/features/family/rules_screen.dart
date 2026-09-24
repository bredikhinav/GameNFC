import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';
import 'home_screen.dart';

const weekdayNames = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'];

/// Limits for children's transfers and recurring allowances.
class RulesScreen extends ConsumerStatefulWidget {
  const RulesScreen({super.key});

  @override
  ConsumerState<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends ConsumerState<RulesScreen> {
  late final _daily = TextEditingController(text: ref.read(spaceProvider).dailyTransferLimit?.toString() ?? '');
  late final _threshold = TextEditingController(text: ref.read(spaceProvider).approvalThreshold?.toString() ?? '');
  late bool _allowNegative = ref.read(spaceProvider).allowNegative;
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(servicesProvider).api.patch('/spaces/${ref.read(spaceProvider).id}', {
        'daily_transfer_limit': int.tryParse(_daily.text),
        'transfer_approval_threshold': int.tryParse(_threshold.text),
        'allow_negative': _allowNegative,
      });
      await ref.read(authProvider.notifier).refreshUser();
      if (mounted) toast(context, 'Сохранено');
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addAllowance() async {
    final amount = TextEditingController(text: '30');
    final comment = TextEditingController(text: 'Карманные');
    var weekday = 6;
    String? playerId;
    final players = ref.read(playersProvider).value ?? const <Player>[];
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Регулярное начисление', style: T.h2),
            const SizedBox(height: 16),
            TextField(controller: comment, decoration: const InputDecoration(hintText: 'За что')),
            const SizedBox(height: 12),
            TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Сколько')),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: weekday,
              items: [for (var i = 0; i < 7; i++) DropdownMenuItem(value: i, child: Text('Каждый ${weekdayNames[i].toLowerCase()}'))],
              onChanged: (v) => setState(() => weekday = v ?? weekday),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: playerId,
              items: [
                const DropdownMenuItem(value: null, child: Text('Всем детям')),
                for (final p in players) DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (v) => setState(() => playerId = v),
            ),
            const SizedBox(height: 16),
            Btn('Добавить', onPressed: () async {
              try {
                await ref.read(servicesProvider).api.post('/spaces/${ref.read(spaceProvider).id}/allowances', {
                  'amount': int.parse(amount.text),
                  'comment': comment.text.trim(),
                  'weekday': weekday,
                  'player_id': playerId,
                });
                if (context.mounted) Navigator.pop(context, true);
              } on Exception catch (e) {
                if (context.mounted) toast(context, describe(e));
              }
            }),
          ]),
        ),
      ),
    );
    if (ok == true) ref.invalidate(allowancesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final allowances = ref.watch(allowancesProvider).value ?? const [];
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          const ScreenHeader('Правила'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('ПЕРЕВОДЫ ДЕТЕЙ', style: T.caps),
              const SizedBox(height: 8),
              const Text('Лимит в день (пусто — без лимита)', style: T.label),
              const SizedBox(height: 6),
              TextField(controller: _daily, keyboardType: TextInputType.number),
              const SizedBox(height: 12),
              const Text('Подтверждать переводы больше', style: T.label),
              const SizedBox(height: 6),
              TextField(controller: _threshold, keyboardType: TextInputType.number),
              SwitchListTile(
                value: _allowNegative,
                onChanged: (v) => setState(() => _allowNegative = v),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: C.green,
                title: const Text('Разрешить уходить в минус', style: T.body),
              ),
              Btn('Сохранить', onPressed: _save, busy: _busy),
              const SizedBox(height: 28),
              const Text('РЕГУЛЯРНЫЕ НАЧИСЛЕНИЯ', style: T.caps),
              const SizedBox(height: 8),
              for (final a in allowances)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    child: Row(children: [
                      Expanded(
                        child: Text('${a['comment']} · ${weekdayNames[a['weekday'] as int].toLowerCase()}', style: T.body),
                      ),
                      Text('+${a['amount']}', style: T.bodyBold.copyWith(color: C.green)),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: C.text2),
                        onPressed: () async {
                          await ref.read(servicesProvider).api.delete('/spaces/${ref.read(spaceProvider).id}/allowances/${a['id']}');
                          ref.invalidate(allowancesProvider);
                        },
                      ),
                    ]),
                  ),
                ),
              DashedBox(onTap: _addAllowance, child: const Text('+ Добавить начисление', style: T.bodyBold)),
            ]),
          ),
        ]),
      ),
    );
  }
}
