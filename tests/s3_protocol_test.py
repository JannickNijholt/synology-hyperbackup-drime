"""Checks the S3 behaviour Hyper Backup depends on, against a running bridge.

Usage: python3 s3_protocol_test.py ENDPOINT ACCESS_KEY SECRET_KEY CA_CERT

Each check is a known Hyper Backup requirement or a data-safety property of the
bridge. See docs/research.md for where each one comes from.
"""
import base64
import concurrent.futures as cf
import hashlib
import os
import socket
import ssl
import sys
import time
from urllib.parse import urlparse

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

ENDPOINT, ACCESS_KEY, SECRET_KEY, CA_CERT = sys.argv[1:5]
BUCKET = "protocol-test"
failures = 0


def client(region="us-east-1"):
    return boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
        region_name=region,
        verify=CA_CERT,
        config=Config(
            s3={"addressing_style": "path"},
            signature_version="s3v4",
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
            retries={"max_attempts": 1},
        ),
    )


def check(name, ok, detail=""):
    global failures
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail and not ok else ''}")
    if not ok:
        failures += 1


def md5_b64(data):
    return base64.b64encode(hashlib.md5(data).digest()).decode()


def eventually(fn, timeout=20):
    """Polls fn until it returns (True, ...) or the timeout passes.

    The bridge writes straight to the key on Drime, so until it has finished
    tearing down an aborted upload (well under a second on a fast backend,
    longer on a real API) readers can still see the in-flight data.
    """
    deadline = time.time() + timeout
    while True:
        ok, detail = fn()
        if ok or time.time() > deadline:
            return ok, detail
        time.sleep(0.5)


def interrupted_put(key, promised, sent):
    """Send a signed-looking PUT that dies part way through the body."""
    url = urlparse(ENDPOINT)
    ctx = ssl.create_default_context(cafile=CA_CERT)
    raw = socket.create_connection((url.hostname, url.port))
    s = ctx.wrap_socket(raw, server_hostname=url.hostname)
    # Presign so the request is authorised; the body is then cut short.
    presigned = s3.generate_presigned_url("put_object", Params={"Bucket": BUCKET, "Key": key}, ExpiresIn=60)
    path = presigned[len(ENDPOINT):]
    s.sendall(f"PUT {path} HTTP/1.1\r\nHost: {url.netloc}\r\nContent-Length: {promised}\r\n\r\n".encode())
    s.sendall(os.urandom(sent))
    s.close()


s3 = client()
print(f"S3 protocol checks against {ENDPOINT}")

try:
    s3.create_bucket(Bucket=BUCKET)
except ClientError as e:
    if e.response["Error"]["Code"] not in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
        raise

check("ListBuckets shows the bucket", BUCKET in [b["Name"] for b in s3.list_buckets()["Buckets"]])
check("HeadBucket", s3.head_bucket(Bucket=BUCKET)["ResponseMetadata"]["HTTPStatusCode"] == 200)
try:
    s3.get_bucket_location(Bucket=BUCKET)
    check("GetBucketLocation (in Hyper Backup's IAM policy)", True)
except ClientError as e:
    check("GetBucketLocation (in Hyper Backup's IAM policy)", False, str(e))

for region in ("eu-central-1", "auto"):
    try:
        client(region).list_objects(Bucket=BUCKET)
        check(f"SigV4 signed for region '{region}' accepted", True)
    except ClientError as e:
        check(f"SigV4 signed for region '{region}' accepted", False, str(e))

data = os.urandom(5 * 1024 * 1024 + 123)
r = s3.put_object(Bucket=BUCKET, Key="Pool/0/0.bucket", Body=data, ContentMD5=md5_b64(data))
check("PutObject returns the MD5 ETag", r["ETag"].strip('"') == hashlib.md5(data).hexdigest(), r["ETag"])

try:
    s3.put_object(Bucket=BUCKET, Key="Pool/0/bad", Body=data, ContentMD5=md5_b64(b"something else"))
    check("PutObject with a wrong Content-MD5 is rejected", False, "was accepted")
except ClientError as e:
    check("PutObject with a wrong Content-MD5 is rejected", e.response["Error"]["Code"] == "BadDigest", str(e))
keys = [o["Key"] for o in s3.list_objects(Bucket=BUCKET).get("Contents", [])]
check("...and nothing was stored for it", "Pool/0/bad" not in keys, str(keys))

got = s3.get_object(Bucket=BUCKET, Key="Pool/0/0.bucket", Range="bytes=1000-1999")["Body"].read()
check("Range GET", got == data[1000:2000])
listed = s3.list_objects(Bucket=BUCKET, Prefix="Pool/", Delimiter="/")
check("ListObjects (v1) with delimiter", [p["Prefix"] for p in listed.get("CommonPrefixes", [])] == ["Pool/0/"])

parts = [os.urandom(5 * 1024 * 1024) for _ in range(4)] + [os.urandom(4321)]
want_etag = hashlib.md5(b"".join(hashlib.md5(p).digest() for p in parts)).hexdigest() + f"-{len(parts)}"


def multipart(key, workers):
    up = s3.create_multipart_upload(Bucket=BUCKET, Key=key)["UploadId"]

    def send(i):
        res = s3.upload_part(Bucket=BUCKET, Key=key, UploadId=up, PartNumber=i + 1, Body=parts[i],
                             ContentMD5=md5_b64(parts[i]))
        return {"PartNumber": i + 1, "ETag": res["ETag"]}

    order = list(reversed(range(len(parts)))) if workers > 1 else list(range(len(parts)))
    with cf.ThreadPoolExecutor(workers) as ex:
        done = sorted(ex.map(send, order), key=lambda p: p["PartNumber"])
    uploads = [u["UploadId"] for u in s3.list_multipart_uploads(Bucket=BUCKET).get("Uploads", [])]
    listed_parts = len(s3.list_parts(Bucket=BUCKET, Key=key, UploadId=up).get("Parts", []))
    res = s3.complete_multipart_upload(Bucket=BUCKET, Key=key, UploadId=up, MultipartUpload={"Parts": done})
    return up in uploads, listed_parts, res.get("ETag", "").strip('"')


for workers in (1, 4):
    label = "in order" if workers == 1 else "parallel, out of order"
    key = f"Pool/1/{workers}.bucket"
    in_list, n_parts, etag = multipart(key, workers)
    check(f"multipart ({label}): ListMultipartUploads shows the upload", in_list)
    check(f"multipart ({label}): ListParts", n_parts == len(parts), str(n_parts))
    # Hyper Backup fails with "ETag is empty" if this is blank.
    check(f"multipart ({label}): CompleteMultipartUpload ETag is set and correct", etag == want_etag, etag)
    body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    check(f"multipart ({label}): content matches", body == b"".join(parts))

up = s3.create_multipart_upload(Bucket=BUCKET, Key="Pool/2/aborted")["UploadId"]
s3.upload_part(Bucket=BUCKET, Key="Pool/2/aborted", UploadId=up, PartNumber=1, Body=parts[0])
s3.abort_multipart_upload(Bucket=BUCKET, Key="Pool/2/aborted", UploadId=up)
keys = [o["Key"] for o in s3.list_objects(Bucket=BUCKET).get("Contents", [])]
check("aborted multipart upload leaves no object", "Pool/2/aborted" not in keys, str(keys))

def fresh_absent():
    keys = [o["Key"] for o in s3.list_objects(Bucket=BUCKET).get("Contents", [])]
    return "Pool/3/fresh.bucket" not in keys, str(keys)


def previous_intact():
    try:
        return s3.get_object(Bucket=BUCKET, Key="Pool/0/0.bucket")["Body"].read() == data, "content differs"
    except Exception as e:  # noqa: BLE001 - mid-teardown reads can fail in several ways
        return False, f"{type(e).__name__}: {e}"


interrupted_put("Pool/3/fresh.bucket", 8 * 1024 * 1024, 2 * 1024 * 1024)
check("interrupted upload stores nothing", *eventually(fresh_absent))

interrupted_put("Pool/0/0.bucket", 8 * 1024 * 1024, 2 * 1024 * 1024)
check("interrupted overwrite keeps the previous object intact", *eventually(previous_intact))

new = os.urandom(2048)
s3.put_object(Bucket=BUCKET, Key="Pool/0/0.bucket", Body=new)
check("overwrite", s3.get_object(Bucket=BUCKET, Key="Pool/0/0.bucket")["Body"].read() == new)

keys = [o["Key"] for o in s3.list_objects(Bucket=BUCKET).get("Contents", [])]
s3.delete_objects(Bucket=BUCKET, Delete={"Objects": [{"Key": k} for k in keys]})
check("DeleteObjects", not s3.list_objects(Bucket=BUCKET).get("Contents"))
try:
    s3.get_object(Bucket=BUCKET, Key="Pool/0/0.bucket")
    check("GET of a deleted object returns NoSuchKey", False, "object still readable")
except ClientError as e:
    check("GET of a deleted object returns NoSuchKey", e.response["Error"]["Code"] == "NoSuchKey", str(e))

bad = boto3.client("s3", endpoint_url=ENDPOINT, aws_access_key_id=ACCESS_KEY, aws_secret_access_key="wrong",
                   region_name="us-east-1", verify=CA_CERT, config=Config(s3={"addressing_style": "path"}))
try:
    bad.list_buckets()
    check("wrong secret key is refused", False, "request succeeded")
except ClientError as e:
    check("wrong secret key is refused", e.response["ResponseMetadata"]["HTTPStatusCode"] == 403, str(e))

try:
    s3.delete_bucket(Bucket=BUCKET)
except ClientError as e:
    # Failed uploads can leave empty folders behind in the backend. They hold
    # no data and S3 clients never see them, but they block DeleteBucket.
    if e.response["Error"]["Code"] != "BucketNotEmpty":
        raise
    print(f"  note  bucket '{BUCKET}' kept: empty folders from the interrupted uploads remain")
print()
print("All protocol checks passed." if failures == 0 else f"{failures} protocol check(s) failed.")
sys.exit(1 if failures else 0)
