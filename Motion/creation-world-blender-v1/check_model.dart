import 'dart:convert';
import 'dart:io';
import '../../Frontend/mobile/lib/features/games/domain/creation_world_model.dart';

void main() {
  final levels =
      jsonDecode(
            File(
              'Motion/creation-world-blender-v1/world-levels.json',
            ).readAsStringSync(),
          )
          as Map;
  final examples =
      jsonDecode(File('Motion/creation-world-blender-v1/world-examples.json').readAsStringSync())
          as Map;
  for (final level in ['1', '2', '3']) {
    final world = CreationWorldModel.fromConfig(
      Map<String, dynamic>.from(levels[level] as Map),
    );
    for (final command in (examples[level] as Map)['commands'] as List) {
      final ok = command['op'] == 'advance'
          ? world.advanceDay()
          : world.place(command['piece_id'] as String, command['cell'] as int);
      if (!ok) throw StateError('Creation day replay diverged: $command');
    }
    if (!world.complete)
      throw StateError('Creation round $level did not complete.');
    stdout.writeln(
      'Creation round $level: Dart replay completed; ${world.commands.length} commands.',
    );
  }
}
