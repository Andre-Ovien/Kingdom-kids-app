import io
from pathlib import Path
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase

from .models import Game, GameLevel, KidGameProgress
from .test_ark_garden import ArkGardenApiTests

COURSE = Path(__file__).with_name('content') / 'ark_garden_curve_contract_v2.json'
BACKUP = 'apps.games.management.commands.install_ark_garden.backup_local_database'


class ArkGardenInstallerTests(TestCase):
    def setUp(self):
        ArkGardenApiTests.setUp(self)

    def test_install_is_idempotent_and_preserves_ids_progress_and_retired_matching(self):
        retired = Game.objects.get(slug='ark-animal-match')
        progress = KidGameProgress.objects.create(
            profile=self.profile, game=retired,
            highest_completed_level=1,
            level_progress={'1': {'completed': True, 'stars': 3, 'completion_xp': 50}},
        )
        before = (retired.is_published, progress.level_progress.copy(), self.game.pk, self.level.pk)
        output = io.StringIO()
        with patch(BACKUP, return_value=Path('/private/tmp/review-backup.sqlite3')) as backup:
            call_command('install_ark_garden', course=COURSE, publish=True, stdout=output)
            call_command('install_ark_garden', course=COURSE, publish=True, stdout=output)
            self.assertEqual(backup.call_count, 1)
        self.game.refresh_from_db()
        self.level.refresh_from_db()
        progress.refresh_from_db()
        retired.refresh_from_db()
        self.assertEqual(self.game.pk, before[2])
        self.assertEqual(self.level.pk, before[3])
        self.assertTrue(self.game.is_published)
        self.assertEqual(self.game.levels.count(), 1)
        self.assertEqual(self.level.config['garden']['version'], 2)
        self.assertEqual(progress.level_progress, before[1])
        self.assertEqual(retired.is_published, before[0])
        self.assertIn('no data changed', output.getvalue())

    def test_dry_run_makes_no_changes_or_backup(self):
        before = self.level.config.copy()
        with patch(BACKUP) as backup:
            call_command('install_ark_garden', course=COURSE, publish=True, dry_run=True, stdout=io.StringIO())
            backup.assert_not_called()
        self.level.refresh_from_db()
        self.game.refresh_from_db()
        self.assertEqual(self.level.config, before)
        self.assertFalse(self.game.is_published)

    def test_conflicting_multi_level_identity_is_rejected_without_deleting_history(self):
        GameLevel.objects.create(game=self.game, level_number=2, title='Existing history',
                                 instructions='Preserve this', config=self.level.config)
        with patch(BACKUP) as backup, self.assertRaises(CommandError):
            call_command('install_ark_garden', course=COURSE, publish=True, stdout=io.StringIO())
        backup.assert_not_called()
        self.assertEqual(self.game.levels.count(), 2)
