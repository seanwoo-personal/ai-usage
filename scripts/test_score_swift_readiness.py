import unittest
from score_swift_readiness import overlay


def report():
    return {'meta': {'rubric_version': 'v2-100pt'}, 'total': 95, 'categories': {
        'A': {'score': 15}, 'B': {'score': 20}, 'C': {'score': 20},
        'D': {'score': 13, 'evidence': {'monorepo_workspace': False}},
        'E': {'score': 14, 'sub_scores': {'E3_TaskValidation': 3}},
        'F': {'score': 8, 'evidence': {'hook_validates_paths': False}},
        'G': {'score': 5}}}


class SwiftScoreTests(unittest.TestCase):
    def test_equivalence(self):
        self.assertEqual(overlay(report(), (True, True, True))['adapted_total'], 100)

    def test_missing_equivalents_earn_nothing(self):
        self.assertEqual(overlay(report(), (False, False, False))['adapted_total'], 95)

    def test_unrelated_gaps_remain(self):
        data = report()
        data['categories']['G']['score'] = 4
        data['total'] = 94
        self.assertEqual(overlay(data, (True, True, True))['adapted_total'], 99)

    def test_no_double_credit(self):
        data = report()
        data['categories']['D'].update(score=15, evidence={'monorepo_workspace': True})
        data['categories']['F'].update(score=10, evidence={'hook_validates_paths': True})
        data['categories']['E'].update(score=15, sub_scores={'E3_TaskValidation': 4})
        data['total'] = 100
        self.assertEqual(overlay(data, (True, True, True))['adapted_total'], 100)

    def test_invalid_total(self):
        data = report()
        data['total'] = 100
        with self.assertRaises(ValueError):
            overlay(data, (True, True, True))
