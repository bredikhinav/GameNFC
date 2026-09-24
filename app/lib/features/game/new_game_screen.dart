import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../data/bank.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';

final templatesProvider = StreamProvider<List<Template>>((ref) {
  final db = ref.watch(servicesProvider).db;
  return (db.select(db.templates)..orderBy([(t) => OrderingTerm(expression: t.name)])).watch();
});

class NewGameScreen extends ConsumerStatefulWidget {
  const NewGameScreen({super.key});

  @override
  ConsumerState<NewGameScreen> createState() => _NewGameScreenState();
}

class _NewGameScreenState extends ConsumerState<NewGameScreen> {
  bool _bank = true;
  String _mode = 'reset';
  Template? _template;
  final _capital = TextEditingController(text: '1500');
  final _name = TextEditingController();
  bool _busy = false;

  Future<void> _next() async {
    if (!_bank) {
      final ok = await confirm(
        context,
        'Сделать телефон телефоном игрока?',
        'На этом телефоне выйдет взрослый аккаунт, и появится детский режим: баланс, переводы, итоги. '
            'Понадобится QR-код с телефона родителя.',
        ok: 'Да, это телефон ребёнка',
      );
      if (!ok || !mounted) return;
      await ref.read(authProvider.notifier).logout();
      if (mounted) context.go('/claim');
      return;
    }
    setState(() => _busy = true);
    try {
      final capital = int.tryParse(_capital.text) ?? 0;
      final name = _name.text.trim().isNotEmpty ? _name.text.trim() : (_template?.name ?? 'Игра');
      final id = await ref.read(bankProvider).createSession(
            name: name,
            moneyMode: _mode,
            startingCapital: capital,
            quickButtons: _template == null ? const [] : QuickButton.parse(_template!.quickButtons),
            templateId: _template?.builtin == true ? null : _template?.id,
          );
      if (mounted) context.pushReplacement('/game/$id/lobby');
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = ref.watch(templatesProvider).value ?? const <Template>[];
    _template ??= templates.firstOrNull;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const ScreenHeader('Новая игра'),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 20), children: [
              const Text('Этот телефон будет', style: T.label),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _RoleCard(
                  selected: _bank,
                  icon: Icons.account_balance_outlined,
                  iconBg: C.green,
                  title: 'Банк',
                  text: 'Терминал ведущего: списания, начисления, итоги',
                  onTap: () => setState(() => _bank = true),
                )),
                const SizedBox(width: 12),
                Expanded(child: _RoleCard(
                  selected: !_bank,
                  icon: Icons.person_outline_rounded,
                  iconBg: C.coin,
                  title: 'Игрок',
                  text: 'Телефон ребёнка: баланс, переводы, итоги',
                  onTap: () => setState(() => _bank = false),
                )),
              ]),
              if (_bank) ...[
                const SizedBox(height: 22),
                const Text('Деньги в игре', style: T.label),
                const SizedBox(height: 10),
                _ModeOption(
                  selected: _mode == 'reset',
                  title: 'С обнулением',
                  text: 'У всех одинаковый старт, копилки не трогаем',
                  onTap: () => setState(() => _mode = 'reset'),
                ),
                const SizedBox(height: 10),
                _ModeOption(
                  selected: _mode == 'persistent',
                  title: 'Постоянный счёт',
                  text: 'Играем на накопленные монеты',
                  onTap: () => setState(() => _mode = 'persistent'),
                ),
                const SizedBox(height: 22),
                const Text('Шаблон игры', style: T.label),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _template?.id,
                  items: [for (final t in templates) DropdownMenuItem(value: t.id, child: Text(t.name))],
                  onChanged: (id) => setState(() {
                    _template = templates.firstWhere((t) => t.id == id);
                    _capital.text = '${_template!.startingCapital}';
                  }),
                ),
                const SizedBox(height: 16),
                const Text('Название (необязательно)', style: T.label),
                const SizedBox(height: 8),
                TextField(controller: _name, decoration: InputDecoration(hintText: _template?.name ?? 'Игра')),
                if (_mode == 'reset') ...[
                  const SizedBox(height: 16),
                  const Text('Стартовый капитал', style: T.label),
                  const SizedBox(height: 8),
                  TextField(controller: _capital, keyboardType: TextInputType.number),
                ],
                const SizedBox(height: 24),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Btn(_bank ? 'Дальше: собрать игроков' : 'Дальше', onPressed: _next, busy: _busy),
          ),
        ]),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.selected, required this.icon, required this.iconBg, required this.title, required this.text, required this.onTap});

  final bool selected;
  final IconData icon;
  final Color iconBg;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: selected ? C.green : C.border, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, color: Colors.white),
                ),
                const Spacer(),
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? C.green : C.text2),
              ]),
              const SizedBox(height: 14),
              Text(title, style: T.title),
              const SizedBox(height: 4),
              Text(text, style: T.small.copyWith(fontSize: 13, height: 1.35)),
            ]),
          ),
        ),
      );
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({required this.selected, required this.title, required this.text, required this.onTap});

  final bool selected;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: selected ? C.green : C.border, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? C.green : C.text2),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: T.bodyBold),
                  Text(text, style: T.small),
                ]),
              ),
            ]),
          ),
        ),
      );
}
