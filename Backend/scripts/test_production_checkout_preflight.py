"""Synthetic offline report tests; no private inputs or runtime services."""
import json
from unittest import TestCase
from unittest.mock import patch

from Backend.scripts import production_checkout_preflight as preflight
from Backend.scripts.test_render_start import environment, production_environment, controlled_production_environment, hosted_production_environment


class ProductionPreflightTests(TestCase):
    def test_hosted_profile_is_noncharging_without_app_scheduler_or_paid_hosting_requirement(self):
        values, output = hosted_production_environment(), []
        original = dict(values)
        self.assertEqual(preflight.main(values, output.append), 0)
        report = json.loads(output[0]); self.assertEqual(values, original)
        self.assertEqual(report['profile'], 'provider_hosted_production')
        self.assertEqual(report['renewal_controller'], 'square_hosted_subscriptions')
        for name in ('public_release_ready', 'activation_performed', 'scheduled_jobs_claimed'): self.assertFalse(report[name])
        self.assertIsNone(report['automatic_renewals_enabled'])
        self.assertEqual((report['database_operations'], report['provider_operations'], report['environment_mutations']), (0, 0, 0))
        self.assertNotIn('qualified_non_sleeping_hosting', report['runtime_qualification_required'])
        self.assertNotIn('scheduled_reconciliation_and_renewal_heartbeats', report['runtime_qualification_required'])
        self.assertIn('owned_canonical_reconciliation_and_cancellation', report['runtime_qualification_required'])
        self.assertNotIn(values['SQUARE_PRODUCTION_ACCESS_TOKEN'], output[0])
        values['SQUARE_PRODUCTION_RENEWALS_ENABLED'] = 'true'
        self.assertEqual(preflight.main(values, lambda _: None), 2)

    def test_controlled_profile_is_noncharging_nonrenewing_and_not_public_release(self):
        values, output = controlled_production_environment(), []
        original = dict(values)
        self.assertEqual(preflight.main(values, output.append), 0)
        report = json.loads(output[0])
        self.assertEqual(values, original)
        self.assertEqual(report['profile'], 'controlled_production')
        self.assertTrue(report['local_configuration_valid'])
        for name in ('public_release_ready', 'activation_performed', 'automatic_renewals_enabled', 'scheduled_jobs_claimed'):
            self.assertFalse(report[name])
        self.assertEqual((report['database_operations'], report['provider_operations'], report['environment_mutations']), (0, 0, 0))
        self.assertNotIn('qualified_non_sleeping_hosting', report['runtime_qualification_required'])
        self.assertNotIn('scheduled_reconciliation_and_renewal_heartbeats', report['runtime_qualification_required'])
        self.assertNotIn(values['SQUARE_PRODUCTION_ACCESS_TOKEN'], output[0])
        self.assertNotIn(values['SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS'], output[0])
        self.assertEqual(report['custom_domain_dns_ca_proof'], 'not_selected')
        values['SQUARE_PRODUCTION_RENEWALS_ENABLED'] = 'true'
        self.assertEqual(preflight.main(values, lambda _: None), 2)
        values = controlled_production_environment(); values['RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED'] = 'TRUE'
        self.assertEqual(preflight.main(values, lambda _: None), 2)

    def test_disabled_draft_is_nonzero_and_never_reads_credentials_from_files(self):
        values = environment()
        values['SQUARE_PRODUCTION_ACCESS_TOKEN'] = 'synthetic-token-not-activation'
        original, output = dict(values), []
        with patch.object(preflight.production_preflight_report.__globals__['os'], 'open',
                side_effect=AssertionError('No file reads for an unqualified draft')):
            self.assertEqual(preflight.main(values, output.append), 2)
        report = json.loads(output[0])
        self.assertEqual(values, original)
        self.assertEqual(report['status'], 'disabled_draft')
        self.assertFalse(report['local_configuration_valid'])
        self.assertFalse(report['public_release_ready'])
        self.assertNotIn(values['SQUARE_PRODUCTION_ACCESS_TOKEN'], output[0])

    def test_passing_local_contract_is_not_deployment_or_activation_proof(self):
        values, output = production_environment(), []
        original = dict(values)
        self.assertEqual(preflight.main(values, output.append), 0)
        report = json.loads(output[0])
        self.assertEqual(values, original)
        self.assertTrue(report['local_configuration_valid'])
        self.assertFalse(report['public_release_ready'])
        self.assertFalse(report['activation_performed'])
        self.assertEqual((report['database_operations'], report['provider_operations'], report['environment_mutations']), (0, 0, 0))
        self.assertIn('scheduled_reconciliation_and_renewal_heartbeats', report['runtime_qualification_required'])
        self.assertIn('original_django_production_checks', report['runtime_qualification_required'])
