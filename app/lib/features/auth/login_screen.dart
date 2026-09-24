import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: C.coin,
          shape: BoxShape.circle,
          border: Border.all(color: C.coinDark, width: size * 0.07),
        ),
        child: Text('Ф', style: T.h1.copyWith(fontSize: size * 0.4)),
      );
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).login(_email.text.trim(), _password.text);
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          children: [
            const Center(child: Logo()),
            const SizedBox(height: 20),
            const Text('ФантикПэй', textAlign: TextAlign.center, style: T.h1),
            const SizedBox(height: 10),
            Text(
              'Игровой банк для детей. Аккаунт создаёт взрослый, дети играют картами.',
              textAlign: TextAlign.center,
              style: T.secondary.copyWith(fontSize: 16),
            ),
            const SizedBox(height: 28),
            Panel(
              padding: const EdgeInsets.all(20),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Электронная почта', style: T.label),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(hintText: 'name@mail.ru', fillColor: C.bg),
                  ),
                  const SizedBox(height: 16),
                  const Text('Пароль', style: T.label),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(fillColor: C.bg),
                    onSubmitted: (_) => _login(),
                  ),
                  const SizedBox(height: 16),
                  Btn('Войти', onPressed: _login, busy: _busy),
                ]),
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: TextButton(
                onPressed: () => context.push('/register'),
                child: Text('Создать аккаунт родителя',
                    style: T.bodyBold.copyWith(color: C.green, decoration: TextDecoration.underline, decorationColor: C.green)),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => context.push('/claim'),
                child: Text('У меня QR-код от родителя',
                    style: T.secondary.copyWith(decoration: TextDecoration.underline, decorationColor: C.text2)),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => context.push('/forgot'),
                child: Text('Забыли пароль?', style: T.small),
              ),
            ),
            const SizedBox(height: 24),
            const LegalNote(),
          ],
        ),
      ),
    );
  }
}

class LegalNote extends StatelessWidget {
  const LegalNote({super.key});

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(
          style: T.small.copyWith(height: 1.5),
          children: [
            const TextSpan(
              text: 'Монеты в игре виртуальные: их нельзя купить или обменять на деньги. '
                  'Продолжая, вы соглашаетесь с ',
            ),
            TextSpan(
              text: 'политикой обработки персональных данных',
              style: const TextStyle(decoration: TextDecoration.underline),
              recognizer: TapGestureRecognizer()..onTap = () {},
            ),
            const TextSpan(text: '.'),
          ],
        ),
        textAlign: TextAlign.center,
      );
}
