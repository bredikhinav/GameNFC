import 'package:intl/intl.dart';

final _grouped = NumberFormat.decimalPattern('ru');

String money(int value) => _grouped.format(value).replaceAll(' ', ' ');

String signed(int value) => value > 0 ? '+${money(value)}' : (value < 0 ? '−${money(-value)}' : '0');

/// Russian plural: plural(5, 'монета', 'монеты', 'монет') -> 'монет'.
String plural(int n, String one, String few, String many) {
  final mod10 = n.abs() % 10, mod100 = n.abs() % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

String coins(int n) => '${money(n)} ${plural(n, 'монета', 'монеты', 'монет')}';

String players(int n) => '$n ${plural(n, 'игрок', 'игрока', 'игроков')}';

String time(DateTime t) => DateFormat.Hm('ru').format(t.toLocal());

String dayTitle(DateTime t) {
  final local = t.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'СЕГОДНЯ';
  if (diff == 1) return 'ВЧЕРА';
  return DateFormat('d MMMM', 'ru').format(local).toUpperCase();
}

String agoText(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} ${plural(d.inMinutes, 'минуту', 'минуты', 'минут')} назад';
  if (d.inHours < 24) return '${d.inHours} ${plural(d.inHours, 'час', 'часа', 'часов')} назад';
  return DateFormat('d MMM, HH:mm', 'ru').format(t.toLocal());
}

String duration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '$h ч $m мин' : '$m мин';
}

/// "Маша" -> "Маши" for "Списано у Маши" — good enough for common Russian names.
String genitive(String name) {
  if (name.isEmpty) return name;
  final last = name[name.length - 1];
  final stem = name.substring(0, name.length - 1);
  final prev = stem.isEmpty ? '' : stem[stem.length - 1];
  const hushing = 'гкхжчшщ';
  if (last == 'а') return stem + (hushing.contains(prev) ? 'и' : 'ы');
  if (last == 'я') return '$stemи';
  if ('бвгдзклмнпрстфхжчшщц'.contains(last)) return '$nameа';
  return name;
}

/// "Тимур" -> "Тимуру" for "Перевести 30 Тимуру".
String dative(String name) {
  if (name.isEmpty) return name;
  final last = name[name.length - 1];
  final stem = name.substring(0, name.length - 1);
  if (last == 'а' || last == 'я') return '$stemе';
  if ('бвгдзклмнпрстфхжчшщц'.contains(last)) return '$nameу';
  return name;
}
