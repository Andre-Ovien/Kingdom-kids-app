import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Isolated visual concept. It is never imported by the app or its router.
/// Real integration would bind each page to a child profile, not an avatar list.
class ProfilePickerConceptEntry {
  const ProfilePickerConceptEntry({
    required this.id,
    required this.name,
    required this.avatarKey,
    required this.color,
    required this.asset,
    required this.sourceSize,
    required this.visibleBounds,
  });

  final String id;
  final String name;
  final String avatarKey;
  final Color color;
  final String asset;
  final Size sourceSize;
  final Rect visibleBounds;
}

const profilePickerConceptEntries = [
  ProfilePickerConceptEntry(
    id: 'preview-kai',
    name: 'Kai',
    avatarKey: 'lion',
    color: Color(0xFF009F6C),
    asset: 'assets/images/mascot/mascot_wave.png',
    sourceSize: Size(1024, 1536),
    visibleBounds: Rect.fromLTRB(162, 99, 795, 1358),
  ),
  ProfilePickerConceptEntry(
    id: 'preview-nia',
    name: 'Nia',
    avatarKey: 'dove',
    color: Color(0xFF854AE4),
    asset: 'assets/images/characters/poses/nia-standing.png',
    sourceSize: Size(1023, 1537),
    visibleBounds: Rect.fromLTRB(263, 70, 805, 1432),
  ),
  ProfilePickerConceptEntry(
    id: 'preview-zuri',
    name: 'Zuri',
    avatarKey: 'rainbow',
    color: Color(0xFFF84D68),
    asset: 'assets/images/characters/poses/zuri-standing.png',
    sourceSize: Size(1122, 1402),
    visibleBounds: Rect.fromLTRB(245, 50, 878, 1337),
  ),
];

class ProfilePickerConcept extends StatefulWidget {
  const ProfilePickerConcept({
    super.key,
    this.entries = profilePickerConceptEntries,
    this.initialPage = 0,
    this.onAddProfile,
    this.onSelectProfile,
    this.onBack,
  });

  final List<ProfilePickerConceptEntry> entries;
  final int initialPage;
  final VoidCallback? onAddProfile;
  final ValueChanged<ProfilePickerConceptEntry>? onSelectProfile;
  final VoidCallback? onBack;

  @override
  State<ProfilePickerConcept> createState() => _ProfilePickerConceptState();
}

class _ProfilePickerConceptState extends State<ProfilePickerConcept> {
  late final PageController _controller;
  late int _page;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    _controller = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: Colors.white,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final top = media.padding.top;
          final bottom = media.padding.bottom;
          final sy = (height - top - bottom) / 759;
          final sx = width / 393;
          final fontScale = math.min(sx, sy).clamp(0.84, 1.0);
          final heroTop = top + 146 * sy;
          return Stack(
            children: [
              Positioned(
                left: 20 * sx,
                top: top + 12 * sy,
                child: IconButton(
                  key: const Key('profile-concept-back'),
                  tooltip: 'Back',
                  onPressed: widget.onBack ?? () {},
                  style: _quietIconStyle,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 24),
                ),
              ),
              Positioned(
                right: 20 * sx,
                top: top + 12 * sy,
                child: IconButton(
                  key: const Key('profile-concept-add'),
                  tooltip: 'Add a child profile',
                  onPressed: widget.onAddProfile ?? () {},
                  style: _quietIconStyle,
                  icon: const Icon(Icons.add_rounded, size: 32),
                ),
              ),
              Positioned(
                top: top + 68 * sy,
                left: 28 * sx,
                right: 28 * sx,
                child: Text(
                  'Who’s ready\nto explore?',
                  key: const Key('profile-concept-heading'),
                  style: TextStyle(
                    fontFamily: 'OnboardingPoppins',
                    fontSize: 31 * fontScale,
                    fontWeight: FontWeight.w700,
                    height: 1.16,
                    letterSpacing: -1.1,
                    color: const Color(0xFF17221F),
                  ),
                ),
              ),
              Positioned(
                top: heroTop,
                left: 0,
                right: 0,
                bottom: bottom + 38 * sy,
                child: PageView.builder(
                  key: const Key('profile-concept-pages'),
                  controller: _controller,
                  itemCount: widget.entries.length,
                  onPageChanged: (page) => setState(() => _page = page),
                  itemBuilder: (context, index) => _CharacterPage(
                    entry: widget.entries[index],
                    scaleX: sx,
                    scaleY: sy,
                    fontScale: fontScale,
                    onSelect: () =>
                        widget.onSelectProfile?.call(widget.entries[index]),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: bottom + 6 * sy,
                child: Row(
                  key: const Key('profile-concept-indicators'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var index = 0; index < widget.entries.length; index++)
                      Semantics(
                        button: true,
                        selected: _page == index,
                        label: 'Show ${widget.entries[index].name}',
                        child: GestureDetector(
                          key: Key('profile-concept-dot-$index'),
                          onTap: () => _controller.animateToPage(
                            index,
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.easeInOutCubic,
                          ),
                          behavior: HitTestBehavior.opaque,
                          child: SizedBox(
                            width: 36,
                            height: 40,
                            child: Center(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: _page == index ? 22 : 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _page == index
                                      ? widget.entries[index].color
                                      : const Color(0xFFD6DBD8),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final _quietIconStyle = IconButton.styleFrom(
  foregroundColor: const Color(0xFF17221F),
  overlayColor: Colors.transparent,
  splashFactory: NoSplash.splashFactory,
  minimumSize: const Size(48, 48),
);

class _CharacterPage extends StatelessWidget {
  const _CharacterPage({
    required this.entry,
    required this.scaleX,
    required this.scaleY,
    required this.fontScale,
    required this.onSelect,
  });

  final ProfilePickerConceptEntry entry;
  final double scaleX;
  final double scaleY;
  final double fontScale;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleHeight = 420 * scaleY;
        final imageScale = visibleHeight / entry.visibleBounds.height;
        final visibleWidth = entry.visibleBounds.width * imageScale;
        final visibleLeft = (constraints.maxWidth - visibleWidth) / 2;
        final imageLeft = visibleLeft - entry.visibleBounds.left * imageScale;
        final imageTop = 33 * scaleY - entry.visibleBounds.top * imageScale;
        final cardTop = 161 * scaleY;
        final cardBottom = constraints.maxHeight - 18 * scaleY;
        return Stack(
          children: [
            Positioned(
              left: 28 * scaleX,
              right: 28 * scaleX,
              top: cardTop,
              bottom: 18 * scaleY,
              child: ClipPath(
                clipper: _AngledCardClipper(drop: 64 * scaleY),
                child: ColoredBox(color: entry.color),
              ),
            ),
            Positioned(
              left: constraints.maxWidth / 2 - 66 * scaleX,
              top: (33 + 420) * scaleY - 5,
              width: 132 * scaleX,
              height: 15 * scaleY,
              child: CustomPaint(painter: _GroundShadowPainter()),
            ),
            Positioned(
              left: imageLeft,
              top: imageTop,
              width: entry.sourceSize.width * imageScale,
              height: entry.sourceSize.height * imageScale,
              child: Image.asset(
                entry.asset,
                key: Key('profile-concept-art-${entry.id}'),
                fit: BoxFit.fill,
                semanticLabel: '${entry.name}, full character illustration',
                filterQuality: FilterQuality.high,
              ),
            ),
            Positioned(
              left: 48 * scaleX,
              right: 118 * scaleX,
              top: cardBottom - 86 * scaleY,
              child: Text(
                entry.name,
                key: Key('profile-concept-name-${entry.id}'),
                style: TextStyle(
                  fontFamily: 'OnboardingPoppins',
                  fontSize: 39 * fontScale,
                  height: 1.14,
                  letterSpacing: -1,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            Positioned(
              right: 47 * scaleX,
              top: cardBottom - 80 * scaleY,
              child: IconButton.filled(
                key: Key('profile-concept-select-${entry.id}'),
                tooltip: 'Select ${entry.name} profile',
                onPressed: onSelect,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF17221F),
                  overlayColor: Colors.transparent,
                  splashFactory: NoSplash.splashFactory,
                  fixedSize: const Size(56, 56),
                ),
                icon: const Icon(Icons.arrow_forward_rounded, size: 30),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AngledCardClipper extends CustomClipper<Path> {
  const _AngledCardClipper({required this.drop});
  final double drop;

  @override
  Path getClip(Size size) {
    const r = 28.0;
    return Path()
      ..moveTo(0, drop + r)
      ..quadraticBezierTo(0, drop + 4, r, drop - 2)
      ..lineTo(size.width - r, 4)
      ..quadraticBezierTo(size.width, -2, size.width, r)
      ..lineTo(size.width, size.height - r)
      ..quadraticBezierTo(size.width, size.height, size.width - r, size.height)
      ..lineTo(r, size.height)
      ..quadraticBezierTo(0, size.height, 0, size.height - r)
      ..close();
  }

  @override
  bool shouldReclip(_AngledCardClipper oldClipper) => oldClipper.drop != drop;
}

class _GroundShadowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawOval(
      Offset.zero & size,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
  }

  @override
  bool shouldRepaint(_GroundShadowPainter oldDelegate) => false;
}
