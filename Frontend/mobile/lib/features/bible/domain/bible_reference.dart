class BibleReference {
  const BibleReference({required this.book, required this.chapter, this.verse});

  final String book;
  final int chapter;
  final int? verse;
}
