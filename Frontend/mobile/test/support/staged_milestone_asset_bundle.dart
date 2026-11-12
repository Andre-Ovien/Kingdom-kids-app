import 'dart:io';

import 'package:flutter/services.dart';

/// Reads rejected review artwork from disk without bundling it in the app.
/// Fonts and other normal app assets still come from Flutter's root bundle.
class StagedMilestoneAssetBundle extends CachingAssetBundle {
  static const _prefix = 'assets/images/milestones/';
  final Directory _directory = Directory(_prefix).absolute;

  @override
  Future<ByteData> load(String key) async {
    if (!key.startsWith(_prefix)) return rootBundle.load(key);
    final bytes = await File(
      '${_directory.path}/${key.substring(_prefix.length)}',
    ).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}
