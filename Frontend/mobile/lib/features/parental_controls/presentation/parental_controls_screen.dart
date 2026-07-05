import 'package:flutter/material.dart';

import '../../../app/theme_controller.dart';
import '../../../shared/widgets/liquid_glass.dart';

class ParentalControlsScreen extends StatelessWidget {
  const ParentalControlsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 34),
              sliver: SliverList.list(
                children: const [
                  _SettingsTopBar(),
                  SizedBox(height: 26),
                  _SettingsHero(),
                  SizedBox(height: 26),
                  _SettingsGroup(
                    title: 'Display',
                    children: [
                      _DarkModeTile(),
                      _SettingsSwitchTile(
                        icon: Icons.bedtime_rounded,
                        title: 'Bedtime glow',
                        subtitle: 'Soften bright screens after evening stories',
                        value: true,
                      ),
                    ],
                  ),
                  SizedBox(height: 22),
                  _SettingsGroup(
                    title: 'Reading',
                    children: [
                      _SettingsTile(
                        icon: Icons.text_fields_rounded,
                        title: 'Story text size',
                        subtitle: 'Comfortable',
                        trailing: Icons.chevron_right_rounded,
                      ),
                      _SettingsSwitchTile(
                        icon: Icons.volume_up_rounded,
                        title: 'Narration audio',
                        subtitle: 'Play gentle read-aloud voices',
                        value: true,
                      ),
                      _SettingsSwitchTile(
                        icon: Icons.play_circle_rounded,
                        title: 'Auto-play videos',
                        subtitle: 'Continue to the next Bible video',
                      ),
                    ],
                  ),
                  SizedBox(height: 22),
                  _SettingsGroup(
                    title: 'Parent & Safety',
                    children: [
                      _SettingsTile(
                        icon: Icons.lock_rounded,
                        title: 'Parent gate',
                        subtitle: 'Require help before purchases or links',
                        trailing: Icons.chevron_right_rounded,
                      ),
                      _SettingsTile(
                        icon: Icons.notifications_rounded,
                        title: 'Notifications',
                        subtitle: 'Daily story reminders',
                        trailing: Icons.chevron_right_rounded,
                      ),
                      _SettingsTile(
                        icon: Icons.download_rounded,
                        title: 'Offline stories',
                        subtitle: 'Manage downloaded stories and videos',
                        trailing: Icons.chevron_right_rounded,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTopBar extends StatelessWidget {
  const _SettingsTopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        LiquidGlass(
          borderRadius: 28,
          opacity: 0.02,
          blur: 28,
          borderOpacity: 0.4,
          child: SizedBox.square(
            dimension: 52,
            child: IconButton(
              padding: EdgeInsets.zero,
              color: _primaryText(context),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 22),
            ),
          ),
        ),
        Expanded(
          child: Text(
            'Settings',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _primaryText(context),
              fontSize: 22,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ),
        const SizedBox(width: 52),
      ],
    );
  }
}

class _SettingsHero extends StatelessWidget {
  const _SettingsHero();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 78,
          height: 78,
          padding: const EdgeInsets.all(7),
          decoration: const BoxDecoration(
            color: Color(0xFFFFD8DF),
            shape: BoxShape.circle,
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/profile_avatar.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 13),
        Text(
          'Ethan',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: _primaryText(context),
            fontSize: 24,
            fontWeight: FontWeight.w500,
            height: 1.1,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Reader profile and app preferences',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: _mutedText(context),
            fontSize: 13,
            fontWeight: FontWeight.w400,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: _primaryText(context),
            fontSize: 17,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 12),
        LiquidGlass(
          borderRadius: 24,
          opacity: _isDark(context) ? 0.05 : 0.34,
          blur: 24,
          borderOpacity: _isDark(context) ? 0.18 : 0.46,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _DarkModeTile extends StatelessWidget {
  const _DarkModeTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppThemeController.mode,
      builder: (context, mode, _) {
        return _SettingsSwitchTile(
          icon: Icons.dark_mode_rounded,
          title: 'Dark mode',
          subtitle: 'Use a softer nighttime look across the app',
          value: mode == ThemeMode.dark,
          onChanged: AppThemeController.setDarkMode,
        );
      },
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    return _SettingsRowShell(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: trailing == null
          ? null
          : Icon(trailing, color: _mutedText(context), size: 24),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.value = false,
    this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingsRowShell(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch.adaptive(
        value: value,
        activeThumbColor: const Color(0xFFFF7043),
        activeTrackColor: const Color(0xFFFFB39B),
        onChanged: onChanged ?? (_) {},
      ),
    );
  }
}

class _SettingsRowShell extends StatelessWidget {
  const _SettingsRowShell({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          _SettingIcon(icon: icon),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _primaryText(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _mutedText(context),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

class _SettingIcon extends StatelessWidget {
  const _SettingIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: _isDark(context)
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFFFEEE8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: const Color(0xFFFF7043), size: 21),
    );
  }
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _primaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _mutedText(BuildContext context) {
  return _isDark(context) ? const Color(0xFF9BA7A5) : const Color(0xFF9D9090);
}
