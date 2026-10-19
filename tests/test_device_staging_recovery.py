import copy
import unittest
import device_staging_recovery as audit


class StagingAuditBindingChecks(unittest.TestCase):
    def test_manifest_is_bound_to_source_plan_and_current_session(self):
        descriptor = dict(resourceType=1, originalFilename='a.HEIC', uniformTypeIdentifier='public.heic')
        source = dict(identifier='a', creationDate=-0.001, pixelWidth=10, pixelHeight=20, mediaType=1, mediaSubtypes=0, resources=[descriptor])
        plan = dict(sessionID='session', sourceOrder=dict(albumIdentifier='album', albumName='test', capturedAt=0.1234567,
            members=[dict(ordinal=1, localIdentifier='a', creationDate=-0.001)]), assets=[source])
        order = dict(albumIdentifier='album', albumName='test', capturedAt='2001-01-01T00:00:00Z',
            members=[dict(ordinal=1, localIdentifier='a', creationDate='2000-12-31T23:59:59Z')])
        manifest = dict(sessionID='session', sourceOrder=order, assets=[dict(ordinal=1, sourceAssetLocalIdentifier='a',
            originalPhotoLibraryCreationDate='2000-12-31T23:59:59Z',pixelWidth=10,pixelHeight=20,mediaType=1,mediaSubtypes=0,
            resources=[dict(descriptor, resourceIndex=1)])])
        audit.bind_plan_manifest(plan, manifest)
        for fault in ['albumIdentifier', 'albumName', 'session', 'catalog', 'member']:
            with self.subTest(fault=fault):
                changed = copy.deepcopy(manifest)
                if fault in ['albumIdentifier','albumName']: changed['sourceOrder'][fault] = 'different'
                elif fault == 'session': changed['sessionID'] = 'different'
                elif fault == 'catalog': changed['assets'][0]['resources'][0]['uniformTypeIdentifier'] = 'different'
                else: changed['assets'][0]['sourceAssetLocalIdentifier'] = 'different'
                with self.assertRaises(ValueError): audit.bind_plan_manifest(plan, changed)


if __name__ == '__main__': unittest.main()
