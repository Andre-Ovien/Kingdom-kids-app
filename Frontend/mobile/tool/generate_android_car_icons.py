"""Generate Android icons and inspect masks using the approved square artwork.

Requires Pillow and the existing Dart/flutter_launcher_icons installation.
This only resizes and applies launcher masks; it never changes the artwork.
Run from any directory, with an optional --preview-directory output path.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont


MOBILE = Path(__file__).resolve().parent.parent
SOURCE = MOBILE / "assets/images/branding/kingdom-kids-car-icon-v1.png"
RESOURCES = MOBILE / "android/app/src/main/res"
IOS_ICONS = MOBILE / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
BACKGROUND = "#72C8EE"


def hashes(directory: Path) -> dict[str, str]:
    return {
        str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in directory.rglob("*")
        if path.is_file()
    }


def mask(size: int, shape: str) -> Image.Image:
    # Supersampling keeps the round legacy edges smooth at low densities.
    scale = 4
    large = size * scale
    result = Image.new("L", (large, large), 0)
    if shape == "circle":
        ImageDraw.Draw(result).ellipse((0, 0, large - 1, large - 1), fill=255)
    else:
        # A squircle approximation for review, not an OS screenshot.
        power = 5.0
        pixels = result.load()
        for y in range(large):
            dy = abs((y + 0.5 - large / 2) / (large / 2)) ** power
            for x in range(large):
                dx = abs((x + 0.5 - large / 2) / (large / 2)) ** power
                if dx + dy <= 1:
                    pixels[x, y] = 255
    return result.resize((size, size), Image.Resampling.LANCZOS)


def masked(image: Image.Image, shape: str) -> Image.Image:
    result = image.convert("RGBA")
    result.putalpha(mask(image.width, shape))
    return result


def adaptive_view(source: Image.Image, size: int) -> Image.Image:
    # Android's adaptive layer is 108 dp with a 72 dp visible viewport.
    # Applying 16% inset produces a 73.44 dp image: it fills the viewport
    # while retaining the faces and car within either launcher mask.
    layer_size = round(size * 108 / 72)
    foreground_size = round(layer_size * (1 - 2 * 0.16))
    layer = Image.new("RGB", (layer_size, layer_size), BACKGROUND)
    foreground = source.resize(
        (foreground_size, foreground_size), Image.Resampling.LANCZOS
    )
    offset = (layer_size - foreground_size) // 2
    layer.paste(foreground, (offset, offset))
    viewport = (layer_size - size) // 2
    return layer.crop((viewport, viewport, viewport + size, viewport + size))


def font(size: int) -> ImageFont.ImageFont:
    path = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    if path.is_file():
        return ImageFont.truetype(str(path), size)
    return ImageFont.load_default(size=size)


def preview(source: Image.Image, directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    canvas = Image.new("RGB", (1100, 600), "#F2F6FA")
    draw = ImageDraw.Draw(canvas)
    draw.text((40, 24), "Kingdom Kids — same car artwork on both platforms", font=font(26), fill="#172B45")
    draw.text((40, 65), "Launcher mask previews; artwork scaled proportionally", font=font(17), fill="#526478")
    columns = [("iPhone squircle", False, "squircle"),
               ("Android circle", True, "circle"),
               ("Android squircle", True, "squircle")]
    for index, (label, is_adaptive, shape) in enumerate(columns):
        center = 195 + index * 355
        large_source = adaptive_view(source, 270) if is_adaptive else source.resize((270, 270), Image.Resampling.LANCZOS)
        icon = masked(large_source, shape)
        canvas.paste(icon, (center - 135, 130), icon)
        draw.text((center - draw.textlength(label, font=font(21)) / 2, 420), label, font=font(21), fill="#172B45")
        small_source = adaptive_view(source, 60) if is_adaptive else source.resize((60, 60), Image.Resampling.LANCZOS)
        small = masked(small_source, shape)
        canvas.paste(small, (center - 30, 470), small)
        draw.text((center - 50, 545), "60 px preview", font=font(16), fill="#526478")
    path = directory / "icon-mask-review.png"
    canvas.save(path)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview-directory", type=Path, default=MOBILE.parent.parent / "Motion/icon-review-20261010")
    args = parser.parse_args()
    source = Image.open(SOURCE).convert("RGB")
    if source.width != source.height:
        raise SystemExit("Icon source must already be square; refusing to stretch or crop it.")
    ios_before = hashes(IOS_ICONS)
    subprocess.run(
        ["dart", "run", "flutter_launcher_icons", "--file", "tool/flutter_launcher_icons_android.yaml"],
        cwd=MOBILE, check=True,
    )
    checks = []
    for density, size in DENSITIES.items():
        standard = RESOURCES / f"mipmap-{density}/ic_launcher.png"
        round_path = standard.with_name("ic_launcher_round.png")
        # Reuse the generated square bitmap so the round variant has identical
        # proportions and content, with only a circle-shaped alpha mask.
        with Image.open(standard) as square:
            assert square.size == (size, size)
            masked(square, "circle").save(round_path)
        foreground_path = RESOURCES / f"drawable-{density}/ic_launcher_foreground.png"
        with Image.open(foreground_path) as foreground:
            expected = round(size * 108 / 48)
            assert foreground.size == (expected, expected), (density, foreground.size)
        (RESOURCES / f"drawable-{density}/ic_launcher_monochrome.png").unlink(missing_ok=True)
        checks.append({"density": density, "legacy": [size, size], "adaptive": [expected, expected], "round": [size, size]})
    adaptive_xml = RESOURCES / "mipmap-anydpi-v26/ic_launcher.xml"
    adaptive_contents = adaptive_xml.read_text()
    assert "ic_launcher_monochrome" not in adaptive_contents
    assert 'android:inset="16%"' in adaptive_contents
    adaptive_xml.with_name("ic_launcher_round.xml").write_text(adaptive_contents)
    assert hashes(IOS_ICONS) == ios_before, "Android generation changed iOS icons"
    preview_path = preview(source, args.preview_directory)
    report = {"source": str(SOURCE), "source_dimensions": source.size,
              "aspect_ratio_preserved": True, "ios_unchanged": True,
              "adaptive_inset_percent": 16, "obsolete_monochrome_removed": True,
              "resources": checks, "preview": str(preview_path)}
    report_path = args.preview_directory / "android-icon-validation.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"preview": str(preview_path), "validation": str(report_path), "ios_unchanged": True}))


if __name__ == "__main__":
    main()
