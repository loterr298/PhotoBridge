import copy
import hashlib
import json
import unittest
from unittest.mock import patch
import tempfile
from pathlib import Path
from device_photos_recovery import bind_stop, bind_final, verify


class PhotosRecoveryAuditChecks(unittest.TestCase):
    def fixture(self):
        manifest = dict(sourceOrder=dict(albumIdentifier='source-album'), assets=[dict(sourceAssetLocalIdentifier='source-one'),dict(sourceAssetLocalIdentifier='source-two')])
        raw = json.dumps(manifest).encode(); request = b'USB request exact bytes'
        plan = dict(schemaVersion='1.0.0',attemptID='F46809AA-719F-4B10-90AD-D6EA19728CE9',inboxSessionID='F46809AA-719F-4B10-90AD-D6EA19728CE0',
            manifestSHA256=hashlib.sha256(raw).hexdigest(),requestSHA256=hashlib.sha256(request).hexdigest(),sourceAlbumID='source-album',sourceAssetIDs=['source-one','source-two'],title='new album',allowTimestampRewrite=False)
        plan_raw = json.dumps(plan).encode(); events = {}
        for name,kind,ordinal,created in [('album-intent.json','album-intent',0,None),('album-placeholder.json','album-placeholder',0,'new-album'),('000001-intent.json','asset-intent',1,None),('000001-placeholder.json','asset-placeholder',1,'new-one')]:
            events[name] = dict(schemaVersion='1.0.0',attemptID=plan['attemptID'],planSHA256=hashlib.sha256(plan_raw).hexdigest(),kind=kind,ordinal=ordinal)
            if ordinal:events[name]['sourceID']='source-one'
            if created:events[name]['createdID']=created
        progress = dict(status='INCOMPLETE',runtimeBuild='target-build',runtimeVersion='0.3.6',recoveryProtocol='explicit-placeholder-v1',
            diagnosticStopWindow='AFTER_FIRST_PHOTOS_COMMIT_BEFORE_RESOURCE_VERIFICATION',createdAssets=1,newAssetsCreatedThisRun=1,
            resourcesVerifiedAssets=0,recoveredExistingAssets=0,createdAlbumID='new-album',newAlbumTitle='new album',attemptID=plan['attemptID'],userAuthorizedAdjustmentTimestampRewrite=False)
        return raw,request,plan_raw,progress,events,plan

    def test_exact_stop_binding_identifies_first_existing_copy(self):
        raw,request,plan_raw,progress,events,plan=self.fixture()
        result=bind_stop(raw,request,plan_raw,progress,events,'target-build',plan['inboxSessionID'])
        self.assertEqual(result['firstCreatedID'],'new-one')

    def test_foreign_manifest_policy_counter_or_event_never_establishes_baseline(self):
        for fault in ['manifest','policy','counter','event','original','missing','verified']:
            with self.subTest(fault=fault):
                raw,request,plan_raw,progress,events,plan=self.fixture()
                if fault=='manifest':raw+=b' '
                if fault=='policy':progress['userAuthorizedAdjustmentTimestampRewrite']=True
                if fault=='counter':progress['resourcesVerifiedAssets']=1
                if fault=='event':events['000001-placeholder.json']['planSHA256']='0'*64
                if fault=='original':events['000001-placeholder.json']['createdID']='source-one'
                if fault=='missing':events.pop('000001-placeholder.json')
                if fault=='verified':events['000001-verified.json']={}
                with self.assertRaises(ValueError):bind_stop(raw,request,plan_raw,progress,events,'target-build',plan['inboxSessionID'])

    def test_final_must_reuse_same_album_first_id_and_exact_remaining_count(self):
        raw,request,plan_raw,progress,events,plan=self.fixture()
        baseline=bind_stop(raw,request,plan_raw,progress,events,'target-build',plan['inboxSessionID'])
        report=dict(runtimeBuild='target-build',recoveryProtocol='explicit-placeholder-v1',recoveryInvocation=True,attemptID=plan['attemptID'],
            createdAlbumID='new-album',newAlbumTitle='new album',observedCreatedAssetIDs=['new-one','new-two'],sourceToCreatedAssetIDs={'source-one':'new-one','source-two':'new-two'},
            createdAssets=2,resourcesVerifiedAssets=2,newAssetsCreatedThisRun=1,recoveredExistingAssets=1,
            userAuthorizedAdjustmentTimestampRewrite=False,verificationDirectory='verification-attempts/F46809AA-719F-4B10-90AD-D6EA19728CE1')
        bind_final(report,baseline)
        for key,value in [('createdAlbumID','other'),('newAssetsCreatedThisRun',2),('recoveredExistingAssets',0),('observedCreatedAssetIDs',['other','new-two']),('runtimeBuild','other'),('newAlbumTitle','wrong'),('observedCreatedAssetIDs',['new-one','source-two'])]:
            changed=copy.deepcopy(report);changed[key]=value
            if key=='observedCreatedAssetIDs':changed['sourceToCreatedAssetIDs']=dict(zip(['source-one','source-two'],value))
            with self.subTest(key=key),self.assertRaises(ValueError):bind_final(changed,baseline)

    def saved_fixture(self, root):
        raw,request,plan_raw,progress,events,plan=self.fixture()
        baseline=root/'baseline';files=baseline/'phone-files';files.mkdir(parents=True)
        contents={'album-order.json':raw,'restore-request.json':request,'restore-progress.json':json.dumps(progress).encode(),
                  'restore-started.json':b'{}','restore-recovery/plan.json':plan_raw}
        contents.update({'restore-recovery/'+name:json.dumps(e).encode() for name,e in events.items()})
        state={}
        for name,data in contents.items():
            path=files/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
            state[name]=dict(sha256=hashlib.sha256(data).hexdigest(),byteCount=len(data),attributes={'st_size':str(len(data)),'st_mtime':'1','st_nlink':'1'})
        (baseline/'phone-state.json').write_text(json.dumps(state))
        (baseline/'private-request.json').write_text(json.dumps(dict(remote='RestoreInbox/'+plan['inboxSessionID'],expectedBuild='target-build')))
        report=dict(runtimeBuild='target-build',recoveryProtocol='explicit-placeholder-v1',recoveryInvocation=True,attemptID=plan['attemptID'],
            createdAlbumID='new-album',newAlbumTitle='new album',observedCreatedAssetIDs=['new-one','new-two'],
            sourceToCreatedAssetIDs={'source-one':'new-one','source-two':'new-two'},createdAssets=2,resourcesVerifiedAssets=2,
            newAssetsCreatedThisRun=1,recoveredExistingAssets=1,userAuthorizedAdjustmentTimestampRewrite=False,
            verificationDirectory='verification-attempts/F46809AA-719F-4B10-90AD-D6EA19728CE1')
        return baseline,state,report

    def test_downloaded_report_switch_cannot_claim_baseline_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);baseline,state,report=self.saved_fixture(root)
            def changed_audit(client,remote,source,output):
                output.mkdir();changed=copy.deepcopy(report);changed['observedCreatedAssetIDs'][0]='different-copy'
                (output/'restore-report.json').write_text(json.dumps(changed));return {}
            with patch('device_photos_recovery.snapshot',return_value=state),patch('device_photos_recovery.read_json',return_value=(json.dumps(report).encode(),report)),patch('device_photos_recovery.audit',side_effect=changed_audit):
                with self.assertRaises(ValueError):verify(None,baseline,root/'source',root/'output',True)
            self.assertFalse((root/'output/recovery-audit.json').exists())

    def test_empty_truncated_or_changed_baseline_cannot_claim_preservation(self):
        for fault in ['empty','truncated','changed-bytes']:
            with self.subTest(fault=fault),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);baseline,state,report=self.saved_fixture(root)
                if fault=='empty':state={}
                if fault=='truncated':state.pop('restore-recovery/000001-placeholder.json')
                if fault=='changed-bytes':(baseline/'phone-files/restore-started.json').write_bytes(b'changed')
                (baseline/'phone-state.json').write_text(json.dumps(state))
                def good_audit(client,remote,source,output):
                    output.mkdir();(output/'restore-report.json').write_text(json.dumps(report));return {}
                with patch('device_photos_recovery.snapshot',return_value=state),patch('device_photos_recovery.read_json',return_value=(json.dumps(report).encode(),report)),patch('device_photos_recovery.audit',side_effect=good_audit):
                    with self.assertRaises(ValueError):verify(None,baseline,root/'source',root/'output',True)
                self.assertFalse((root/'output/recovery-audit.json').exists())

    def test_relaunch_claim_requires_user_attestation(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);baseline,state,report=self.saved_fixture(root)
            with self.assertRaisesRegex(ValueError,'attestation'):verify(None,baseline,root/'source',root/'output',False)

    def test_complete_saved_baseline_and_exact_audited_report_can_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);baseline,state,report=self.saved_fixture(root)
            def good_audit(client,remote,source,output):
                output.mkdir();(output/'restore-report.json').write_text(json.dumps(report));return {}
            with patch('device_photos_recovery.snapshot',return_value=state),patch('device_photos_recovery.read_json',return_value=(json.dumps(report).encode(),report)),patch('device_photos_recovery.audit',side_effect=good_audit):
                result=verify(None,baseline,root/'source',root/'output',True)
                self.assertTrue(result['sameFirstCreatedID'])
