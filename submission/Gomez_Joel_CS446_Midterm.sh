#!/usr/bin/env bash

# =============================================================================
# CS 446 Midterm — OpenCSUSM
# Name: Joel Gomez
# Campus ID: 201381796
# Lane: cpu
# ===============================================================
#
# WHY I CHOSE THIS LANE
# I chose the CPU lane and selected the c7i.2xlarge instance.
# I chose this lane specifcally because it was slightly cheaper but also had enough memory and power for its price
# it was also able to run the Qwen model I chose with more than enough space.
# this lane all together costs about $0.3570 and it can specifically buy 280 hours using 100$.
# I specifically chose to run qwen2.5:0.5b because it is able to use CPU and 
# it was the right choice for my setup because it used 
# minimal amount of memory and had less amount of inputs to run within the test's time limit
#
# ===============================================================
# Usage:
#   bash opencsusm.sh 1   # selected lane and live price
#   bash opencsusm.sh 2   # create temporary key, firewall, and EC2 instance
#   bash opencsusm.sh 3   # install Ollama over SSH
#   bash opencsusm.sh 4   # pull model and verify the private API
#   bash opencsusm.sh 5   # print tunnel command for a second terminal
#   bash opencsusm.sh 6   # send the graded prompt through the tunnel
#   bash opencsusm.sh 7   # stop EC2; disk still exists
#   bash opencsusm.sh 8   # terminate and delete; success prints nothing
#
# =============================================================================

set -Eeuo pipefail

# ------------------------------------------------- MY CHOICES
AWS_REGION="${AWS_REGION:-us-east-1}"
MODE="cpu"
OWNER="gomez"
INSTANCE_TYPE="c7i.2xlarge"
RATE="0.3570"
ENGINE="Ollama"
MODEL="qwen2.5:0.5b"
REMOTE_PORT="11434"
LOCAL_PORT="11434"
SSH_USER="ubuntu"
DISK_GB="40"
AMI_PARAMETER="/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
INSTANCE_NAME="opencsusm-$OWNER"
PROJECT_TAG="OpenCSUSM"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_FILE="$SCRIPT_DIR/opencsusm_state.env"

# ======================================== PART 2 — THE COMMANDS
# State populated by Stage 2 and reused by Stages 3-8.
ACCOUNT_ID=""
INSTANCE_ID=""
PUBLIC_IP=""
PUBLIC_DNS=""
SG_ID=""
KEY_NAME=""
KEY_FILE=""
KNOWN_HOSTS_FILE=""
SUBNET_ID=""
AMI_ID=""
STAGE2_COMPLETE=false

# Displays the available stages when the script is run incorrectly or without a stage number.
usage() {
  cat <<'EOF'
Usage: bash opencsusm.sh STAGE

Stages:
  1  Show the CPU lane and live instance price
  2  Launch EC2 with a temporary SSH key and port 22 only
  3  Install Ollama over SSH
  4  Pull qwen2.5:0.5b and verify Ollama inside EC2
  5  Print the required SSH tunnel command
  6  Send "I am John" through the tunnel
  7  Stop EC2 (the EBS disk still costs money)
  8  Terminate and delete all project resources
EOF
}

# Prints an error message to standard error and immediately stops the script.
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Checks that every required command-line program is installed before continuing.
require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || \
      die "Required command not found: $command_name"
  done
}

# Returns the account ID associated with the AWS credentials currently used by the AWS CLI.
current_account_id() {
  aws sts get-caller-identity --query Account --output text
}

# Restores the saved deployment values and verifies that the AWS account and region have not changed.
load_state() {
  [[ -f "$STATE_FILE" ]] || \
    die "Deployment state not found. Run Stage 2 first."

  source "$STATE_FILE"

  local active_account
  active_account=$(current_account_id)
  [[ "$active_account" == "$ACCOUNT_ID" ]] || \
    die "AWS account changed. State belongs to $ACCOUNT_ID, but AWS CLI is using $active_account."

  [[ "$AWS_REGION" == "$STATE_AWS_REGION" ]] || \
    die "Region changed. State uses $STATE_AWS_REGION; current setting is $AWS_REGION."

  AWS_REGION="$STATE_AWS_REGION"
}

# Saves the deployment information so later stages can find the same AWS resources.
save_state() {
  {
    printf 'ACCOUNT_ID=%q\n' "$ACCOUNT_ID"
    printf 'STATE_AWS_REGION=%q\n' "$AWS_REGION"
    printf 'MODE=%q\n' "$MODE"
    printf 'OWNER=%q\n' "$OWNER"
    printf 'INSTANCE_TYPE=%q\n' "$INSTANCE_TYPE"
    printf 'RATE=%q\n' "$RATE"
    printf 'ENGINE=%q\n' "$ENGINE"
    printf 'MODEL=%q\n' "$MODEL"
    printf 'REMOTE_PORT=%q\n' "$REMOTE_PORT"
    printf 'LOCAL_PORT=%q\n' "$LOCAL_PORT"
    printf 'SSH_USER=%q\n' "$SSH_USER"
    printf 'DISK_GB=%q\n' "$DISK_GB"
    printf 'AMI_PARAMETER=%q\n' "$AMI_PARAMETER"
    printf 'INSTANCE_NAME=%q\n' "$INSTANCE_NAME"
    printf 'PROJECT_TAG=%q\n' "$PROJECT_TAG"
    printf 'INSTANCE_ID=%q\n' "$INSTANCE_ID"
    printf 'PUBLIC_IP=%q\n' "$PUBLIC_IP"
    printf 'PUBLIC_DNS=%q\n' "$PUBLIC_DNS"
    printf 'SG_ID=%q\n' "$SG_ID"
    printf 'KEY_NAME=%q\n' "$KEY_NAME"
    printf 'KEY_FILE=%q\n' "$KEY_FILE"
    printf 'KNOWN_HOSTS_FILE=%q\n' "$KNOWN_HOSTS_FILE"
    printf 'SUBNET_ID=%q\n' "$SUBNET_ID"
    printf 'AMI_ID=%q\n' "$AMI_ID"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# Builds the secure SSH options used to connect to the EC2 instance.
build_ssh_options() {
  [[ -f "$KEY_FILE" ]] || die "Temporary SSH key not found: $KEY_FILE"
  chmod 400 "$KEY_FILE"

  SSH_OPTIONS=(
    -i "$KEY_FILE"
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=30
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE"
  )
}

# Repeatedly attempts an SSH connection until the EC2 operating system is ready.
wait_for_ssh() {
  local attempt
  build_ssh_options

  for attempt in {1..36}; do
    if ssh "${SSH_OPTIONS[@]}" "$SSH_USER@$PUBLIC_IP" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  die "SSH did not become ready within 180 seconds."
}

# --- 1 ------------------------------------------------- selected lane and live price

stage_1() {
  # This command stops Stage 1 immediately if either the AWS CLI or Python 3 is unavailable.
  require_commands aws python3

  # This command creates local variables for the quota values and pricing response so they do not affect other stages.
  local gvt_quota standard_quota
  local price_json price

  # This command retrieves the account ID associated with the AWS credentials currently active in the CLI.
  ACCOUNT_ID=$(current_account_id)

  # This command displays the AWS account, region, selected execution lane, and chosen EC2 and model configuration.
  echo "AWS account: $ACCOUNT_ID"
  echo "Region: $AWS_REGION"
  echo "Selected lane: $MODE"
  echo "Configuration: $INSTANCE_TYPE + $ENGINE + $MODEL"
  echo

  # This command reads the G and VT On-Demand quota in the selected region and extracts its numeric vCPU limit.
  gvt_quota=$(aws service-quotas get-service-quota \
    --region "$AWS_REGION" \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --query 'Quota.Value' \
    --output text)

  # Running On-Demand Standard instances
  gvt_standard_quota_code="L-1216C47A"

  # This command reads the Standard On-Demand quota used by C-family instances and extracts its numeric vCPU limit.
  standard_quota=$(aws service-quotas get-service-quota \
    --region "$AWS_REGION" \
    --service-code ec2 \
    --quota-code "$gvt_standard_quota_code" \
    --query 'Quota.Value' \
    --output text)

  # This command displays both quota results and explains how they affect the GPU alternative and selected CPU instance.
  echo "Service quota results:"
  echo "  Running On-Demand G and VT: $gvt_quota vCPUs"
  echo "  Running On-Demand Standard: $standard_quota vCPUs"
  echo

  echo "Quota explanation:"
  echo "  AWS reports these quotas in vCPUs instead of instances because"
  echo "  different EC2 instance sizes consume different amounts of CPU"
  echo "  capacity, allowing multiple instance sizes to share one quota."
  echo

  echo "Why this matters for my CPU lane:"
  echo "  The G and VT quota tells me whether the GPU lane is available"
  echo "  as an alternative. A g4dn.xlarge requires 4 vCPUs from that"
  echo "  quota. If the result is below 4, I would use the CPU lane or"
  echo "  request a GPU quota increase."
  echo
  echo "  My c7i.2xlarge belongs to the Standard instance families and"
  echo "  requires 8 vCPUs from the Standard On-Demand quota."
  echo

  # This command stops the script if the deployment region differs from the Virginia region used by the price lookup.
  [[ "$AWS_REGION" == "us-east-1" ]] || \
    die "This configuration expects AWS_REGION=us-east-1."

  # This command announces which EC2 instance type will be searched in the AWS pricing catalog.
  echo "Live Linux On-Demand price for $INSTANCE_TYPE:"

  # This command retrieves pricing products matching a shared Linux On-Demand c7i.2xlarge instance in Northern Virginia.
  price_json=$(aws pricing get-products \
    --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
      "Type=TERM_MATCH,Field=instanceType,Value=$INSTANCE_TYPE" \
      "Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)" \
      "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
      "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
      "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
      "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --max-results 100 \
    --query 'PriceList' \
    --output json)

  price=$(PRICE_JSON="$price_json" python3 -c '
import json
import os

# This command parses the AWS pricing response and selects the lowest matching hourly price in US dollars.
items = json.loads(os.environ["PRICE_JSON"])
prices = []

for raw_product in items:
    product = json.loads(raw_product)

    for term in product.get("terms", {}).get("OnDemand", {}).values():
        for dimension in term.get("priceDimensions", {}).values():
            if dimension.get("unit") == "Hrs":
                usd = dimension.get("pricePerUnit", {}).get("USD")

                if usd is not None:
                    prices.append(float(usd))

print(f"{min(prices):.4f}" if prices else "")
')

  # This command displays the selected instance, its live hourly price, and confirmation that Stage 1 finished.
  [[ -n "$price" ]] || \
    die "AWS Pricing returned no hourly price for $INSTANCE_TYPE."

  echo "  Instance: $INSTANCE_TYPE"
  echo "  Price: \$$price per instance-hour"
  echo
  echo "Stage 1 complete."
}

# --- 2 ---------------------------------------------------- create temporary key, firewall, and EC2 instance

stage_2() {
  require_commands aws curl ssh ssh-keygen
  [[ ! -e "$STATE_FILE" ]] || \
    die "A deployment already exists. Run Stage 8 before launching another."

  ACCOUNT_ID=$(current_account_id)

  local my_ip vpc_id deployment_suffix
  my_ip=$(curl -4 --fail --silent --show-error https://checkip.amazonaws.com | tr -d '[:space:]')
  [[ "$my_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
    die "Could not determine a valid public IPv4 address."

  vpc_id=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text)
  [[ -n "$vpc_id" && "$vpc_id" != "None" ]] || \
    die "No default VPC exists in $AWS_REGION."

  SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=default-for-az,Values=true" \
    --query 'Subnets[0].SubnetId' \
    --output text)
  [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]] || \
    die "No default subnet exists in the default VPC."

  AMI_ID=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$AMI_PARAMETER" \
    --query 'Parameter.Value' \
    --output text)

  deployment_suffix="$(date -u +%Y%m%d-%H%M%S)-$$"
  KEY_NAME="opencsusm-key-$deployment_suffix"
  KEY_FILE="$SCRIPT_DIR/$KEY_NAME.pem"
  KNOWN_HOSTS_FILE="$SCRIPT_DIR/opencsusm_known_hosts"
  SG_ID=""
  INSTANCE_ID=""
  STAGE2_COMPLETE=false

  cleanup_failed_stage_2() {
    local status=$?
    trap - EXIT INT TERM

    if [[ "$STAGE2_COMPLETE" == true && $status -eq 0 ]]; then
      return
    fi

    echo "Stage 2 failed; removing partially created resources..." >&2

    if [[ -n "$INSTANCE_ID" ]]; then
      aws ec2 terminate-instances \
        --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
        --no-cli-pager >/dev/null 2>&1 || true
      aws ec2 wait instance-terminated \
        --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
        >/dev/null 2>&1 || true
    fi

    if [[ -n "$SG_ID" ]]; then
      aws ec2 delete-security-group \
        --region "$AWS_REGION" --group-id "$SG_ID" \
        --no-cli-pager >/dev/null 2>&1 || true
    fi

    aws ec2 delete-key-pair \
      --region "$AWS_REGION" --key-name "$KEY_NAME" \
      --no-cli-pager >/dev/null 2>&1 || true

    rm -f "$KEY_FILE" "$KNOWN_HOSTS_FILE" "$STATE_FILE"
    exit "$status"
  }
  trap cleanup_failed_stage_2 EXIT INT TERM

  umask 077
  aws ec2 create-key-pair \
    --region "$AWS_REGION" \
    --key-name "$KEY_NAME" \
    --key-type rsa \
    --key-format pem \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
    --query 'KeyMaterial' \
    --output text >"$KEY_FILE"
  chmod 400 "$KEY_FILE"
  ssh-keygen -y -f "$KEY_FILE" >/dev/null 2>&1 || \
    die "AWS returned an invalid private key."

  SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --group-name "opencsusm-sg-$deployment_suffix" \
    --description "OpenCSUSM SSH only from student public IP" \
    --vpc-id "$vpc_id" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
    --query 'GroupId' \
    --output text)

  aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "$my_ip/32" \
    --no-cli-pager >/dev/null

  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --metadata-options HttpTokens=required \
    --count 1 \
    --block-device-mappings \
      "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$DISK_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Course,Value=CS446},{Key=Project,Value=$PROJECT_TAG},{Key=Owner,Value=$OWNER}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=$INSTANCE_NAME-root},{Key=Course,Value=CS446},{Key=Project,Value=$PROJECT_TAG},{Key=Owner,Value=$OWNER}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

  aws ec2 wait instance-running \
    --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  aws ec2 wait instance-status-ok \
    --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

  read -r PUBLIC_IP PUBLIC_DNS <<EOF
$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,PublicDnsName]' \
  --output text)
EOF

  [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] || \
    die "The EC2 instance received no public IPv4 address."

  : >"$KNOWN_HOSTS_FILE"
  chmod 600 "$KNOWN_HOSTS_FILE"
  save_state
  STAGE2_COMPLETE=true

  echo "Instance: $INSTANCE_ID"
  echo "Public IP: $PUBLIC_IP"
  echo "Port 22 is restricted to $my_ip/32. Port $REMOTE_PORT is not open."
}

# --- 3 ------------------------------------------- Install Ollama over SSH

stage_3() {
  require_commands aws ssh
  load_state
  wait_for_ssh

  ssh "${SSH_OPTIONS[@]}" "$SSH_USER@$PUBLIC_IP" 'bash -s' <<'REMOTE_INSTALL'
set -Eeuo pipefail
curl -fsSL https://ollama.com/install.sh | sh
REMOTE_INSTALL

  echo "Ollama installed and active on $INSTANCE_ID."
}

# --- 4 ------------------------------------------- pull model and verify the private API

stage_4() {
  require_commands aws ssh
  load_state
  wait_for_ssh

  ssh "${SSH_OPTIONS[@]}" "$SSH_USER@$PUBLIC_IP" \
    "MODEL='$MODEL' REMOTE_PORT='$REMOTE_PORT' bash -s" <<'REMOTE_MODEL'
set -Eeuo pipefail

for attempt in {1..30}; do
  if curl -fsS "http://127.0.0.1:${REMOTE_PORT}/v1/models" >/dev/null; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    echo "Ollama did not become ready." >&2
    exit 1
  fi
  sleep 2
done

ollama pull "$MODEL"
REMOTE_MODEL

  echo "$MODEL is installed. Ollama is private on EC2 port $REMOTE_PORT."
}

# --- 5 -------------------------------------------- print tunnel command for a second terminal

stage_5() {
  require_commands aws ssh
  load_state
  build_ssh_options

  echo "Open a SECOND terminal and leave this command running:"
  printf 'ssh -i %q -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=%q -N -L %q %q\n' \
    "$KEY_FILE" \
    "$KNOWN_HOSTS_FILE" \
    "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
    "$SSH_USER@$PUBLIC_IP"
  echo
  echo "Then return to the first terminal and run:"
  echo "bash opencsusm.sh 6"
}

# --- 6 --------------------------------------------------------- send the graded prompt through the tunnel

stage_6() {
  require_commands aws curl python3
  load_state

  local response reply

  response=$(curl --fail --silent --show-error \
    "http://127.0.0.1:${LOCAL_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{
      \"model\": \"$MODEL\",
      \"messages\": [
        {
          \"role\": \"system\",
          \"content\": \"Greet the user by name. Reply with the greeting only.\"
        },
        {
          \"role\": \"user\",
          \"content\": \"I am John\"
        }
      ],
      \"max_tokens\": 20,
      \"temperature\": 0
    }") || die \
      "Could not reach Ollama. Run Stage 5 in a second terminal and leave the tunnel open."

  printf '%s' "$reply" | grep -q 'John' || \
    die "The model response did not contain John."

  echo "reply: $reply"
  echo
  echo "# ============================================================================="
  echo "# STAGE 6 OUTPUT"
  echo "#"
  echo "#  mode (gpu/cpu): $MODE"
  echo "#  why: No G-instance quota required; lower-cost CPU lane."
  echo "#  instance: $INSTANCE_TYPE"
  echo "#  model: $MODEL"
  echo "#  reply: $reply"
  echo "# ============================================================================="
}

# --- 7 ------------------------------------------------------------------ Stop EC2 (the EBS disk still costs money)

stage_7() {
  require_commands aws python3
  load_state

  local instance_state
  instance_state=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

  if [[ "$instance_state" == "running" || "$instance_state" == "pending" ]]; then
    aws ec2 stop-instances \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" \
      --no-cli-pager >/dev/null
    aws ec2 wait instance-stopped \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID"
  fi

  echo "Instance $INSTANCE_ID is stopped. Compute billing stopped, but the $DISK_GB GB gp3 disk still costs about \$$(python3 -c "print(round($DISK_GB*0.08, 2))") per month until Stage 8."
}

# --- 8 ---------------------------------------------------------------- Terminate and delete all project resources

stage_8() {
  require_commands aws
  load_state

  local instance_state attempt volume_id
  instance_state=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || true)

  if [[ -n "$instance_state" && "$instance_state" != "None" && "$instance_state" != "terminated" ]]; then
    aws ec2 terminate-instances \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" \
      --no-cli-pager >/dev/null
    aws ec2 wait instance-terminated \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID"
  fi

  # The AMI normally deletes its root disk on termination. Delete any tagged,
  # detached volume that remains so Stage 8 cannot leave storage billing behind.
  while IFS= read -r volume_id; do
    [[ -n "$volume_id" && "$volume_id" != "None" ]] || continue
    aws ec2 delete-volume \
      --region "$AWS_REGION" \
      --volume-id "$volume_id" \
      --no-cli-pager >/dev/null
  done <<EOF
$(aws ec2 describe-volumes \
  --region "$AWS_REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' \
  --output text | tr '\t' '\n')
EOF

  if aws ec2 describe-security-groups \
    --region "$AWS_REGION" --group-ids "$SG_ID" \
    --no-cli-pager >/dev/null 2>&1; then
    for attempt in {1..12}; do
      if aws ec2 delete-security-group \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --no-cli-pager >/dev/null 2>&1; then
        break
      fi
      if [[ "$attempt" -eq 12 ]]; then
        die "Could not delete security group $SG_ID."
      fi
      sleep 5
    done
  fi

  aws ec2 delete-key-pair \
    --region "$AWS_REGION" \
    --key-name "$KEY_NAME" \
    --no-cli-pager >/dev/null 2>&1 || true

  rm -f "$KEY_FILE" "$KNOWN_HOSTS_FILE" "$STATE_FILE"

  # Successful Stage 8 intentionally prints nothing.
}

main() {
  [[ $# -eq 1 ]] || {
    usage
    exit 2
  }

  case "$1" in
    1) stage_1 ;;
    2) stage_2 ;;
    3) stage_3 ;;
    4) stage_4 ;;
    5) stage_5 ;;
    6) stage_6 ;;
    7) stage_7 ;;
    8) stage_8 ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"

# =============================================================================
#  STAGE 6 OUTPUT
#
#  mode (gpu/cpu): cpu
#  why: No G-instance quota required; lower-cost CPU lane.
#  instance: c7i.2xlarge
#  model: qwen2.5:0.5b
#  reply: Hello, John.
#  hours running: 0.072
#  estimated cost: $0.0257
# =============================================================================