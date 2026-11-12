import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/kid_profile.dart';
import 'kid_profile_avatar.dart';

/// Each page is an actual child profile. Avatars control artwork, never identity.
class ProfilePickerCarousel extends StatefulWidget {
  const ProfilePickerCarousel({
    super.key,
    required this.profiles,
    required this.onAddProfile,
    required this.onSelectProfile,
    this.onBack,
    this.selectingProfileId,
    this.isAddingProfile = false,
  }) : assert(profiles.length > 0);

  final List<KidProfile> profiles;
  final VoidCallback onAddProfile;
  final ValueChanged<KidProfile> onSelectProfile;
  final VoidCallback? onBack;
  final String? selectingProfileId;
  final bool isAddingProfile;

  @override
  State<ProfilePickerCarousel> createState() => _ProfilePickerCarouselState();
}

class _ProfilePickerCarouselState extends State<ProfilePickerCarousel> {
  final _pageController = PageController();
  final _indicatorController = ScrollController();
  int _page = 0;
  int _listRevision = 0;
  late String _visibleProfileId;

  bool get _busy => widget.selectingProfileId != null || widget.isAddingProfile;

  @override
  void initState() {
    super.initState();
    _visibleProfileId = widget.profiles.first.id;
  }

  @override
  void didUpdateWidget(ProfilePickerCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.profiles.map((profile) => profile.id).toList();
    final newIds = widget.profiles.map((profile) => profile.id).toList();
    if (listEquals(oldIds, newIds)) return;
    final retainedIndex = newIds.indexOf(_visibleProfileId);
    _page = retainedIndex >= 0
        ? retainedIndex
        : _page.clamp(0, widget.profiles.length - 1);
    _visibleProfileId = widget.profiles[_page].id;
    final revision = ++_listRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _listRevision) return;
      if (_pageController.hasClients) _pageController.jumpToPage(_page);
      _revealIndicator();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _indicatorController.dispose();
    super.dispose();
  }

  void _showPage(int page) {
    if (_busy) return;
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    if (reducedMotion) {
      _pageController.jumpToPage(page);
    } else {
      _pageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _revealIndicator() {
    if (!_indicatorController.hasClients) return;
    final position = _indicatorController.position;
    final target = (_page * 44 + 22 - position.viewportDimension / 2).clamp(
      0.0,
      position.maxScrollExtent,
    );
    _indicatorController.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = dark ? Colors.white : const Color(0xFF17221F);
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF101C19) : Colors.white,
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final top = media.viewPadding.top;
          final bottom = media.viewPadding.bottom;
          final sy = math.max(0.45, (height - top - bottom) / 759);
          final sx = width / 393;
          final fontScale = math.min(sx, sy).clamp(0.84, 1.0);
          final headingStyle = TextStyle(
            fontFamily: 'OnboardingPoppins',
            fontSize: 31 * fontScale,
            fontWeight: FontWeight.w700,
            height: 1.16,
            letterSpacing: -1.1,
            color: foreground,
          );
          final headingHeight = _textHeight(
            context,
            'Who’s ready\nto explore?',
            headingStyle,
            width - 56 * sx,
          );
          final headingTop = top + 68 * sy;
          final heroTop = headingTop + headingHeight + 6 * sy;
          final extraHeading = math.max(0.0, headingHeight - 72 * sy);
          return Stack(
            children: [
              if (widget.onBack != null)
                Positioned(
                  left: 20 * sx,
                  top: top + 12 * sy,
                  child: IconButton(
                    key: const Key('profile-picker-back'),
                    tooltip: 'Back',
                    onPressed: _busy ? null : widget.onBack,
                    style: _quietIconStyle(foreground),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 24,
                    ),
                  ),
                ),
              Positioned(
                right: 20 * sx,
                top: top + 12 * sy,
                child: IconButton(
                  key: const Key('profile-picker-add-child'),
                  tooltip: 'Add a child profile',
                  onPressed: _busy ? null : widget.onAddProfile,
                  style: _quietIconStyle(foreground),
                  icon: const Icon(Icons.add_rounded, size: 32),
                ),
              ),
              Positioned(
                top: headingTop,
                left: 28 * sx,
                right: 28 * sx,
                child: Text(
                  'Who’s ready\nto explore?',
                  key: const Key('profile-picker-heading'),
                  style: headingStyle,
                ),
              ),
              Positioned(
                top: heroTop,
                left: 0,
                right: 0,
                bottom: bottom + 38 * sy,
                child: PageView.builder(
                  key: const Key('profile-picker-carousel'),
                  controller: _pageController,
                  physics: _busy ? const NeverScrollableScrollPhysics() : null,
                  itemCount: widget.profiles.length,
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final index = widget.profiles.indexWhere(
                      (profile) => profile.id == key.value,
                    );
                    return index < 0 ? null : index;
                  },
                  onPageChanged: (page) {
                    if (page >= widget.profiles.length) return;
                    setState(() {
                      _page = page;
                      _visibleProfileId = widget.profiles[page].id;
                    });
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _revealIndicator();
                    });
                  },
                  itemBuilder: (context, index) {
                    final profile = widget.profiles[index];
                    return _ProfileCarouselPage(
                      key: ValueKey(profile.id),
                      profile: profile,
                      scaleX: sx,
                      scaleY: sy,
                      fontScale: fontScale,
                      extraHeading: extraHeading,
                      selecting: widget.selectingProfileId == profile.id,
                      onSelect: _busy
                          ? null
                          : () => widget.onSelectProfile(profile),
                    );
                  },
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: bottom + 6 * sy,
                child: Center(
                  child: SingleChildScrollView(
                    key: const Key('profile-picker-indicators'),
                    controller: _indicatorController,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (
                          var index = 0;
                          index < widget.profiles.length;
                          index++
                        )
                          Semantics(
                            button: true,
                            enabled: !_busy,
                            selected: _page == index,
                            label:
                                'Show ${widget.profiles[index].displayName}’s profile, ${index + 1} of ${widget.profiles.length}',
                            child: GestureDetector(
                              key: Key(
                                'profile-picker-dot-${widget.profiles[index].id}',
                              ),
                              onTap: _busy ? null : () => _showPage(index),
                              behavior: HitTestBehavior.opaque,
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                  child: AnimatedContainer(
                                    duration: media.disableAnimations
                                        ? Duration.zero
                                        : const Duration(milliseconds: 180),
                                    width: _page == index ? 22 : 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: _page == index
                                          ? _CharacterArtwork.forAvatar(
                                              widget.profiles[index].avatarKey,
                                            ).color
                                          : dark
                                          ? const Color(0xFF65716D)
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
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

ButtonStyle _quietIconStyle(Color color) => IconButton.styleFrom(
  foregroundColor: color,
  disabledForegroundColor: color,
  overlayColor: Colors.transparent,
  splashFactory: NoSplash.splashFactory,
  minimumSize: const Size(48, 48),
);

class _CharacterArtwork {
  const _CharacterArtwork({
    required this.avatarKey,
    required this.label,
    required this.color,
    this.asset,
    this.sourceSize,
    this.visibleBounds,
  });

  factory _CharacterArtwork.forAvatar(String avatarKey) {
    final option = kidAvatarOptionFor(avatarKey.trim().toLowerCase());
    return switch (option.key) {
      'lion' => const _CharacterArtwork(
        avatarKey: 'lion',
        label: 'Kai',
        color: Color(0xFF009F6C),
        asset: 'assets/images/mascot/mascot_wave.png',
        sourceSize: Size(1024, 1536),
        visibleBounds: Rect.fromLTRB(162, 99, 795, 1358),
      ),
      'dove' => const _CharacterArtwork(
        avatarKey: 'dove',
        label: 'Nia',
        color: Color(0xFF854AE4),
        asset: 'assets/images/characters/poses/nia-standing.png',
        sourceSize: Size(1023, 1537),
        visibleBounds: Rect.fromLTRB(263, 70, 805, 1432),
      ),
      'rainbow' => const _CharacterArtwork(
        avatarKey: 'rainbow',
        label: 'Zuri',
        color: Color(0xFFF84D68),
        asset: 'assets/images/characters/poses/zuri-standing.png',
        sourceSize: Size(1122, 1402),
        visibleBounds: Rect.fromLTRB(245, 50, 878, 1337),
      ),
      _ => _CharacterArtwork(
        avatarKey: option.key,
        label: option.label,
        color: option.color,
      ),
    };
  }

  final String avatarKey;
  final String label;
  final Color color;
  final String? asset;
  final Size? sourceSize;
  final Rect? visibleBounds;

  Color get nameColor => 1.05 / (color.computeLuminance() + 0.05) >= 3
      ? Colors.white
      : const Color(0xFF10241C);

  Color get subtitleColor => 1.05 / (color.computeLuminance() + 0.05) >= 4.5
      ? Colors.white
      : const Color(0xFF10241C);
}

class _ProfileCarouselPage extends StatelessWidget {
  const _ProfileCarouselPage({
    super.key,
    required this.profile,
    required this.scaleX,
    required this.scaleY,
    required this.fontScale,
    required this.extraHeading,
    required this.selecting,
    required this.onSelect,
  });

  final KidProfile profile;
  final double scaleX;
  final double scaleY;
  final double fontScale;
  final double extraHeading;
  final bool selecting;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final artwork = _CharacterArtwork.forAvatar(profile.avatarKey);
    final nameStyle = TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: 39 * fontScale,
      height: 1.14,
      letterSpacing: -1,
      fontWeight: FontWeight.w700,
      color: artwork.nameColor,
    );
    final subtitleStyle = TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: 15.5 * fontScale,
      height: 1.25,
      fontWeight: FontWeight.w600,
      color: artwork.subtitleColor,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardBottom = constraints.maxHeight - 18 * scaleY;
        final nameHeight = _textHeight(context, 'Ag', nameStyle, 220 * scaleX);
        final subtitleHeight = _textHeight(
          context,
          artwork.label,
          subtitleStyle,
          220 * scaleX,
        );
        final labelHeight = nameHeight + 4 * scaleY + subtitleHeight;
        final labelTop = cardBottom - 24 * scaleY - labelHeight;
        final characterTop = 33 * scaleY;
        final characterHeight = math.max(
          80.0,
          math.min(420 * scaleY, labelTop - 20 * scaleY - characterTop),
        );
        return GestureDetector(
          onTap: onSelect,
          child: Stack(
            children: [
              Positioned(
                left: 28 * scaleX,
                right: 28 * scaleX,
                top: 161 * scaleY - extraHeading * 0.35,
                bottom: 18 * scaleY,
                child: ClipPath(
                  clipper: _AngledCardClipper(drop: 64 * scaleY),
                  child: ColoredBox(color: artwork.color),
                ),
              ),
              if (artwork.asset != null) ...[
                Positioned(
                  left: constraints.maxWidth / 2 - 66 * scaleX,
                  top: characterTop + characterHeight - 5,
                  width: 132 * scaleX,
                  height: 15 * scaleY,
                  child: CustomPaint(painter: _GroundShadowPainter()),
                ),
                _OriginalCharacterImage(
                  profileId: profile.id,
                  artwork: artwork,
                  viewportWidth: constraints.maxWidth,
                  top: characterTop,
                  height: characterHeight,
                ),
              ] else
                Positioned(
                  top: characterTop,
                  left: 0,
                  right: 0,
                  height: characterHeight,
                  child: Center(
                    child: KidAvatarBadge(
                      avatarKey: artwork.avatarKey,
                      size: math.min(230 * scaleY, characterHeight),
                    ),
                  ),
                ),
              Positioned(
                left: 48 * scaleX,
                right: 118 * scaleX,
                top: labelTop,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName,
                      key: Key('profile-picker-display-name-${profile.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: nameStyle,
                    ),
                    SizedBox(height: 4 * scaleY),
                    Text(
                      artwork.label,
                      key: Key('profile-picker-character-name-${profile.id}'),
                      maxLines: 1,
                      style: subtitleStyle,
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 47 * scaleX,
                top: labelTop + (labelHeight - 56) / 2,
                child: IconButton.filled(
                  key: Key('profile-picker-select-${profile.id}'),
                  tooltip: 'Open ${profile.displayName}’s profile',
                  onPressed: onSelect,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF17221F),
                    disabledForegroundColor: const Color(0xFF17221F),
                    overlayColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    fixedSize: const Size(56, 56),
                  ),
                  icon: selecting
                      ? SizedBox.square(
                          dimension: 23,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.3,
                            color: artwork.color,
                          ),
                        )
                      : const Icon(Icons.arrow_forward_rounded, size: 30),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OriginalCharacterImage extends StatelessWidget {
  const _OriginalCharacterImage({
    required this.profileId,
    required this.artwork,
    required this.viewportWidth,
    required this.top,
    required this.height,
  });

  final String profileId;
  final _CharacterArtwork artwork;
  final double viewportWidth;
  final double top;
  final double height;

  @override
  Widget build(BuildContext context) {
    final bounds = artwork.visibleBounds!;
    final scale = height / bounds.height;
    final visibleLeft = (viewportWidth - bounds.width * scale) / 2;
    return Positioned(
      left: visibleLeft - bounds.left * scale,
      top: top - bounds.top * scale,
      width: artwork.sourceSize!.width * scale,
      height: artwork.sourceSize!.height * scale,
      child: Image.asset(
        artwork.asset!,
        key: Key('profile-picker-art-$profileId'),
        fit: BoxFit.fill,
        semanticLabel: '${artwork.label}, story character',
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => Center(
          child: KidAvatarBadge(avatarKey: artwork.avatarKey, size: 150),
        ),
      ),
    );
  }
}

double _textHeight(
  BuildContext context,
  String text,
  TextStyle style,
  double width,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 2,
  )..layout(maxWidth: width);
  final height = painter.height;
  painter.dispose();
  return height;
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
