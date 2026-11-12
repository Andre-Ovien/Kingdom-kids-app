/// Story-library choices only. Matching games, puzzles and quizzes keep their
/// separate catalogues, including activities based on these stories.
const unavailableStorySlugs = {'lost-sheep', 'good-samaritan'};

bool isStoryAvailable(String slug) =>
    !unavailableStorySlugs.contains(slug.trim().toLowerCase());
