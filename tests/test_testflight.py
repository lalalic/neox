"""Executable stdlib regression tests; never call Apple or modify credentials."""
import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT=Path(__file__).resolve().parents[1]/'scripts'/'testflight.py'
spec=importlib.util.spec_from_file_location('testflight',SCRIPT)
tf=importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)


class FakeApple:
    def __init__(self, state, attached=False):
        self.state=state
        self.attached=attached
        self.calls=[]

    def build(self,num):
        return {'id':'B17','attributes':{'version':'17','processingState':self.state,'uploadedDate':'2026-11-13','usesNonExemptEncryption':False}} if num=='17' else None

    def request(self,path,method='GET',payload=None):
        self.calls.append((path,method,payload))
        return {'data':{'attributes':{'internalBuildState': 'IN_BETA_TESTING'}}} if path.endswith('buildBetaDetail') else {}

    def group_state(self,bid):
        return ({'attributes':{'name':'testers','isInternalGroup':True}},self.attached)

    def attach_group(self,bid):
        self.attached=True
        self.calls.append(('attach',bid,None))


class TestTestFlight(unittest.TestCase):
    def test_config_matches_project(self):
        c=tf.load_config()
        self.assertEqual(c['bundle_id'],'com.neox.app')
        self.assertEqual(c['app_id'],'6761634486')
        version, build = tf.stored_version(c)
        self.assertTrue(version)
        self.assertGreater(tf.numeric_build(build),0)

    def test_apple_url_rejects_cross_origin_pagination(self):
        o=tf.Apple({},None)
        with patch.object(o,'request',return_value={'data':[], 'links':{'next':'http://other.example/steal'}}):
            with self.assertRaisesRegex(tf.ReleaseError,'unexpected origin'):
                o.pages('/v1/builds')

    def test_apple_url_follows_only_apple_pages(self):
        o=tf.Apple({},None)
        requests=[]
        def get(path):
            requests.append(path)
            if len(requests)==1:
                return {'data':[{'id':'one'}], 'links':{'next':'https://api.appstoreconnect.apple.com/v1/builds?cursor=x'}}
            return {'data':[{'id':'two'}]}
        with patch.object(o,'request',side_effect=get):
            self.assertEqual(len(o.pages('/v1/builds')),2)
        self.assertEqual(requests[1],'/v1/builds?cursor=x')

    def test_bump_is_monotonic_even_if_unsorted(self):
        b=[{'attributes':{'version':'4'}},{'attributes':{'version':'14'}},{'attributes':{'version':'9'}}]
        self.assertEqual(tf.latest_build_num(b),14)
        with self.assertRaises(tf.ReleaseError):
            tf.numeric_build('1.2')

    def test_existing_build_prevents_upload(self):
        a=type('AppleStub',(),{'builds':lambda self:[{'attributes':{'version':'17'}}]})()
        with self.assertRaisesRegex(tf.ReleaseError,'not newer'):
            tf.ensure_build_not_used(a,'0.1.0','17')

    def test_archive_checks_exact_bundle_and_version(self):
        c=tf.load_config()
        with tempfile.TemporaryDirectory() as temp:
            d=Path(temp)/'A.xcarchive/Products/Applications/Neox.app'
            d.mkdir(parents=True)
            (d/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.neox.app','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'17'}))
            self.assertEqual(tf.archived_version(Path(temp)/'A.xcarchive',c),('0.1.0','17'))
            (d/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.other.app'}))
            with self.assertRaisesRegex(tf.ReleaseError,'bundle ID'):
                tf.archived_version(Path(temp)/'A.xcarchive',c)

    def test_no_false_positive_for_processing_or_missing_group(self):
        self.assertFalse(tf.report_status(FakeApple('PROCESSING'),'0.1.0','17',assign=True))
        self.assertFalse(tf.report_status(FakeApple('VALID'),'0.1.0','17',assign=False))
        a=FakeApple('VALID')
        self.assertTrue(tf.report_status(a,'0.1.0','17',assign=True))
        self.assertTrue(a.attached)

    def test_key_permissions_are_enforced(self):
        c=tf.load_config()
        with tempfile.TemporaryDirectory() as temp:
            k=Path(temp)/('AuthKey_'+c['key_id']+'.p8')
            k.write_text('test-not-a-private-key')
            os.chmod(k,0o644)
            with patch.dict(os.environ,{'ASC_PRIVATE_KEYS_DIR':temp}):
                with self.assertRaisesRegex(tf.ReleaseError,'chmod 600'):
                    tf.key_path(c)
                os.chmod(k,0o600)
                self.assertEqual(tf.key_path(c),k)

    def test_release_existing_archive_executes_only_export_and_verifies_group(self):
        c=tf.load_config()
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            info=root/'Neox'/'Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.1.0','CFBundleVersion':'17'}))
            app=root/'candidate.xcarchive/Products/Applications/Neox.app'
            app.mkdir(parents=True)
            (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.neox.app','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'17'}))
            fake=FakeApple('VALID',attached=True)
            fake.app=lambda:{'attributes':{'bundleId':c['bundle_id'],'name':'Neox AI'}}
            fake.builds=lambda:[{'attributes':{'version':'14'}}]
            seen=[]
            def runner(command,output,env=None):
                seen.append(command)
            with patch.object(tf,'ROOT',root), patch.object(tf,'Apple',return_value=fake), patch.object(tf,'key_path',return_value=root/'fake-key.p8'),patch.object(tf,'check_signing',return_value=True),patch.object(tf,'run_logged',side_effect=runner):
                self.assertEqual(tf.main(['release','--archive',str(app.parents[2]),'--wait-seconds','0']),0)
            self.assertEqual(len(seen),1)
            self.assertIn('-exportArchive',seen[0])
            self.assertIn('-authenticationKeyPath',seen[0])
            self.assertNotIn('archive',seen[0]) # avoid accidentally invoking a build step

    def test_dry_run_never_invokes_upload_or_modifies_source(self):
        c=tf.load_config()
        fake=FakeApple('VALID',attached=True)
        fake.app=lambda:{'attributes':{'bundleId':c['bundle_id'],'name':'Neox AI'}}
        fake.builds=lambda:[{'attributes':{'version':'14'}}]
        with patch.object(tf,'Apple',return_value=fake), patch.object(tf,'key_path',return_value=Path('/not/used')),patch.object(tf,'check_signing',return_value=True),patch.object(tf,'run_logged') as run:
            self.assertEqual(tf.main(['release','--dry-run']),0)
            run.assert_not_called()

    def test_ecdsa_der_signature_to_es256(self):
        if not shutil_which('openssl'):
            self.skipTest('OpenSSL not available')
        with tempfile.TemporaryDirectory() as temp:
            key=Path(temp)/'key.pem'
            subprocess.run(['openssl','ecparam','-name','prime256v1','-genkey','-noout','-out',str(key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            c={'key_id':'TESTKEY000','issuer_id':'00000000-0000-0000-0000-000000000000'}
            token=tf.jwt(c,key,now=1234567890)
            h,p,s=token.split('.')
            self.assertEqual(len(tf.base64.urlsafe_b64decode(s+'='*((-len(s))%4))),64)
            self.assertEqual(json.loads(tf.base64.urlsafe_b64decode(p+'='*((-len(p))%4)))['iat'],1234567890)
        with self.assertRaises(tf.ReleaseError):
            tf.der_signature_to_raw(b'invalid')


def shutil_which(name):
    from shutil import which
    return which(name)


if __name__=='__main__':
    unittest.main()
