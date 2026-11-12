"""Typed DisableCard response/uncertainty proofs; only mocked transport."""
import json
from unittest.mock import Mock
from django.test import SimpleTestCase,override_settings
from .client import SquareSandboxClient,SquareHttpResult,SquareClientError
from .test_checkout import CHECKOUT_CONFIG

@override_settings(**CHECKOUT_CONFIG)
class DisableCardTests(SimpleTestCase):
    def card(self,enabled,**overrides):
        return SquareHttpResult(200,json.dumps({'card':{'id':'ccof:owned','enabled':enabled,
            'customer_id':'customer-test','merchant_id':'merchant-test',**overrides}}).encode())
    def run_disable(self,results):
        transport=Mock();transport.send.side_effect=results;client=SquareSandboxClient(transport)
        return client,transport
    def test_successful_empty_disable_requires_fresh_canonical_false_and_no_repeat(self):
        client,transport=self.run_disable([self.card(True),SquareHttpResult(200,b''),self.card(False)])
        self.assertEqual(client.disable_card('ccof:owned',customer_id='customer-test'),{'id':'ccof:owned','enabled':False})
        self.assertEqual([call.kwargs['method'] for call in transport.send.call_args_list],['GET','POST','GET'])
        self.assertTrue(transport.send.call_args_list[1].kwargs['url'].endswith('/v2/cards/ccof%3Aowned/disable'))
        self.assertEqual(transport.send.call_args_list[1].kwargs['body'],b'{}')
    def test_lost_post_response_can_be_resolved_only_by_get_no_second_post(self):
        client,transport=self.run_disable([self.card(True),TimeoutError('Synthetic secret'),self.card(False)])
        self.assertFalse(client.disable_card('ccof:owned',customer_id='customer-test')['enabled'])
        self.assertEqual(sum(c.kwargs['method']=='POST' for c in transport.send.call_args_list),1)
    def test_empty_success_without_canonical_disabled_is_not_success(self):
        client,transport=self.run_disable([self.card(True),SquareHttpResult(200,b''),self.card(True)])
        with self.assertRaises(SquareClientError):client.disable_card('ccof:owned',customer_id='customer-test')
        self.assertEqual(sum(c.kwargs['method']=='POST' for c in transport.send.call_args_list),1)
    def test_already_disabled_or_foreign_owner_never_posts(self):
        for changes in [{},{'customer_id':'foreign-parent'},{'merchant_id':'foreign-merchant'},{'enabled':'false'}]:
            enabled=changes.pop('enabled',False);client,transport=self.run_disable([self.card(enabled,**changes)])
            if changes or type(enabled) is not bool:
                with self.assertRaises(SquareClientError):client.disable_card('ccof:owned',customer_id='customer-test')
            else:self.assertFalse(client.disable_card('ccof:owned',customer_id='customer-test')['enabled'])
            self.assertEqual([c.kwargs['method'] for c in transport.send.call_args_list],['GET'])
    def test_generic_json_parser_remains_strict_on_empty_success(self):
        client,_transport=self.run_disable([SquareHttpResult(200,b'')])
        with self.assertRaises(SquareClientError):client.request('POST','/v2/payments',{})
    def test_invalid_or_error_disable_body_still_requires_get_proof_not_payload_trust(self):
        for body in [b'not-json',b'{"errors":[{"detail":"private-synthetic-marker"}]}',b'{"card":{"enabled":false}}']:
            client,transport=self.run_disable([self.card(True),SquareHttpResult(200,body),self.card(True)])
            with self.assertRaises(SquareClientError) as error:client.disable_card('ccof:owned',customer_id='customer-test')
            self.assertNotIn('private-synthetic-marker',str(error.exception))
            self.assertEqual(sum(c.kwargs['method']=='POST' for c in transport.send.call_args_list),1)
