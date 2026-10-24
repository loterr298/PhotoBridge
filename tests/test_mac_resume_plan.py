import json, pathlib, sys, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import mac_control

class ResumePlanChecks(unittest.TestCase):
    def test_ready_phone_export_is_reused_without_a_new_photos_request(self):
        journal = {'requestID': '12345678-1234-4234-8234-123456789abc', 'albumIdentifier': 'album',
                   'remote': 'Exports/87654321-4321-4321-8321-123456789abc'}
        class Client:
            def read(self, path, sink, maximum):
                sink(json.dumps({'requestID': journal['requestID'], 'albumIdentifier': 'album',
                    'sessionID': '87654321-4321-4321-8321-123456789abc', 'status': self.state}).encode())
        c = Client()
        for state in ['STAGING', 'FINALIZING', 'STAGED']:
            c.state = state
            plan = mac_control.continuation_plan(c, journal)
            self.assertEqual(plan['existingRequestID'], journal['requestID'])
            self.assertNotIn('resumeSession', plan)
        c.state = 'STOPPED'
        plan = mac_control.continuation_plan(c, journal)
        self.assertEqual(plan['resumeSession'], '87654321-4321-4321-8321-123456789abc')
        self.assertNotIn('existingRequestID', plan)
        with self.assertRaises(ValueError): mac_control.continuation_plan(c, dict(journal, albumIdentifier='other'))
