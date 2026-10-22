import copy
import unittest
from device_preconditions_audit import bind_report, unchanged_inbox, _report_relative_path, read_report

class PreconditionsAuditChecks(unittest.TestCase):
    def report(self, mode):
        r=dict(kind='PhotoBridgePreflightReport',schemaVersion='1.0.0',sessionID='session',runtimeBuild='target',runtimeVersion='0.3.7',
            photoKitCreationRequestsIssuedByPreflight=False,photoAccessAtStart='full',photoAccessAtEnd='full',
            simulatedZeroCapacity=mode=='zero',manifestSHA256='source-hash',assets=3,resources=6,recordedAssets=0,
            remainingPhotoCopyBytes=100,remainingReadbackBytes=100,reserveBytes=128*1024*1024,
            requiredEstimatedBytes=200+128*1024*1024,actualAvailableBytes=1000000000,
            effectiveAvailableBytes=0 if mode=='zero' else 1000000000,
            status='BLOCKED' if mode=='zero' else 'READY',resourcesHashVerified=0 if mode=='zero' else 6)
        if mode=='zero':
            r['failureCode']='INSUFFICIENT_ESTIMATED_CAPACITY';r['resourcesHashVerified']=0
        if mode=='denied':
            r.update(photoAccessAtStart='denied',photoAccessAtEnd='denied',status='BLOCKED',resourcesHashVerified=0,failureCode='FULL_PHOTO_ACCESS_REQUIRED')
            for key in ['manifestSHA256','assets','resources','recordedAssets','remainingPhotoCopyBytes','remainingReadbackBytes','reserveBytes','requiredEstimatedBytes','actualAvailableBytes','effectiveAvailableBytes']:r.pop(key)
        return r
    def bind(self,r,mode):return bind_report(r,mode,'session','target','source-hash',3,6,(100,100))
    def test_three_distinct_modes_bind_actual_target_build(self):
        for mode in ['zero','denied','ready']:self.bind(self.report(mode),mode)
    def test_wrong_build_session_simulation_or_write_claim_refused(self):
        for key,value in [('runtimeBuild','other'),('sessionID','other'),('simulatedZeroCapacity',False),('photoKitCreationRequestsIssuedByPreflight',True),('effectiveAvailableBytes',1),('requiredEstimatedBytes',1),('resourcesHashVerified',6)]:
            with self.subTest(key=key):
                r=self.report('zero');r[key]=value
                with self.assertRaises(ValueError):self.bind(r,'zero')
    def test_denied_must_be_real_permission_and_before_capacity_read(self):
        for key,value in [('photoAccessAtStart','full'),('photoAccessAtEnd','limited'),('actualAvailableBytes',0),('resourcesHashVerified',1)]:
            r=self.report('denied');r[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.bind(r,'denied')
    def test_ready_requires_all_hashes_real_capacity_and_no_simulation(self):
        for key,value in [('resourcesHashVerified',5),('simulatedZeroCapacity',True),('effectiveAvailableBytes',0),('actualAvailableBytes',1),('failureCode','old-error')]:
            r=self.report('ready');r[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.bind(r,'ready')
    def test_empty_incomplete_or_changed_inbox_baseline_cannot_pass(self):
        expected={'album-order.json','restore-request.json','upload-owner.json','Resources/one'}
        before={k:dict(sha256='a',byteCount=1,attributes={'st_size':'1','st_mtime':'2','st_nlink':'1'}) for k in expected}
        unchanged_inbox(before,copy.deepcopy(before),expected)
        for fault in ['empty','missing','changed','new-intent']:
            a=copy.deepcopy(before);b=copy.deepcopy(before)
            if fault=='empty':a={}
            if fault=='missing':a.pop('Resources/one')
            if fault=='changed':b['Resources/one']['sha256']='b'
            if fault=='new-intent':b['restore-started.json']={}
            with self.subTest(fault=fault),self.assertRaises(ValueError):unchanged_inbox(a,b,expected)

    def test_shared_report_uses_selected_filename_without_session_path_guessing(self):
        self.assertEqual(_report_relative_path('report.json'), 'RestoreChecks/report.json')
        for unsafe in ['', '.', '..', '../report.json', 'RestoreChecks/report.json', 'a/b.json']:
            with self.subTest(unsafe=unsafe), self.assertRaises(ValueError):
                _report_relative_path(unsafe)

        class Client:
            def __init__(self): self.path = None
            def read(self, path, sink, maximum):
                self.path = path; sink(b'{"status":"READY"}')
        client = Client()
        self.assertEqual(read_report(client, 'RestoreChecks/report.json'), {'status': 'READY'})
        self.assertEqual(client.path, 'RestoreChecks/report.json')
