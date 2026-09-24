import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';
import 'login_screen.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _accepted = false;
  bool _busy = false;

  Future<void> _submit() async {
    if (_password.text.length < 8) {
      toast(context, 'Пароль — минимум 8 символов');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).register(_name.text.trim(), _email.text.trim(), _password.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const ScreenHeader('Аккаунт родителя'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text(
                    'Аккаунт создаёт взрослый. Детям почта и телефон не нужны: им хватит карты и прозвища.',
                    style: T.secondary,
                  ),
                  const SizedBox(height: 20),
                  const Text('Как к вам обращаться', style: T.label),
                  const SizedBox(height: 8),
                  TextField(controller: _name, textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(hintText: 'Например, Мама')),
                  const SizedBox(height: 16),
                  const Text('Электронная почта', style: T.label),
                  const SizedBox(height: 8),
                  TextField(controller: _email, keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(hintText: 'name@mail.ru')),
                  const SizedBox(height: 16),
                  const Text('Пароль', style: T.label),
                  const SizedBox(height: 8),
                  TextField(controller: _password, obscureText: true,
                      decoration: const InputDecoration(hintText: 'Минимум 8 символов')),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    value: _accepted,
                    onChanged: (v) => setState(() => _accepted = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'Мне есть 18 лет. Я принимаю пользовательское соглашение и политику обработки персональных данных',
                      style: T.secondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Btn('Создать аккаунт', onPressed: _accepted ? _submit : null, busy: _busy),
                  const SizedBox(height: 24),
                  const LegalNote(),
                ]),
              ),
            ],
          ),
        ),
      );
}
