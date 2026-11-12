import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/creation_world_engine.dart';
import 'package:mobile/features/games/presentation/creation_world_graphics.dart';
import 'package:mobile/features/games/presentation/wise_builders_engine.dart';

const record = bool.fromEnvironment('RUN_LIVING_WORLD_VISUAL_REVIEW');
bool fontsLoaded = false;

GameLevel level(int number, Map<String, dynamic> config) => GameLevel(
  id: 'native-living-$number',
  number: number,
  title: 'Living world',
  instructions: 'Build and explore.',
  config: config,
  maxScore: 100,
);

void main() {
  for (final number in [1, 2, 3]) {
    testWidgets(
      'record Creation round $number first and completed native states',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await loadFonts(tester);
        final configs =
            jsonDecode(
                  File(
                    'test/fixtures/creation_world_levels.json',
                  ).readAsStringSync(),
                )
                as Map;
        final config = Map<String, dynamic>.from(configs['$number'] as Map);
        final examples =
            jsonDecode(
                  File(
                    '../../Motion/creation-world-blender-v1/world-examples.json',
                  ).readAsStringSync(),
                )
                as Map;
        final commands = (examples['$number'] as Map)['commands'] as List;
        final art = await tester.runAsync(
          () => CreationWorldGraphics.load(number, bundle: FileBundle()),
        );
        final boundary = GlobalKey();
        Map<String, dynamic>? submitted;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildKingdomKidsTheme(),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: CreationWorldEngine(
                  level: level(number, config),
                  graphicsLoader: (_) => Future.value(art!),
                  onComplete: (r) => submitted = r,
                  onExit: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final directory = Directory(
          '../../Motion/creation-world-blender-v1/review/native',
        );
        await tester.runAsync(() => directory.create(recursive: true));
        await capture(
          tester,
          boundary,
          '${directory.path}/round-$number-first.png',
        );
        final pieces = {
          for (final raw in (config['world'] as Map)['pieces'] as List)
            (raw as Map)['id']: raw,
        };
        for (final raw in commands) {
          final command = Map<String, dynamic>.from(raw as Map);
          if (command['op'] == 'advance') {
            final day = command['day'] as int;
            final button = find.widgetWithText(
              FilledButton,
              day == 7 ? 'Rest and enjoy your world' : 'Finish day $day',
            );
            expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
            await tester.tap(button);
            await tester.pump();
          } else {
            final kind = (pieces[command['piece_id']] as Map)['kind'] as String;
            final piece = find.text(kind).first;
            await tester.ensureVisible(piece);
            await tester.tap(piece);
            await tester.pump();
            final cell = command['cell'] as int;
            const width = 390 * .88,
                height = width * .90,
                left = 390 * .06,
                top = 844 * .28;
            final point = Offset(
              left + (cell % 5 + .5) * width / 5,
              top + (cell ~/ 5 + .5) * height / 4,
            );
            await tester.tapAt(point);
            await tester.pump();
          }
        }
        expect(find.text('Your living world'), findsOneWidget);
        await capture(
          tester,
          boundary,
          '${directory.path}/round-$number-completed.png',
        );
        if (number == 3) {
          final frames = Directory('${directory.path}/creature-frames');
          await tester.runAsync(() => frames.create(recursive: true));
          for (var frame = 0; frame < 48; frame++) {
            await tester.pump(const Duration(milliseconds: 83));
            await capture(
              tester,
              boundary,
              '${frames.path}/frame-${frame.toString().padLeft(3, '0')}.png',
              pixelRatio: 1,
            );
          }
        }
        await tester.tap(find.widgetWithText(FilledButton, 'Save my world'));
        await tester.pump();
        expect(submitted?['commands'], commands);
        expect(
          submitted!.keys,
          unorderedEquals(['commands', 'elapsed_seconds']),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      skip: !record,
    );
    testWidgets(
      'record Builders round $number first and storm-completed native states',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await loadFonts(tester);
        final configs =
            jsonDecode(
                  File(
                    '../../Motion/wise-builders-blender-v1/builders-levels.json',
                  ).readAsStringSync(),
                )
                as Map;
        final config = Map<String, dynamic>.from(configs['$number'] as Map);
        final parts = List<String>.from(
          (config['builders'] as Map)['parts'] as List,
        );
        final storm = (config['builders'] as Map)['storm'] as String;
        final art = await tester.runAsync(() => loadBuilders(parts, storm));
        final boundary = GlobalKey();
        Map<String, dynamic>? submitted;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildKingdomKidsTheme(),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: WiseBuildersEngine(
                  level: level(number, config),
                  graphicsLoader: () => Future.value(art!),
                  onComplete: (r) => submitted = r,
                  onExit: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final directory = Directory(
          '../../Motion/wise-builders-blender-v1/review/native',
        );
        await tester.runAsync(() => directory.create(recursive: true));
        await capture(
          tester,
          boundary,
          '${directory.path}/round-$number-first.png',
        );
        for (var house = 0; house < 2; house++) {
          await tester.tap(
            find.widgetWithText(
              ChoiceChip,
              house == 0 ? 'Little house' : 'Garden house',
            ),
          );
          await tester.pump();
          await tester.tap(
            find.widgetWithText(
              ActionChip,
              house == 0 ? 'Rock foundation' : 'Sand foundation',
            ),
          );
          await tester.pump();
          for (final part in parts) {
            final piece = find.text(part.replaceAll('-', ' '));
            await tester.ensureVisible(piece);
            await tester.tap(piece);
            await tester.pump();
            await tester.tapAt(Offset(house == 0 ? 99 : 290, 360));
            await tester.pump();
          }
        }
        final button = find.widgetWithText(FilledButton, 'Test the storm');
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        await tester.tap(button);
        await tester.pump();
        if (number == 3) {
          final frames = Directory('${directory.path}/storm-frames');
          await tester.runAsync(() => frames.create(recursive: true));
          for (var frame = 0; frame < 72; frame++) {
            await tester.pump(const Duration(milliseconds: 83));
            await capture(
              tester,
              boundary,
              '${frames.path}/frame-${frame.toString().padLeft(3, '0')}.png',
              pixelRatio: 1,
            );
          }
          await tester.pump(const Duration(milliseconds: 200));
        } else {
          await tester.pump(const Duration(seconds: 7));
        }
        await capture(
          tester,
          boundary,
          '${directory.path}/round-$number-completed.png',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Finish discovery'));
        await tester.pump();
        expect((submitted!['commands'] as List).last, {'op': 'storm'});
        expect(
          submitted!.keys,
          unorderedEquals(['commands', 'elapsed_seconds']),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      skip: !record,
    );
  }
}

Future<void> loadFonts(WidgetTester tester) async {
  if (fontsLoaded) return;
  await tester.runAsync(() async {
    for (final family in ['Avenir Next', 'Roboto', 'Ahem', 'sans-serif']) {
      final font = FontLoader(family)
        ..addFont(
          File(
            '/System/Library/Fonts/Avenir Next.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await font.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  fontsLoaded = true;
}

Future<void> capture(
  WidgetTester tester,
  GlobalKey key,
  String path, {
  double pixelRatio = 2,
}) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(path).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

Future<Map<String, ui.Image>> loadBuilders(
  List<String> parts,
  String storm,
) async {
  final art = <String, ui.Image>{};
  for (final name in [
    'background',
    'rock',
    'sand',
    ...parts,
    'standing',
    'collapse',
    'storm',
  ]) {
    final filename = name == 'storm' ? 'storm-$storm' : name;
    final bytes = await File(
      'assets/images/games/wise_builders/$filename.png',
    ).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    art[name] = (await codec.getNextFrame()).image;
    codec.dispose();
  }
  return art;
}

class FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}
