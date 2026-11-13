#!/usr/bin/env python3
"""Reproducible Neox TestFlight release. Stdlib + macOS Xcode/openssl only.

Usage:
  scripts/testflight.py doctor
  scripts/testflight.py release --archive path/to/existing.xcarchive
  scripts/testflight.py release --bump
  scripts/testflight.py status --build 17

The API key lives outside the repository. No Xcode GUI account is required.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = Path(__file__).with_suffix('.json')
API = 'https://api.appstoreconnect.apple.com'


class ReleaseError(Exception):
    pass


def log(message: str):
    print(message, flush=True)


def load_config(path=CONFIG_PATH):
    cfg = json.loads(Path(path).read_text())
    for key in ('bundle_id', 'team_id', 'app_id', 'key_id', 'issuer_id', 'scheme', 'project', 'info_plist', 'group_id'):
        if not isinstance(cfg.get(key), str) or not cfg[key]:
            raise ReleaseError('Missing configuration field: '+key)
    return cfg


def key_path(cfg):
    # Private material must never be stored in the repo or copied into logs.
    directory = Path(os.environ.get('ASC_PRIVATE_KEYS_DIR', '~/.private_keys')).expanduser()
    path = directory / ('AuthKey_'+cfg['key_id']+'.p8')
    if not path.is_file():
        raise ReleaseError('App Store Connect private key missing at '+str(path))
    if path.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise ReleaseError('Private key has group/other permissions; run chmod 600 on '+str(path))
    return path


def b64(value: bytes):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode('ascii')


def der_signature_to_raw(data):
    """Convert OpenSSL ASN.1 ECDSA signature to the 64-byte ES256 JWS format."""
    def tlv(buf, pos):
        if pos + 2 > len(buf):
            raise ReleaseError('Invalid ECDSA signature encoding')
        tag = buf[pos]
        length = buf[pos+1]
        start = pos + 2
        if length & 128:
            count = length & 127
            if count == 0 or count > 4 or start + count > len(buf):
                raise ReleaseError('Invalid ECDSA signature length')
            length = int.from_bytes(buf[start:start+count], 'big')
            start += count
        end = start + length
        if end > len(buf):
            raise ReleaseError('Truncated ECDSA signature')
        return tag, buf[start:end], end
    outer, body, end = tlv(data, 0)
    if outer != 0x30 or end != len(data):
        raise ReleaseError('Expected DER SEQUENCE')
    t1, r, index = tlv(body, 0)
    t2, s, end = tlv(body, index)
    if t1 != 2 or t2 != 2 or end != len(body):
        raise ReleaseError('Expected DER INTEGER pair')
    try:
        return int.from_bytes(r, 'big').to_bytes(32, 'big') + int.from_bytes(s, 'big').to_bytes(32, 'big')
    except OverflowError as exc:
        raise ReleaseError('Invalid ES256 signature width') from exc


def jwt(cfg, path, now=None):
    epoch = int(time.time() if now is None else now)
    head = b64(json.dumps({'alg':'ES256', 'kid':cfg['key_id'], 'typ':'JWT'}, separators=(',', ':')).encode())
    body = b64(json.dumps({'iss':cfg['issuer_id'], 'iat':epoch, 'exp':epoch+600, 'aud':'appstoreconnect-v1'}, separators=(',', ':')).encode())
    signing_input = (head+'.'+body).encode()
    signature = subprocess.run(['openssl','dgst','-sha256','-sign',str(path)], input=signing_input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if signature.returncode:
        raise ReleaseError('Failed to sign App Store Connect request with local private key')
    return head+'.'+body+'.'+b64(der_signature_to_raw(signature.stdout))


class Apple:
    def __init__(self, cfg, path):
        self.cfg, self.path = cfg, path

    def request(self, path, method='GET', payload=None):
        if not path.startswith('/'):
            raise ReleaseError('Unexpected Apple API path')
        url = API+path
        data = None if payload is None else json.dumps(payload).encode('utf-8')
        headers = {'Authorization':'Bearer '+jwt(self.cfg, self.path), 'Accept':'application/json'}
        if data is not None:
            headers['Content-Type']='application/json'
        req = urllib.request.Request(url, method=method, headers=headers, data=data)
        try:
            with urllib.request.urlopen(req, timeout=25) as response:
                content = response.read()
                return json.loads(content) if content else {}
        except urllib.error.HTTPError as exc:
            # Never include request headers or secrets in error output.
            try:
                errors = json.loads(exc.read()).get('errors', [])
                detail = '; '.join((x.get('code','')+': '+x.get('title','')) for x in errors[:2])
            except Exception:
                detail = ''
            raise ReleaseError('Apple API HTTP '+str(exc.code)+' '+detail) from exc
        except urllib.error.URLError as exc:
            raise ReleaseError('Apple API unavailable: '+str(exc.reason)) from exc

    def pages(self, path, maximum=12):
        results = []
        for _ in range(maximum):
            doc = self.request(path)
            results.extend(doc.get('data', []))
            next_url = doc.get('links',{}).get('next')
            if not next_url:
                return results
            parsed = urllib.parse.urlsplit(next_url)
            if parsed.scheme != 'https' or parsed.netloc != 'api.appstoreconnect.apple.com':
                raise ReleaseError('Apple API pagination URL has unexpected origin')
            path = parsed.path + ('?'+parsed.query if parsed.query else '')
        raise ReleaseError('Apple API pagination limit reached; cannot safely choose a build number')

    def app(self):
        doc = self.request('/v1/apps/'+urllib.parse.quote(self.cfg['app_id']))
        obj = doc.get('data',{})
        if obj.get('attributes',{}).get('bundleId') != self.cfg['bundle_id']:
            raise ReleaseError('App Store Connect app ID does not match configured bundle ID')
        return obj

    def builds(self):
        appid = urllib.parse.quote(self.cfg['app_id'])
        return self.pages('/v1/builds?filter%5Bapp%5D='+appid+'&limit=200&include=preReleaseVersion')

    def build(self, build_number):
        matches = [b for b in self.builds() if b.get('attributes',{}).get('version') == str(build_number)]
        if len(matches)>1:
            raise ReleaseError('Multiple App Store Connect builds share build number '+str(build_number))
        return matches[0] if matches else None

    def group_state(self, build_id):
        group = self.request('/v1/betaGroups/'+urllib.parse.quote(self.cfg['group_id']))['data']
        if not group['attributes'].get('isInternalGroup', False):
            raise ReleaseError('Configured group is not an internal TestFlight group')
        app_rel = group.get('relationships',{}).get('app',{}).get('data',{})
        if app_rel and app_rel.get('id') != self.cfg['app_id']:
            raise ReleaseError('Configured tester group belongs to another app')
        # Apple's builds/{id}/relationships/betaGroups endpoint does not support GET.
        # Verify membership through the documented betaGroups/{id}/builds listing.
        builds = self.pages('/v1/betaGroups/'+urllib.parse.quote(self.cfg['group_id'])+'/builds?limit=200')
        return group, any(b.get('id')==build_id for b in builds)

    def attach_group(self, build_id):
        body = {'data':[{'type':'betaGroups','id':self.cfg['group_id']}]}
        self.request('/v1/builds/'+urllib.parse.quote(build_id)+'/relationships/betaGroups', method='POST', payload=body)
        _, linked = self.group_state(build_id)
        if not linked:
            raise ReleaseError('Tester group assignment was not confirmed by Apple API')


def stored_version(cfg):
    p = ROOT/cfg['info_plist']
    with p.open('rb') as fh:
        info=plistlib.load(fh)
    return str(info['CFBundleShortVersionString']), str(info['CFBundleVersion'])


def archived_version(archive, cfg):
    app = archive/'Products'/'Applications'/(cfg['scheme'].removesuffix('App')+'.app')
    if not (app/'Info.plist').is_file():
        candidates=list((archive/'Products'/'Applications').glob('*.app/Info.plist'))
        if len(candidates)!=1:
            raise ReleaseError('Cannot find a unique iOS app inside archive')
        app=candidates[0].parent
    with (app/'Info.plist').open('rb') as f:
        info=plistlib.load(f)
    if info.get('CFBundleIdentifier')!=cfg['bundle_id']:
        raise ReleaseError('Archive bundle ID does not match target')
    return str(info['CFBundleShortVersionString']), str(info['CFBundleVersion'])


def numeric_build(build):
    if not re.fullmatch(r'[0-9]+',str(build)):
        raise ReleaseError('This release tool requires integer build numbers; got '+str(build))
    return int(build)


def latest_build_num(builds):
    nums = [numeric_build(b['attributes']['version']) for b in builds]
    return max(nums, default=0)


def check_signing(cfg):
    """Warn before release; Xcode automatic signing with the API key may repair a stale profile."""
    identities = subprocess.run(['security','find-identity','-v','-p','codesigning'], capture_output=True, text=True, check=True).stdout
    certs = set(re.findall(r'\b([A-F0-9]{40}) "Apple Distribution:.*?"', identities))
    if not certs:
        log('SIGNING: No local Apple Distribution identity; authenticated Xcode export must provision one.')
        return False
    profiles = Path.home()/'Library/Developer/Xcode/UserData/Provisioning Profiles'
    matched = False
    found = False
    for profile in profiles.glob('*.mobileprovision'):
        cms = subprocess.run(['security','cms','-D','-i',str(profile)],capture_output=True)
        if cms.returncode:
            continue
        try:
            data=plistlib.loads(cms.stdout)
        except Exception:
            continue
        if data.get('Entitlements',{}).get('application-identifier','').split('.',1)[-1] != cfg['bundle_id']:
            continue
        if data.get('Entitlements',{}).get('get-task-allow',True):
            continue
        found=True
        embedded={hashlib.sha1(c).hexdigest().upper() for c in data.get('DeveloperCertificates',[])}
        if embedded & certs:
            matched = True
            log('SIGNING: Local distribution certificate matches cached App Store profile.')
            break
    if not matched:
        log('SIGNING: No compatible cached distribution profile'+(' (stale profile found).' if found else '.')+' Xcode must refresh signing with API-key access.')
    return matched


def run_logged(command, outfile, env=None):
    outfile.parent.mkdir(parents=True, exist_ok=True)
    log('RUN: '+command[0]+' → '+outfile.name+' (details in private run directory)')
    with outfile.open('w') as f:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
    if result.returncode:
        errors = []
        for line in outfile.read_text(errors='replace').splitlines():
            if 'error:' in line or '** EXPORT FAILED **' in line or '** ARCHIVE FAILED **' in line:
                errors.append(line.strip())
        raise ReleaseError('Command failed ('+str(result.returncode)+'): '+(' | '.join(errors[-3:])[:500] if errors else 'see '+str(outfile)))


def export_options(path, cfg):
    options={'method':'app-store-connect','destination':'upload','signingStyle':'automatic',
             'teamID':cfg['team_id'],'manageAppVersionAndBuildNumber':False,'uploadSymbols':True}
    path.write_bytes(plistlib.dumps(options))


def ensure_build_not_used(apple, version, build):
    builds=apple.builds()
    if numeric_build(build) <= latest_build_num(builds):
        raise ReleaseError('Build '+build+' is not newer than existing Apple build '+str(latest_build_num(builds))+'. Use release --bump for fresh builds.')
    return builds


def report_status(apple, version, build, assign=False):
    target=apple.build(build)
    if not target:
        log('STORE: '+version+' ('+build+') not present in App Store Connect. No upload is verified.')
        return False
    attrs=target.get('attributes',{})
    if str(attrs.get('version')) != build:
        raise ReleaseError('Build number mismatch on readback')
    bid=target['id']
    state=attrs.get('processingState')
    log('STORE: build='+build+' processingState='+str(state)+' uploadedDate='+str(attrs.get('uploadedDate')))
    if state!='VALID':
        log('STOP: Apple has not finished processing this build.')
        return False
    try:
        beta=apple.request('/v1/builds/'+urllib.parse.quote(bid)+'/buildBetaDetail').get('data',{})
        internal=beta.get('attributes',{}).get('internalBuildState')
    except ReleaseError as exc:
        internal='unverified ('+str(exc)+')'
    log('BETA: internalBuildState='+str(internal)+' usesNonExemptEncryption='+str(attrs.get('usesNonExemptEncryption')))
    group, linked=apple.group_state(bid)
    log('GROUP: '+str(group['attributes'].get('name'))+' linked='+str(linked))
    if not linked and assign:
        apple.attach_group(bid)
        linked=True
        log('GROUP: newly linked and verified')
    # Apple's IN_BETA_TESTING is independent from VALID and group linkage.
    if internal=='IN_BETA_TESTING' and linked:
        log('API: internal TestFlight group is active. Check App Store Connect website and phone TestFlight for final release gates.')
        return True
    log('PENDING: Compliance, beta activation or tester group is not fully confirmed. No installability claim.')
    return False


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument('--config',type=Path,default=CONFIG_PATH)
    sub=parser.add_subparsers(dest='action',required=True)
    doctor=sub.add_parser('doctor',help='Check credentials, App Store identity, build numbers and cached signing (read-only).')
    doctor.add_argument('--offline',action='store_true',help='Skip Apple network for local diagnostics')
    release=sub.add_parser('release',help='Archive and upload through API-key signing, then read back Apple state.')
    release.add_argument('--archive',type=Path,help='Upload an existing .xcarchive; does not rebuild')
    release.add_argument('--bump',action='store_true',help='Increase local Info.plist build number above Apple builds before archive')
    release.add_argument('--dry-run',action='store_true',help='Perform preflight only; do not change source, archive or upload')
    release.add_argument('--wait-seconds',type=int,default=480,help='Wait for Apple processing after upload (default 480s)')
    status=sub.add_parser('status',help='Read Apple processing, compliance and internal testing state.')
    status.add_argument('--build',required=True)
    status.add_argument('--assign-group',action='store_true',help='Link configured internal group if build is VALID; never change compliance')
    args=parser.parse_args(argv)
    cfg=load_config(args.config)
    p8=key_path(cfg)
    if args.action in ('doctor','release'):
        version,build=stored_version(cfg)
        log('APP: '+cfg['bundle_id']+' '+version+' ('+build+')')
        check_signing(cfg)
    if args.action=='doctor' and args.offline:
        log('AUTH: private key found with restrictive permissions (offline mode).')
        return 0
    apple=Apple(cfg,p8)
    app=apple.app()
    log('AUTH: App Store Connect API verified: '+str(app['attributes'].get('name')))
    if args.action=='doctor':
        builds=apple.builds()
        log('STORE: max uploaded build number '+str(latest_build_num(builds))+'; local '+build)
        return 0
    if args.action=='status':
        return 0 if report_status(apple,'?',str(args.build),assign=args.assign_group) else 2
    if args.archive and args.bump:
        raise ReleaseError('--archive and --bump cannot be combined')
    if args.wait_seconds<0:
        raise ReleaseError('--wait-seconds must be nonnegative')
    if args.archive:
        archive=args.archive.expanduser().resolve()
        if not archive.is_dir():
            raise ReleaseError('Archive path does not exist: '+str(archive))
        version,build=archived_version(archive,cfg)
    else:
        archive=None
        if args.bump:
            builds=apple.builds()
            build=str(max(numeric_build(build),latest_build_num(builds))+1)
    ensure_build_not_used(apple,version,build)
    log('TARGET: '+version+' ('+build+')')
    if args.dry_run:
        log('DRY RUN: credentials and build preflight passed; no source changes or upload.')
        return 0
    if not archive:
        # Deliberate source version bump; caller is responsible for reviewing/committing the changed Info.plist.
        if args.bump:
            plist=ROOT/cfg['info_plist']
            subprocess.run(['/usr/libexec/PlistBuddy','-c','Set :CFBundleVersion '+build,str(plist)],check=True)
            log('SOURCE: updated '+str(plist)+' to build '+build+'; commit this change after release.')
        subprocess.run(['xcodegen','generate'], cwd=ROOT,check=True, stdout=subprocess.DEVNULL)
    timestamp=dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    run_dir=ROOT/'runs'/('testflight-'+version+'-'+build+'-'+timestamp)
    run_dir.mkdir(parents=True,exist_ok=False)
    os.chmod(run_dir,0o700)
    if not archive:
        archive=run_dir/('Neox-'+version+'-'+build+'.xcarchive')
        run_logged(['xcodebuild','-project',cfg['project'],'-scheme',cfg['scheme'],
                    '-configuration','Release','-destination','generic/platform=iOS',
                    '-archivePath',str(archive),'-allowProvisioningUpdates',
                    '-authenticationKeyPath',str(p8),'-authenticationKeyID',cfg['key_id'],
                    '-authenticationKeyIssuerID',cfg['issuer_id'],'archive'],run_dir/'archive.log')
    archived_v, archived_b=archived_version(archive,cfg)
    if (archived_v,archived_b)!=(version,build):
        raise ReleaseError('ARCHIVE: build identity changed unexpectedly')
    options=run_dir/'ExportOptions.plist'
    export_options(options,cfg)
    run_logged(['xcodebuild','-exportArchive','-archivePath',str(archive),
                '-exportOptionsPlist',str(options),'-exportPath',str(run_dir/'Export'),
                '-allowProvisioningUpdates','-authenticationKeyPath',str(p8),
                '-authenticationKeyID',cfg['key_id'],'-authenticationKeyIssuerID',cfg['issuer_id']],run_dir/'upload.log')
    log('UPLOAD: Xcode completed transport. Apple server processing and beta availability are separate gates.')
    deadline=time.monotonic()+args.wait_seconds
    while True:
        target=apple.build(build)
        if target and target['attributes'].get('processingState') in ('VALID','FAILED','INVALID'):
            break
        if time.monotonic()>=deadline:
            raise ReleaseError('UPLOAD: Apple has not confirmed processed build '+build+' yet; use status --build '+build)
        time.sleep(min(20,max(1,deadline-time.monotonic())))
    result=report_status(apple,version,build,assign=True)
    return 0 if result else 2


if __name__=='__main__':
    try:
        sys.exit(main())
    except (ReleaseError, OSError, subprocess.CalledProcessError, ValueError, KeyError) as exc:
        print('TESTFLIGHT ERROR: '+str(exc),file=sys.stderr)
        sys.exit(1)
