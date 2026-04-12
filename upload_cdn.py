#!/usr/bin/env python3
"""Upload App Store pages (privacy, terms, support) to Qiniu CDN."""
import os
import sys
import hmac
import hashlib
import base64
import json
import urllib.request

# Load from .env.local (check neox/ first, then root)
env = {}
for env_path in [
    os.path.join(os.path.dirname(__file__), '.env.local'),
    os.path.join(os.path.dirname(__file__), '..', '.env.local'),
]:
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    k, v = line.split('=', 1)
                    env[k] = v.strip('"').strip("'")
        break

ACCESS_KEY = env.get('QINIU_ACCESS_KEY', '')
SECRET_KEY = env.get('QINIU_SECRET_KEY', '')
BUCKET = env.get('CDN_BUCKET', 'qiliadmin')
CDN_DOMAIN = env.get('CDN_DOMAIN', 'cdn.qili2.com')

if not ACCESS_KEY or not SECRET_KEY:
    print("Error: QINIU_ACCESS_KEY and QINIU_SECRET_KEY required in .env.local")
    print("Add them to neox/.env.local or the root .env.local")
    sys.exit(1)


def upload_token(bucket, key):
    """Generate Qiniu upload token."""
    policy = json.dumps({
        "scope": f"{bucket}:{key}",
        "deadline": 9999999999,
    }).encode()
    encoded = base64.urlsafe_b64encode(policy).decode()
    sign = hmac.new(SECRET_KEY.encode(), encoded.encode(), hashlib.sha1).digest()
    encoded_sign = base64.urlsafe_b64encode(sign).decode()
    return f"{ACCESS_KEY}:{encoded_sign}:{encoded}"


def upload_file(filepath, key):
    """Upload a file to Qiniu."""
    token = upload_token(BUCKET, key)
    boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
    with open(filepath, 'rb') as f:
        file_data = f.read()

    body = (
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="token"\r\n\r\n'
        f'{token}\r\n'
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="key"\r\n\r\n'
        f'{key}\r\n'
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="file"; filename="{os.path.basename(filepath)}"\r\n'
        f'Content-Type: text/html\r\n\r\n'
    ).encode() + file_data + f'\r\n--{boundary}--\r\n'.encode()

    req = urllib.request.Request(
        'https://up.qiniup.com',
        data=body,
        headers={'Content-Type': f'multipart/form-data; boundary={boundary}'},
        method='POST'
    )
    try:
        resp = urllib.request.urlopen(req)
        result = json.loads(resp.read())
        url = f"https://{CDN_DOMAIN}/{key}"
        print(f"  ✓ {url}")
        return url
    except urllib.error.HTTPError as e:
        print(f"  ✗ Upload failed: {e.code} {e.read().decode()}")
        return None


if __name__ == '__main__':
    docs_dir = os.path.join(os.path.dirname(__file__), 'docs', 'appstore')
    pages = [
        ('privacy-policy.html', 'neox/privacy-policy.html'),
        ('terms-of-service.html', 'neox/terms-of-service.html'),
        ('support.html', 'neox/support.html'),
    ]

    print(f"Uploading to {CDN_DOMAIN}...")
    urls = []
    for filename, cdn_key in pages:
        filepath = os.path.join(docs_dir, filename)
        if os.path.exists(filepath):
            url = upload_file(filepath, cdn_key)
            if url:
                urls.append(url)
        else:
            print(f"  ✗ Not found: {filepath}")

    print(f"\nUploaded {len(urls)}/{len(pages)} pages:")
    for url in urls:
        print(f"  {url}")

    print("\nApp Store Connect URLs:")
    print(f"  Privacy Policy: https://{CDN_DOMAIN}/neox/privacy-policy.html")
    print(f"  Terms of Service: https://{CDN_DOMAIN}/neox/terms-of-service.html")
    print(f"  Support: https://{CDN_DOMAIN}/neox/support.html")
