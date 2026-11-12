"""Add the remaining illustrated matching games to the local review catalogue."""

from .install_matching_studio import Command as StudioCommand
from apps.games.matching_collection import (
    build_sheep_reunion_config, build_creation_bloom_config, build_esther_table_config)

DEFINITIONS = (
    {
        'slug': 'find-my-sheep', 'title': 'Find My Sheep',
        'subtitle': 'Little lambs. A happy home.',
        'description': 'Look closely at each lamb’s patterned scarf. Guide the lost lambs home to their matching families in a sunny meadow.',
        'mode': 'sheep_reunion', 'builder': build_sheep_reunion_config,
        'cover_asset_key': 'assets/images/stories/lost-sheep-storybook-v1.webp',
        'accent_color': '#6D8757', 'icon_key': 'pets', 'sort_order': 52,
        'estimated_duration_seconds': 90,
        'round_titles': ('Home in the meadow', 'Look a little closer', 'Happy families'),
        'instructions': 'Match each lamb’s scarf colour and pattern to its family.',
    },
    {
        'slug': 'creation-match-bloom', 'title': 'Creation: Match & Bloom',
        'subtitle': 'Find a home. Watch it grow.',
        'description': 'Help a little illustrated world come alive. Match birds to sky, fish to water and growing things to their garden homes.',
        'mode': 'creation_bloom', 'builder': build_creation_bloom_config,
        'cover_asset_key': 'assets/images/stories/creation-week-v2.webp',
        'accent_color': '#438878', 'icon_key': 'eco', 'sort_order': 53,
        'estimated_duration_seconds': 90,
        'round_titles': ('A little living world', 'Places to flourish', 'A garden of wonder'),
        'instructions': 'Find the right habitat for each living piece.',
    },
    {
        'slug': 'esthers-celebration-table', 'title': 'Esther’s Celebration Table',
        'subtitle': 'A place for everyone.',
        'description': 'Help Esther prepare a beautiful celebration. Look at each guest’s illustrated request and bring the matching dish to the table.',
        'mode': 'esther_table', 'builder': build_esther_table_config,
        'cover_asset_key': 'assets/images/stories/esther-speaks-up-v2.webp',
        'accent_color': '#A56B56', 'icon_key': 'celebration', 'sort_order': 54,
        'estimated_duration_seconds': 90,
        'round_titles': ('A warm welcome', 'A table to share', 'The celebration begins'),
        'instructions': 'Match each serving piece to its place at Esther’s table.',
    },
)


class Command(StudioCommand):
    help = 'Stage three more matching games locally while preserving history.'
    definitions = DEFINITIONS
