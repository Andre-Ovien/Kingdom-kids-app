import '../domain/parent_settings.dart';

class ParentalControlsRepository {
  const ParentalControlsRepository();

  Future<ParentSettings> fetchSettings() async {
    return const ParentSettings(dailyPlayMinutes: 30);
  }
}
