"""CV site served from a Lambda function URL.

Files are read from a private S3 bucket using the function's execution role.
BUCKET and PREFIX come from environment variables; nothing is hard-coded here.
"""
import base64
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ["PREFIX"]

# path -> (S3 file name, content type, binary?)
ROUTES = {
    "/": ("index.html", "text/html", False),
    "/index.html": ("index.html", "text/html", False),
    "/style.css": ("style.css", "text/css", False),
    "/cv.pdf": ("cv.pdf", "application/pdf", True),
}

NOT_FOUND_HTML = (
    "<!DOCTYPE html><html><head><title>404 Not Found</title></head>"
    "<body><h1>404</h1><p>Page not found.</p></body></html>"
)


def respond(status, content_type, body, headers=None, binary=False):
    out = {
        "statusCode": status,
        "headers": {"Content-Type": content_type, **(headers or {})},
    }
    if binary:
        out["body"] = base64.b64encode(body).decode("ascii")
        out["isBase64Encoded"] = True
    else:
        out["body"] = body
        out["isBase64Encoded"] = False
    return out


def lambda_handler(event, context):
    start = time.perf_counter()
    path = event.get("rawPath") or "/"
    result = handle(path, context)
    print(json.dumps({
        "fn": context.function_name,
        "path": path,
        "status": result["statusCode"],
        "ms": round((time.perf_counter() - start) * 1000, 1),
    }))
    return result


def handle(path, context):
    route = ROUTES.get(path)
    if route is None:
        return respond(404, "text/html", NOT_FOUND_HTML)

    name, content_type, binary = route
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=PREFIX + name)
        data = obj["Body"].read()
    except ClientError:
        return respond(502, "text/html",
                       "<h1>502</h1><p>Could not load the page.</p>")

    if binary:
        return respond(200, content_type, data, binary=True)

    text = data.decode("utf-8")
    headers = {}
    if name == "index.html":
        text = text.replace("{{HOSTED_ON}}", "Lambda " + context.function_name)
        headers["Cache-Control"] = "max-age=60"
    return respond(200, content_type, text, headers)
