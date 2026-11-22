"""Check semantic cleanup proposals and the duplicate-group retention boundary."""
import unittest
import argparse
import tempfile
from unittest.mock import patch
from pathlib import Path

from agent_loop import run_agent
from album_core import BASE, SEMANTIC_GUIDANCE
from album_core import model_advice, write_json
from album_agent import record_review
import semantic_preferences as semantic


class Planner:
    def __init__(self, ids):
        self.ids = ids
        self.calls = 0

    def next_action(self, request):
        assert SEMANTIC_GUIDANCE in request['instruction']
        self.calls += 1
        if self.calls == 1:
            return {'tool': 'inspect_group', 'arguments': {'group_id': 'g'}}
        return {'tool': 'propose_review', 'arguments': {
            'group_id': 'g', 'keep_ids': self.ids, 'reason': 'Accidental shot with no useful subject.'}}


class SemanticReviewTest(unittest.TestCase):
    def run_proposal(self, kind, ids):
        photo = dict(id='p', path='p.jpg', sha='sha', sharp=1, bright=100, resolution=100, text='')
        group = {'id': 'g', 'kind': kind, 'photos': [photo]}
        return run_agent('Review content value', [group], Path('.'), BASE, {}, Planner(ids),
                         ask_user=lambda _: self.fail('No question expected'))

    def test_single_low_value_photo_can_be_proposed_for_cleanup(self):
        proposal = self.run_proposal('single', [])
        self.assertEqual(proposal.keep_ids, set())
        self.assertEqual(proposal.trace[-1]['tool'], 'propose_review')

    def test_screenshot_can_be_proposed_for_cleanup(self):
        self.assertEqual(self.run_proposal('screenshot', []).keep_ids, set())

    def test_duplicate_group_must_retain_a_representative(self):
        for kind in ('copy', 'burst', 'similar'):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.run_proposal(kind, [])

    def test_foreign_photo_id_is_rejected(self):
        with self.assertRaises(ValueError):
            self.run_proposal('single', ['outside-task'])


class PreferenceLearningTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.photo = dict(id='p', path='p.jpg', sha='sha', sharp=1, bright=100, resolution=100, text='')
        self.group = {'id': 'g', 'kind': 'single', 'photos': [self.photo]}
        self.rule = {'category': '频谱图', 'condition': '没有上下文的独立频谱截图',
                     'exceptions': '有明确用途说明或标记重要的记录', 'photo_ids': ['p']}
        self.review = {'group': self.group, 'split': 'feedback', 'keep': [], 'uncertain': []}

    def test_skip_does_not_learn_and_confirmation_persists_across_reload(self):
        semantic.confirm(self.state, self.rule, self.review, ask=lambda _: '')
        self.assertFalse((self.state / 'semantic-rules.json').exists())
        semantic.confirm(self.state, self.rule, self.review, ask=lambda _: 'yes')
        rules = semantic.active_rules(self.state)
        self.assertEqual(rules[0]['action'], 'cleanup')
        self.assertEqual(rules[0]['source']['examples'][0]['sha256'], 'sha')
        self.assertIn('频谱图', semantic.prompt(rules))
        semantic.confirm(self.state, self.rule, self.review,
                         ask=lambda _: self.fail('An identical learned preference must not ask again.'))
        self.assertEqual(len(semantic.store(self.state)['versions']), 2)

    def test_generic_sop_is_present_without_any_category_defaults(self):
        instruction = semantic.prompt([])
        self.assertIn(semantic.FEEDBACK_SOP, instruction)
        self.assertEqual(semantic.active_rules(self.state), [])
        self.assertNotIn('频谱图', instruction)
        self.assertNotIn('二维码', instruction)

    def test_rollback_and_later_owner_correction(self):
        semantic.remember(self.state, self.rule, self.review)
        self.review['keep'] = ['p']
        semantic.remember(self.state, self.rule, self.review)
        self.assertEqual(len(semantic.active_rules(self.state)), 1)
        self.assertEqual(semantic.active_rules(self.state)[0]['action'], 'keep')
        semantic.rollback(self.state)
        self.assertEqual(semantic.active_rules(self.state)[0]['action'], 'cleanup')
        semantic.rollback(self.state)
        self.assertEqual(semantic.active_rules(self.state), [])

    def test_blind_evaluation_and_uncertain_examples_do_not_teach(self):
        self.review['split'] = 'test'
        with self.assertRaises(ValueError):
            semantic.remember(self.state, self.rule, self.review)
        self.review.update(split='feedback', uncertain=['p'])
        with self.assertRaises(ValueError):
            semantic.remember(self.state, self.rule, self.review)
        self.assertEqual(semantic.active_rules(self.state), [])

    def test_foreign_examples_and_mixed_labels_are_rejected(self):
        with self.assertRaises(ValueError):
            semantic.validate_rule(self.rule | {'photo_ids': ['outside']}, {'p'})
        extra = self.photo | {'id': 'p2', 'sha': 'sha2'}
        self.group['photos'].append(extra)
        self.review['keep'] = ['p']
        with self.assertRaises(ValueError):
            semantic.remember(self.state, self.rule | {'photo_ids': ['p', 'p2']}, self.review)

    def test_full_agent_feedback_then_future_agent_receives_learned_prompt(self):
        owner_test = self

        class SuggestingPlanner(Planner):
            def next_action(self, request):
                action = super().next_action(request)
                if action['tool'] == 'propose_review':
                    action['arguments']['semantic_rule'] = owner_test.rule
                return action

        proposal = run_agent('review', [self.group], self.state, BASE, {}, SuggestingPlanner([]),
                             ask_user=lambda _: '')
        self.assertFalse((self.state / 'semantic-rules.json').exists())
        write_json(self.state / 'scan.json', {'groups': [self.group]})
        args = argparse.Namespace(group='g', keep='none', uncertain='', split='feedback',
                                  scope='once', rank=None, reason='不用这些图', allow_remote=False,
                                  use_for_evolution=False)
        with patch('builtins.input', return_value='yes'):
            record_review(args, self.state, proposal)
        learned = semantic.active_rules(self.state)

        class FuturePlanner(Planner):
            def next_action(self, request):
                owner_test.assertIn('频谱图', request['instruction'])
                owner_test.assertEqual(request['owner_semantic_preferences'][0]['action'], 'cleanup')
                return super().next_action(request)

        future_group = self.group | {'photos': [self.photo | {'id': 'new-photo', 'sha': 'new-sha'}]}
        result = run_agent('review future photo', [future_group], self.state, BASE, {}, FuturePlanner([]),
                           ask_user=lambda _: '', semantic_rules=learned)
        self.assertEqual(result.keep_ids, set())

    def test_direct_model_advice_also_receives_owner_preferences(self):
        semantic.remember(self.state, self.rule, self.review)
        (self.state / 'thumbs').mkdir()
        (self.state / 'thumbs' / 'sha.jpg').write_bytes(b'test image bytes')
        owner_test = self

        class Gateway:
            def advise(self, request):
                owner_test.assertIn('频谱图', request['task'])
                owner_test.assertIn('cleanup', request['task'])
                return {'keep_ids': [], 'reason': 'Matched owner-confirmed spectrum preference.'}

        keep, _ = model_advice(Gateway(), self.group, self.state, {'p'}, {},
                               semantic_rules=semantic.active_rules(self.state))
        self.assertEqual(keep, set())


if __name__ == '__main__':
    unittest.main()
