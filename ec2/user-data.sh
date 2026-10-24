#!/bin/bash
# EC2 user data for the CV site (Amazon Linux 2023).
# Edit BUCKET below if your bucket name has extra digits on the end.
# The sync script is embedded here between the SYNC markers; it is identical to ec2/sync-cv.sh.
set -eux
exec > >(tee /var/log/user-data.log) 2>&1

BUCKET="cv-23l-3029"
PREFIX="site/"

dnf install -y httpd
# Send plain content types (text/css, text/html) without a charset suffix; the page declares UTF-8 itself.
echo 'AddDefaultCharset Off' > /etc/httpd/conf.d/cv.conf
systemctl enable --now httpd

cat > /etc/cv-sync.env <<ENV
BUCKET=$BUCKET
PREFIX=$PREFIX
ENV

cat > /usr/local/bin/sync-cv.sh <<'SYNC'
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
SYNC
chmod 755 /usr/local/bin/sync-cv.sh

touch /var/log/cv-sync.log
chmod 644 /var/log/cv-sync.log

# AL2023 has no cron, so a systemd timer runs the sync every 2 minutes.
cat > /etc/systemd/system/cv-sync.service <<'UNIT'
[Unit]
Description=Sync CV site from S3
After=network-online.target httpd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
UNIT

cat > /etc/systemd/system/cv-sync.timer <<'UNIT'
[Unit]
Description=Run the CV sync every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now cv-sync.timer

# First sync right away (do not fail the whole boot if the role is not ready yet; the timer retries)
/usr/local/bin/sync-cv.sh || true
