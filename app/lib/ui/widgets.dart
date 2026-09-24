import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/errors.dart';
import '../core/theme.dart';
import '../data/db.dart';

// --- Buttons ---------------------------------------------------------------------------

enum BtnKind { green, dark, outline, danger }

class Btn extends StatelessWidget {
  const Btn(this.label, {super.key, this.onPressed, this.kind = BtnKind.green, this.icon, this.busy = false, this.height = 56});

  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final IconData? icon;
  final bool busy;
  final double height;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, side) = switch (kind) {
      BtnKind.green => (C.green, Colors.white, BorderSide.none),
      BtnKind.dark => (C.ink, Colors.white, BorderSide.none),
      BtnKind.outline => (C.surface, C.ink, const BorderSide(color: C.borderStrong)),
      BtnKind.danger => (C.surface, C.red, const BorderSide(color: C.borderStrong)),
    };
    final enabled = onPressed != null && !busy;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: TextButton(
        onPressed: enabled ? onPressed : null,
        style: TextButton.styleFrom(
          backgroundColor: enabled ? bg : bg.withValues(alpha: 0.55),
          foregroundColor: fg,
          disabledForegroundColor: fg.withValues(alpha: 0.8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: side),
          textStyle: T.button.copyWith(fontFamily: 'Manrope'),
        ),
        child: busy
            ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: fg))
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[Icon(icon, size: 22), const SizedBox(width: 10)],
                  Flexible(child: Text(label, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis)),
                ],
              ),
      ),
    );
  }
}

class CircleBack extends StatelessWidget {
  const CircleBack({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => CircleIconButton(
        icon: Icons.chevron_left_rounded,
        onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
      );
}

class CircleIconButton extends StatelessWidget {
  const CircleIconButton({super.key, required this.icon, this.onPressed, this.size = 46});

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        shape: const CircleBorder(side: BorderSide(color: C.border)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(width: size, height: size, child: Icon(icon, color: C.ink, size: 24)),
        ),
      );
}

class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, this.onPressed, this.selected = false, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? C.ink : C.surface,
        shape: StadiumBorder(side: BorderSide(color: selected ? C.ink : C.borderStrong)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, size: 18, color: selected ? Colors.white : C.ink), const SizedBox(width: 6)],
              Text(label, style: T.label.copyWith(color: selected ? Colors.white : C.ink, fontSize: 14)),
            ]),
          ),
        ),
      );
}

// --- Surfaces --------------------------------------------------------------------------

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color = C.surface, this.onTap, this.border = true});

  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final VoidCallback? onTap;
  final bool border;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: border ? const BorderSide(color: C.border) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.child, this.onTap, this.height = 64});

  final Widget child;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: CustomPaint(
          painter: _DashPainter(),
          child: SizedBox(height: height, width: double.infinity, child: Center(child: child)),
        ),
      );
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = C.borderStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)));
    for (final metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Label/value rows inside a white card ("Остаток 1300").
class InfoRows extends StatelessWidget {
  const InfoRows(this.rows, {super.key});

  final List<(String, Widget)> rows;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(children: [
                Expanded(child: Text(rows[i].$1, style: T.secondary.copyWith(fontSize: 15))),
                rows[i].$2,
              ]),
            ),
          ],
        ]),
      );
}

class Note extends StatelessWidget {
  const Note(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: C.surfaceSand, borderRadius: BorderRadius.circular(18)),
        child: Text(text, style: T.secondary.copyWith(color: C.inkSoft)),
      );
}

// --- Identity --------------------------------------------------------------------------

const _avatarColors = [
  (C.peach, C.redDark),
  (C.greenMint, C.greenDark),
  (C.lilac, C.violet),
  (C.coinPale, Color(0xFF6B4A08)),
];

class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 44, this.seed});

  final String name;
  final double size;
  final String? seed;

  @override
  Widget build(BuildContext context) {
    final key = (seed ?? name).codeUnits.fold<int>(0, (a, b) => a + b);
    final (bg, fg) = _avatarColors[key % _avatarColors.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(fontFamily: 'Unbounded', fontWeight: FontWeight.w700, fontSize: size * 0.38, color: fg),
      ),
    );
  }
}

class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar(this.player, {super.key, this.size = 44});

  final Player player;
  final double size;

  @override
  Widget build(BuildContext context) => Avatar(player.name, size: size, seed: player.id);
}

class Coin extends StatelessWidget {
  const Coin({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: C.coin,
          shape: BoxShape.circle,
          border: Border.all(color: C.coinDark, width: size * 0.12),
        ),
      );
}

class NfcBadge extends StatelessWidget {
  const NfcBadge({super.key, this.color = Colors.white, this.size = 22});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Icon(Icons.contactless_outlined, color: color, size: size);
}

// --- Screens ---------------------------------------------------------------------------

class ScreenHeader extends StatelessWidget {
  const ScreenHeader(this.title, {super.key, this.subtitle, this.back = true, this.trailing, this.onBack});

  final String title;
  final String? subtitle;
  final bool back;
  final Widget? trailing;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(children: [
          if (back) ...[CircleBack(onPressed: onBack), const SizedBox(width: 14)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: T.h2, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (subtitle != null) Text(subtitle!, style: T.small.copyWith(fontSize: 13)),
            ]),
          ),
          ?trailing,
        ]),
      );
}

/// Big round icon + title + text: results and errors.
class StatusHero extends StatelessWidget {
  const StatusHero({super.key, required this.icon, required this.color, required this.halo, this.iconColor = Colors.white});

  final IconData icon;
  final Color color;
  final Color halo;
  final Color iconColor;

  @override
  Widget build(BuildContext context) => Container(
        width: 112,
        height: 112,
        decoration: BoxDecoration(color: halo, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: iconColor, size: 36),
        ),
      );
}

class OfflinePill extends StatelessWidget {
  const OfflinePill({super.key, this.text = 'Нет сети · отправится позже'});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: C.surfaceSand, borderRadius: BorderRadius.circular(40)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, size: 18, color: C.inkSoft),
          const SizedBox(width: 8),
          Text(text, style: T.label.copyWith(color: C.inkSoft)),
        ]),
      );
}

// --- Keypad ----------------------------------------------------------------------------

class Keypad extends StatelessWidget {
  const Keypad({super.key, required this.onDigit, required this.onBackspace, this.dark = false, this.doubleZero = true, this.keyHeight = 58});

  final void Function(String digit) onDigit;
  final VoidCallback onBackspace;
  final bool dark;
  final bool doubleZero;
  final double keyHeight;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, Widget? child}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Material(
              color: dark ? const Color(0xFF2E3444) : C.surface,
              borderRadius: BorderRadius.circular(dark ? 40 : 16),
              child: InkWell(
                borderRadius: BorderRadius.circular(dark ? 40 : 16),
                onTap: onTap == null
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        onTap();
                      },
                child: SizedBox(
                  height: keyHeight,
                  child: Center(
                    child: child ?? Text(label, style: T.key.copyWith(color: dark ? Colors.white : C.ink)),
                  ),
                ),
              ),
            ),
          ),
        );
    Widget row(List<String> digits) => Row(children: [for (final d in digits) key(d, onTap: () => onDigit(d))]);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      row(['1', '2', '3']),
      row(['4', '5', '6']),
      row(['7', '8', '9']),
      Row(children: [
        if (doubleZero) key('00', onTap: () => onDigit('00')) else const Expanded(child: SizedBox()),
        key('0', onTap: () => onDigit('0')),
        key('', onTap: onBackspace, child: Icon(Icons.backspace_outlined, color: dark ? Colors.white : C.ink)),
      ]),
    ]);
  }
}

// --- Feedback --------------------------------------------------------------------------

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

String describe(Object error) => switch (error) {
      ApiError e => e.message,
      OfflineError _ => 'Нет сети. Попробуйте, когда появится интернет',
      _ => 'Что-то пошло не так',
    };

Future<bool> confirm(BuildContext context, String title, String text, {String ok = 'Да', bool danger = false}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: C.bg,
      title: Text(title, style: T.h3),
      content: Text(text, style: T.secondary),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(ok, style: TextStyle(color: danger ? C.red : C.green, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  return result ?? false;
}
