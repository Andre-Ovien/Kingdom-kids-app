import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../stories/domain/story_detail.dart';
import '../../stories/presentation/story_cover_image.dart';

/// The established Home story card, shared by Story picks and Continue reading.
class HomeStoryCard extends StatelessWidget {
  const HomeStoryCard({
    required this.story,
    required this.paletteIndex,
    required this.onTap,
    required this.metadata,
    this.semanticActionLabel = 'Read',
    this.isOpening = false,
    this.tapKey,
    super.key,
  });

  final StoryDetail story;
  final int paletteIndex;
  final VoidCallback? onTap;
  final String metadata;
  final String semanticActionLabel;
  final bool isOpening;
  final Key? tapKey;

  static bool usesVerticalLayout(BuildContext context, double width) =>
      width < 335 || MediaQuery.textScalerOf(context).scale(1) > 1.15;

  static TextStyle _titleStyle(BuildContext context, Color ink) =>
      (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
        color: ink,
        fontSize: 19,
        height: 1,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.45,
      );

  static TextStyle _summaryStyle(BuildContext context, Color ink) =>
      (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).copyWith(
        color: ink.withValues(alpha: 0.72),
        fontWeight: FontWeight.w600,
        height: 1.2,
      );

  static TextStyle _metadataStyle(BuildContext context, Color ink) =>
      (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
        color: ink,
        fontWeight: FontWeight.w900,
      );

  /// A PageView needs an explicit height; ordinary vertical story cards keep
  /// their natural size. Measure the same text so large type is never clipped.
  static double heightFor({
    required BuildContext context,
    required double width,
    required StoryDetail story,
    required String metadata,
  }) {
    if (!usesVerticalLayout(context, width)) return 166;
    final textWidth = math.max(1.0, width - 26);
    double textHeight(
      String text,
      TextStyle style,
      int maxLines,
      double width,
    ) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: maxLines,
        ellipsis: '…',
      )..layout(maxWidth: width);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    const ink = Color(0xFF171421);
    return 150 +
        25 +
        textHeight(story.title, _titleStyle(context, ink), 2, textWidth) +
        6 +
        textHeight(story.summary, _summaryStyle(context, ink), 2, textWidth) +
        10 +
        math.max(
          37,
          textHeight(
            metadata,
            _metadataStyle(context, ink),
            1,
            math.max(1.0, textWidth - 45),
          ),
        ) +
        2;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xFFFFFCF6) : const Color(0xFF171421);
    final paper = dark ? const Color(0xFF181B1A) : const Color(0xFFFFFCF6);
    const colors = [
      Color(0xFF6FDB9A),
      Color(0xFFFF9DCF),
      Color(0xFF65C8F5),
      Color(0xFFFFD34E),
    ];
    final baseColor = colors[paletteIndex % colors.length];
    final color = dark
        ? Color.alphaBlend(Colors.black.withValues(alpha: 0.52), baseColor)
        : baseColor;
    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical = usesVerticalLayout(context, constraints.maxWidth);
        final cover = SizedBox(
          height: vertical ? 150 : double.infinity,
          width: vertical ? double.infinity : 116,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                right: vertical
                    ? BorderSide.none
                    : BorderSide(color: ink, width: 2.2),
                bottom: vertical
                    ? BorderSide(color: ink, width: 2.2)
                    : BorderSide.none,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: StoryCoverImage(story: story),
          ),
        );
        final details = Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                story.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _titleStyle(context, ink),
              ),
              const SizedBox(height: 6),
              Text(
                story.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _summaryStyle(context, ink),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (metadata.isNotEmpty)
                    Expanded(
                      child: Text(
                        isOpening ? 'Opening…' : metadata,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _metadataStyle(context, ink),
                      ),
                    )
                  else
                    const Spacer(),
                  const SizedBox(width: 8),
                  Container(
                    width: 37,
                    height: 37,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: ink, width: 2),
                    ),
                    child: isOpening
                        ? Padding(
                            padding: const EdgeInsets.all(8),
                            child: CircularProgressIndicator(
                              color: ink,
                              strokeWidth: 2,
                            ),
                          )
                        : Icon(
                            Icons.arrow_forward_rounded,
                            color: ink,
                            size: 21,
                          ),
                  ),
                ],
              ),
            ],
          ),
        );
        return Semantics(
          button: true,
          enabled: onTap != null,
          label: isOpening
              ? 'Opening ${story.title}'
              : '$semanticActionLabel ${story.title}',
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
            child: Material(
              color: paper,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: ink, width: 2.2),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: tapKey,
                onTap: onTap,
                child: vertical
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [cover, details],
                      )
                    : SizedBox(
                        height: 166,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            cover,
                            Expanded(child: details),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
