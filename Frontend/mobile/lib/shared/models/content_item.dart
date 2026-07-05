enum ContentKind { story, video, game, verse }

class ContentItem {
  const ContentItem({
    required this.id,
    required this.title,
    required this.kind,
  });

  final String id;
  final String title;
  final ContentKind kind;
}
