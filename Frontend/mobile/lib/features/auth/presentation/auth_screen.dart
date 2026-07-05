import 'package:flutter/material.dart';

import '../../../core/widgets/feature_placeholder_screen.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholderScreen(
      title: 'Sign In',
      icon: Icons.lock,
      accentColor: Color(0xFF2D7D6F),
    );
  }
}
