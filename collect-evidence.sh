#!/usr/bin/env bash
# Collects the evidence for the CV hosting lab into evidence.txt.
#
# Usage: ./collect-evidence.sh <bucket> <ec2-address> <lambda-address>
#   e.g. ./collect-evidence.sh cv-23l-3029 http://203.0.113.10 https://abc123.lambda-url.eu-north-1.on.aws
#
# Every section starts with a line "== name ==". If a command fails, the section
# says so and the script carries on with the next one. Needs the AWS CLI, curl
# and credentials that can read (not change) the resources.
#
# Resource names follow the lab naming rule. ROLL and the Region can be
# overridden from the environment (ROLL=23l-3029, AWS_REGION / AWS_DEFAULT_REGION).

set -u
set -o pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <bucket> <ec2-address> <lambda-address>" >&2
  exit 1
fi

BUCKET=$1
EC2_ADDR=$2
LAMBDA_ADDR=$3

ROLL="${ROLL:-23l-3029}"
EC2_NAME="cv-ec2-${ROLL}"
EC2_ROLE="cv-ec2-role-${ROLL}"
FUNC="cv-func-${ROLL}"
LAMBDA_ROLE="cv-lambda-role-${ROLL}"
LOG_GROUP="/aws/lambda/${FUNC}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"

cd "$(dirname "$0")" || exit 1
OUT="evidence.txt"
: > "$OUT"

# section <name> <function>: run the function, add its output under "== name ==",
# and note a failure instead of stopping.
section() {
  local name=$1 fn=$2 tmp rc
  tmp=$(mktemp)
  "$fn" > "$tmp" 2>&1
  rc=$?
  {
    echo "== ${name} =="
    cat "$tmp"
    [ "$rc" -eq 0 ] || echo "NOTE: this section failed (exit ${rc}); see the message above."
    echo
  } >> "$OUT"
  rm -f "$tmp"
}

# Keeps a bare address usable: adds a scheme if missing and drops a trailing slash.
base_url() {
  local url=$1 default_scheme=$2
  case "$url" in
    http://*|https://*) ;;
    *) url="${default_scheme}://${url}" ;;
  esac
  echo "${url%/}"
}

# One line per URL: status code and content type.
probe() {
  local url=$1 line rc
  line=$(curl -s -o /dev/null --max-time 15 \
    -w 'status=%{http_code} content_type=%{content_type}' "$url")
  rc=$?
  echo "${url}  ${line}"
  return "$rc"
}

# The footer the server filled in, to show which side served the page.
footer() {
  local url=$1 text
  text=$(curl -s --max-time 15 "$url/" | grep -o 'Hosted on: [^<]*' | head -n 1)
  echo "${url}/  footer='${text:-<not found>}'"
}

# The instance of this lab, by its Name tag (ignores terminated ones).
instance_ids() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${EC2_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# Prints the inline policies of a role in full.
role_inline_policies() {
  local role=$1 names p rc=0
  names=$(aws iam list-role-policies --role-name "$role" \
    --query 'PolicyNames[]' --output text) || return 1
  [ -n "$names" ] || { echo "(no inline policies)"; return 0; }
  for p in $names; do
    echo "-- inline policy: ${p}"
    aws iam get-role-policy --role-name "$role" --policy-name "$p" || rc=1
  done
  return "$rc"
}

# Prints the managed policies attached to a role.
role_attached_policies() {
  echo "-- attached managed policies of ${1}"
  aws iam list-attached-role-policies --role-name "$1"
}

s_caller()        { aws sts get-caller-identity; }
s_public_access() { aws s3api get-public-access-block --bucket "$BUCKET"; }
s_versioning()    { aws s3api get-bucket-versioning --bucket "$BUCKET"; }
# The whole bucket, so anything outside site/ would show up too.
s_objects()       { aws s3 ls "s3://${BUCKET}/" --recursive; }

s_ec2_policy() {
  local rc=0
  role_attached_policies "$EC2_ROLE" || rc=1
  role_inline_policies "$EC2_ROLE" || rc=1
  return "$rc"
}

s_lambda_policy() {
  local rc=0
  role_attached_policies "$LAMBDA_ROLE" || rc=1
  role_inline_policies "$LAMBDA_ROLE" || rc=1
  return "$rc"
}

s_security_group() {
  local ids groups
  local -a id_list group_list
  ids=$(instance_ids) || return 1
  [ -n "$ids" ] || { echo "no instance named ${EC2_NAME} found"; return 1; }
  read -ra id_list <<< "$ids"
  groups=$(aws ec2 describe-instances --instance-ids "${id_list[@]}" \
    --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text) || return 1
  read -ra group_list <<< "$groups"
  aws ec2 describe-security-groups --group-ids "${group_list[@]}" \
    --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Inbound:IpPermissions}'
}

s_instance() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${EC2_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,Type:InstanceType,State:State.Name,PublicIp:PublicIpAddress,HttpTokens:MetadataOptions.HttpTokens,InstanceProfile:IamInstanceProfile.Arn,Tags:Tags}'
}

s_endpoints() {
  local ec2 lam s3 rc=0
  ec2=$(base_url "$EC2_ADDR" http)
  lam=$(base_url "$LAMBDA_ADDR" https)
  s3="https://${BUCKET}.s3${REGION:+.${REGION}}.amazonaws.com/site/index.html"

  echo "-- EC2"
  footer "$ec2" || rc=1
  for path in / /style.css /cv.pdf; do probe "${ec2}${path}" || rc=1; done
  echo "-- Lambda"
  footer "$lam" || rc=1
  for path in / /style.css /cv.pdf /anything; do probe "${lam}${path}" || rc=1; done
  echo "-- S3 direct (expected: 403)"
  probe "$s3" || rc=1
  return "$rc"
}

s_lambda_logs() { aws logs tail "$LOG_GROUP" --since 3d --format short | tail -n 20; }

s_log_retention() {
  aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query 'logGroups[].{logGroupName:logGroupName,retentionInDays:retentionInDays}'
}

section caller          s_caller
section public-access  s_public_access
section versioning     s_versioning
section objects        s_objects
section ec2-policy     s_ec2_policy
section lambda-policy  s_lambda_policy
section security-group s_security_group
section instance       s_instance
section endpoints      s_endpoints
section lambda-logs    s_lambda_logs
section log-retention  s_log_retention

echo DONE
