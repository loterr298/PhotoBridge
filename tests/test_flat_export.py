import hashlib, json, pathlib, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import album_export, album_restore
import test_album_export, test_album_restore

REQUEST = '9d4933c5-c0ef-4b67-9698-2c47077cd84d'

def fixture():
    m, files = test_album_export.AlbumExportChecks().fixture()
    for index, kind, name, uti, data in [(2,5,'same.JPG','public.jpeg',b'visible-edited'),
            (3,9,'same.MOV','com.apple.quicktime-movie',b'live-movie'),
            (4,7,'Adjustments.plist','com.apple.property-list',b'private-adjustments')]:
        path = f'Resources/000001/{index:04d}.' + name.rsplit('.',1)[1]
        m['assets'][0]['resources'].append(dict(resourceIndex=index,resourceType=kind,originalFilename=name,
            uniformTypeIdentifier=uti,storedRelativePath=path,sha256=hashlib.sha256(data).hexdigest(),byteCount=len(data)))
        files[path] = data
    return m, files

class Phone:
    def __init__(self,m,files,reject_media=()): self.m=m;self.files=files;self.reject_media=reject_media
    def read(self,path,sink,maximum=None):
        if path.startswith('Control/Jobs/'):
            data=json.dumps(dict(requestID=REQUEST,albumIdentifier='album-test',sessionID=self.m['sessionID'],status='STAGED')).encode()
        else:
            name=path.split('/'+self.m['sessionID']+'/',1)[1]
            if name=='source-order.json': data=json.dumps(self.m['sourceOrder']).encode()
            elif name=='album-order.json': data=json.dumps(self.m).encode()
            elif name.startswith('asset-records/'): data=json.dumps(self.m['assets'][int(pathlib.PurePosixPath(name).stem)-1]).encode()
            else:
                if name in self.reject_media: raise AssertionError('Verified previous media must be reused')
                data=self.files[name]
        if maximum is not None and len(data)>maximum:raise ValueError('bound')
        sink(data)

class FlatExportChecks(unittest.TestCase):
    def export(self,root,m,files,previous=None,reject_media=()):
        try: return album_export.download_live_album(Phone(m,files,reject_media),REQUEST,'album-test',root,previous=previous,flat=True)
        except TypeError as error: self.fail('Flat live export must be available: '+str(error))

    def test_one_visible_file_per_asset_no_child_directories_and_restore_keeps_all_resources(self):
        m,files=fixture()
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d)/'album';self.export(root,m,files)
            visible=sorted(p.name for p in root.iterdir() if not p.name.startswith('.'))
            self.assertEqual(visible,['000001_same.JPG','000002_same.HEIC'])
            self.assertFalse(any(p.is_dir() for p in root.iterdir()))
            self.assertEqual((root/visible[0]).read_bytes(),b'visible-edited')
            self.assertEqual((root/visible[1]).stat().st_mtime-(root/visible[0]).stat().st_mtime,5)
            raw,observed,resources,digest,total=album_restore.validated_backup(root)
            self.assertEqual(observed,m)
            for name,data in files.items():self.assertEqual(album_restore.regular_path(root,name).read_bytes(),data)
            remote=pathlib.Path(d)/'phone';remote.mkdir()
            result=album_restore.upload_backup(test_album_restore.RestoreChecks().client(remote),root)
            inbox=remote/result['remote']
            self.assertEqual(json.loads((inbox/'album-order.json').read_text()),m)
            for name,data in files.items():self.assertEqual((inbox/name).read_bytes(),data)
            self.assertFalse(any(p.is_dir() for p in root.iterdir()),'Upload journals must not add child folders')

    def test_legacy_partial_can_be_organized_then_resumed_without_old_file_changes(self):
        m,files=fixture()
        with tempfile.TemporaryDirectory() as d:
            old=pathlib.Path(d)/'old';old.mkdir();(old/'asset-records').mkdir()
            first={r['storedRelativePath']:files[r['storedRelativePath']] for r in m['assets'][0]['resources']}
            for name,data in first.items():p=old/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
            (old/'source-order.json').write_text(json.dumps(m['sourceOrder']))
            (old/'asset-records/000001.json').write_text(json.dumps(m['assets'][0]))
            (old/'transfer-progress.json').write_text(json.dumps(dict(status='FAILED',assetsVerified=1,
                albumIdentifier='album-test',requestID=REQUEST,remote='Exports/'+m['sessionID'],error='old transport failure')))
            baseline={str(p.relative_to(old)):(p.read_bytes(),p.stat().st_mtime_ns) for p in old.rglob('*') if p.is_file()}
            organized=pathlib.Path(d)/'organized'
            album_export.organize_local_album(old,organized)
            self.assertFalse(any(p.is_dir() for p in organized.iterdir()))
            self.assertEqual([p.name for p in organized.iterdir() if not p.name.startswith('.')],['000001_same.JPG'])
            progress=json.loads(album_restore.regular_path(organized,'transfer-progress.json').read_text())
            self.assertEqual(progress['assetsVerified'],1);self.assertEqual(progress['status'],'STOPPED');self.assertNotIn('error',progress)
            self.assertFalse((organized/'.photobridge-transfer-manifest.json').exists())
            target=pathlib.Path(d)/'continued';self.export(target,m,files,previous=organized,reject_media=first)
            album_restore.validated_backup(target)
            for name,(data,mtime) in baseline.items():self.assertEqual(((old/name).read_bytes(),(old/name).stat().st_mtime_ns),(data,mtime))

    def test_flat_resource_symlink_is_refused_before_upload(self):
        m,files=fixture()
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d)/'album';self.export(root,m,files)
            p=album_restore.regular_path(root,next(iter(files)));outside=pathlib.Path(d)/'outside';p.rename(outside);p.symlink_to(outside)
            remote=pathlib.Path(d)/'phone';remote.mkdir()
            with self.assertRaises(ValueError):album_restore.upload_backup(test_album_restore.RestoreChecks().client(remote),root)
            self.assertEqual(list(remote.iterdir()),[])

    def test_flat_backup_upload_can_resume_a_partial_phone_file_without_subfolders(self):
        import test_upload_resume, upload_resume
        with tempfile.TemporaryDirectory() as d:
            base=pathlib.Path(d)
            old,phone,m,files,client,writes,offsets=test_upload_resume.UploadContinuationChecks().setup_files(base)
            flat=base/'flat';album_export.organize_local_album(old,flat)
            with self.assertRaisesRegex(RuntimeError,'CONTROLLED_WRITER_INTERRUPTION'):upload_resume.upload(client,flat)
            journals=list(flat.glob('.photobridge-upload-*.json'));self.assertEqual(len(journals),1)
            old_journal=journals[0].read_bytes();client.interrupted=False
            result=upload_resume.upload(client,flat,journals[0])
            self.assertEqual(result['state'],'USB_VERIFIED');self.assertEqual(offsets,[5])
            self.assertEqual(journals[0].read_bytes(),old_journal)
            self.assertFalse(any(p.is_dir() for p in flat.iterdir()))
            for name,data in files.items():self.assertEqual((phone/result['remote']/name).read_bytes(),data)

    def test_visible_alias_cannot_overwrite_existing_user_file(self):
        import backup_layout
        m,files=fixture()
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d)/'album';self.export(root,m,files)
            existing=root/'000001_same.JPG';before=existing.read_bytes()
            with self.assertRaises(FileExistsError):backup_layout.publish_photo(root,m['assets'][0])
            self.assertEqual(existing.read_bytes(),before)

    def test_flat_names_do_not_allow_original_filename_paths_to_escape(self):
        import backup_layout
        m,files=fixture();m['assets'][0]['resources'][1]['originalFilename']='../../evil:photo.JPG'
        self.assertEqual(backup_layout.visible_name(m['assets'][0]),'000001_evil-photo.JPG')
