import '../domain/progress_summary.dart';

class ProfileRepository {
  const ProfileRepository();

  Future<ProgressSummary> fetchProgress() async {
    return const ProgressSummary(completedStories: 0, completedGames: 0);
  }
}
