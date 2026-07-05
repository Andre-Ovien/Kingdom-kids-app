import 'package:flutter/material.dart';

import '../../../core/widgets/feature_placeholder_screen.dart';

class BibleScreen extends StatelessWidget {
  const BibleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholderScreen(
      title: 'Bible',
      icon: Icons.menu_book,
      accentColor: Color(0xFF2F80C5),
    );
  }
}
