import 'dart:convert';
import 'dart:io';
import '../../Frontend/mobile/lib/features/games/domain/wise_builders_model.dart';

void main() {
  final levels = jsonDecode(File('Motion/wise-builders-blender-v1/builders-levels.json').readAsStringSync()) as Map;
  final examples = jsonDecode(File('Motion/wise-builders-blender-v1/builders-examples.json').readAsStringSync()) as Map;
  for (final level in ['1', '2', '3']) {
    final world = WiseBuildersModel.fromConfig(Map<String, dynamic>.from(levels[level] as Map));
    for (final c in (examples[level] as Map)['commands'] as List) {
      final ok = switch(c['op']) {
        'foundation' => world.foundation(c['house_id'] as String, c['material'] as String),
        'place' => world.place(c['house_id'] as String, c['part'] as String),
        'storm' => world.testStorm(), _ => false,
      };
      if (!ok) throw StateError('Builders command replay diverged: $c');
    }
    if (!world.complete) throw StateError('Builders round $level did not complete.');
    stdout.writeln('Builders round $level: Dart replay completed; ${world.commands.length} commands.');
  }
}
