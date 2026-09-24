import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider) as AdultSession;
    final space = auth.space;
    final pending = ref.watch(outboxCountProvider).value ?? 0;
    final online = ref.watch(onlineProvider).value ?? true;
    final s = ref.read(servicesProvider);

    Widget row(String title, String? value, {VoidCallback? onTap, IconData icon = Icons.chevron_right_rounded}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(children: [
              Expanded(child: Text(title, style: T.body)),
              if (value != null) Text(value, style: T.secondary),
              if (onTap != null) Icon(icon, color: C.text2),
            ]),
          ),
        );

    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Настройки', style: T.h1),
      const SizedBox(height: 16),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          row('Аккаунт', auth.email),
          const Divider(),
          row('PIN-код терминала', auth.pin == null ? 'не задан' : 'задан', onTap: () => _setPin(context, ref)),
          const Divider(),
          row('Синхронизация', pending > 0 ? '$pending ${plural(pending, 'операция', 'операции', 'операций')} ждут' : (online ? 'всё отправлено' : 'нет сети'),
              icon: Icons.sync_rounded, onTap: () async {
            final r = await s.sync.sync();
            if (context.mounted) toast(context, r.offline ? 'Нет сети' : 'Готово');
          }),
        ]),
      ),
      const SizedBox(height: 16),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          row(space.isOrganization ? 'Организация' : 'Семья', space.name),
          const Divider(),
          row('Валюта', '${space.currencyIcon} ${space.currencyName}'),
          if (space.isAdmin) ...[
            const Divider(),
            row('Правила и начисления', null, onTap: () => context.push('/rules')),
            const Divider(),
            row('Взрослые и ведущие', null, onTap: () => context.push('/members')),
          ],
          if (auth.spaces.length > 1) ...[
            const Divider(),
            row('Сменить пространство', null, onTap: () => _switchSpace(context, ref, auth)),
          ],
        ]),
      ),
      const SizedBox(height: 24),
      Btn('Выйти', kind: BtnKind.danger, onPressed: () async {
        final warn = pending > 0 ? '\n\nНа телефоне $pending неотправленных операций — они пропадут.' : '';
        if (await confirm(context, 'Выйти из аккаунта?', 'Данные на этом телефоне будут удалены.$warn', ok: 'Выйти', danger: true)) {
          await ref.read(authProvider.notifier).logout();
        }
      }),
      const SizedBox(height: 16),
      Text('ФантикПэй · монеты виртуальные и не обмениваются на деньги', textAlign: TextAlign.center, style: T.small),
    ]);
  }

  Future<void> _setPin(BuildContext context, WidgetRef ref) async {
    final pin = TextEditingController();
    final password = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('PIN-код взрослого', style: T.h2),
          const SizedBox(height: 8),
          const Text('Нужен, чтобы выйти из режима банка или отменить операцию. Работает и без интернета.', style: T.secondary),
          const SizedBox(height: 16),
          TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 4,
              decoration: const InputDecoration(hintText: '4 цифры', counterText: '')),
          const SizedBox(height: 12),
          TextField(controller: password, obscureText: true, decoration: const InputDecoration(hintText: 'Пароль от аккаунта')),
          const SizedBox(height: 16),
          Btn('Сохранить', onPressed: () async {
            try {
              await ref.read(servicesProvider).api.put('/auth/pin', {'pin': pin.text, 'password': password.text});
              if (context.mounted) Navigator.pop(context, true);
            } on Exception catch (e) {
              if (context.mounted) toast(context, describe(e));
            }
          }),
        ]),
      ),
    );
    if (ok == true) await ref.read(authProvider.notifier).refreshUser();
  }

  Future<void> _switchSpace(BuildContext context, WidgetRef ref, AdultSession auth) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => ListView(shrinkWrap: true, children: [
        for (final s in auth.spaces)
          ListTile(title: Text(s.name), trailing: s.id == auth.space.id ? const Icon(Icons.check) : null, onTap: () => Navigator.pop(context, s.id)),
      ]),
    );
    if (id != null) await ref.read(authProvider.notifier).switchSpace(id);
  }
}
