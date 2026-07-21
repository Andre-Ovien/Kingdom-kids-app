import '../../auth/data/auth_repository.dart';
import '../domain/story_detail.dart';
import 'story_api.dart';

abstract interface class StoryRepository {
  Future<List<StoryDetail>> fetchStories({String? search, String? category});

  Future<StoryDetail> fetchStory(String slug);
}

/// Fetches story content with the parent's refresh-aware authenticated session.
class RemoteStoryRepository implements StoryRepository {
  RemoteStoryRepository({AuthRepository? authRepository, StoryApi? api})
    : _authRepository = authRepository ?? AuthRepository(),
      _api = api ?? HttpStoryApi();

  final AuthRepository _authRepository;
  final StoryApi _api;

  @override
  Future<List<StoryDetail>> fetchStories({String? search, String? category}) {
    return _authRepository.withAccessToken(
      (accessToken) =>
          _api.fetchStories(accessToken, search: search, category: category),
    );
  }

  @override
  Future<StoryDetail> fetchStory(String slug) {
    return _authRepository.withAccessToken(
      (accessToken) => _api.fetchStory(slug, accessToken),
    );
  }
}
