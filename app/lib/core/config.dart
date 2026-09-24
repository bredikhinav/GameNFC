/// Build-time settings: `flutter run --dart-define=API_URL=http://10.0.2.2:8000`.
abstract final class Config {
  static const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://fantikpay.ru');
  static String get apiBase => '$apiUrl/api/v1';

  /// Cards carry `https://fantikpay.ru/c/<token>`; tokens from any of these hosts are accepted.
  static const cardHosts = {'fantikpay.ru', 'www.fantikpay.ru'};

  /// Enables typing a card token instead of tapping (emulators, demos without cards).
  static const debugCards = bool.fromEnvironment('DEBUG_CARDS', defaultValue: false);
}
