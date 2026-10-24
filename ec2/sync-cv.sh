#!/bin/bash
# Copies the site/ prefix of the CV bucket into the web root, then fills in the
# "Hosted on" footer with EC2 and the instance ID. Run by cv-sync.timer.
# Credentials come from the instance role (IMDSv2); no keys are used anywhere.
set -u

[ -f /etc/cv-sync.env ] && . /etc/cv-sync.env
BUCKET="${BUCKET:?BUCKET is not set}"
PREFIX="${PREFIX:-site/}"
WEBROOT="${WEBROOT:-/var/www/html}"
STAGE="${STAGE:-/var/lib/cv-stage}"
LOG="${LOG:-/var/log/cv-sync.log}"

imds() {
  local token
  token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 1
  curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

INSTANCE_ID=$(imds instance-id) || { log "sync=FAILED reason=no-instance-id"; exit 1; }
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(imds placement/region)}"

mkdir -p "$STAGE" "$WEBROOT"

if aws s3 sync "s3://${BUCKET}/${PREFIX}" "$STAGE" --delete --only-show-errors \
   && [ -f "$STAGE/index.html" ]; then
  # Publish from the clean copy so the placeholder is always replaced from scratch.
  cp -a "$STAGE"/. "$WEBROOT"/
  sed -i "s|{{HOSTED_ON}}|EC2 ${INSTANCE_ID}|g" "$WEBROOT/index.html"
  log "sync=OK instance=${INSTANCE_ID} bucket=${BUCKET}"
else
  log "sync=FAILED instance=${INSTANCE_ID} bucket=${BUCKET}"
  exit 1
fi
