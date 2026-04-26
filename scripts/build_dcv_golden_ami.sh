#!/usr/bin/env bash
set -euo pipefail

# GOLDEN AMI BUILDER BLOCK
# LAUNCHES ONE TEMPORARY ON-DEMAND DCV BUILDER, CONFIGURES IT WITH ANSIBLE, SANITIZES IT, CREATES AN AMI, THEN TERMINATES THE BUILDER.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
AMI_NAME=""
BUILDER_INSTANCE_TYPE=""
SKIP_CONFIGURE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      AMI_NAME="$2"
      shift 2
      ;;
    --instance-type)
      BUILDER_INSTANCE_TYPE="$2"
      shift 2
      ;;
    --skip-configure)
      SKIP_CONFIGURE=true
      shift
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: $0 [--name AMI_NAME] [--instance-type TYPE] [--skip-configure] [--env-file PATH]" >&2
      exit 1
      ;;
  esac
done

source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/validate_env.sh" --scope=ansible "$ENV_FILE"

if [[ -z "$AMI_NAME" ]]; then
  AMI_NAME="${PROJECT_NAME}-dcv-golden-$(date +%Y%m%d%H%M%S)"
fi

if [[ -z "$BUILDER_INSTANCE_TYPE" ]]; then
  BUILDER_INSTANCE_TYPE="$DCV_INSTANCE_TYPE"
fi

cleanup_instance_id=""
cleanup() {
  if [[ -n "$cleanup_instance_id" ]]; then
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$cleanup_instance_id" >/dev/null || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR/terraform"

if ! terraform output -raw vpn_public_ip >/dev/null 2>&1; then
  echo "ERROR: Terraform outputs are missing. Run ./create.sh or ./scripts/terraform_apply.sh first." >&2
  exit 1
fi

vpn_public_ip="$(terraform output -raw vpn_public_ip)"

private_subnet_id="$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=cidr-block,Values=$PRIVATE_SUBNET_CIDR" \
  --query 'Subnets[0].SubnetId' \
  --output text)"

dcv_sg_id="$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters "Name=group-name,Values=${PROJECT_NAME}-dcv-sg" "Name=tag:Project,Values=$PROJECT_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)"

ubuntu_ami_id="$(aws ec2 describe-images \
  --region "$AWS_REGION" \
  --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' 'Name=virtualization-type,Values=hvm' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text)"

if [[ -z "$private_subnet_id" || "$private_subnet_id" == "None" || -z "$dcv_sg_id" || "$dcv_sg_id" == "None" || -z "$ubuntu_ami_id" || "$ubuntu_ami_id" == "None" ]]; then
  echo "ERROR: Could not resolve builder subnet, security group, or Ubuntu AMI." >&2
  exit 1
fi

echo "Launching temporary On-Demand DCV AMI builder in $private_subnet_id"
builder_instance_id="$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$ubuntu_ami_id" \
  --instance-type "$BUILDER_INSTANCE_TYPE" \
  --subnet-id "$private_subnet_id" \
  --security-group-ids "$dcv_sg_id" \
  --key-name "$SSH_KEY_NAME" \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${DCV_ROOT_VOLUME_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true}" \
  --metadata-options 'HttpEndpoint=enabled,HttpTokens=required' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=${PROJECT_NAME}},{Key=ManagedBy,Value=golden-ami-builder},{Key=Name,Value=${PROJECT_NAME}-dcv-ami-builder},{Key=Role,Value=dcv-ami-builder}]" \
  --query 'Instances[0].InstanceId' \
  --output text)"

cleanup_instance_id="$builder_instance_id"
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$builder_instance_id"

builder_private_ip="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$builder_instance_id" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)"

tmp_inventory="$(mktemp "$ROOT_DIR/ansible/inventories/golden-builder.XXXXXX.yml")"
inventory_ssh_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
inventory_proxy_command="ssh $inventory_ssh_args -i $SSH_PRIVATE_KEY_PATH -W %h:%p ubuntu@$vpn_public_ip"

cat >"$tmp_inventory" <<INVENTORY
all:
  children:
    dcv:
      hosts:
        dcv-golden-builder:
          ansible_host: $builder_private_ip
          ansible_user: ubuntu
          ansible_ssh_private_key_file: $SSH_PRIVATE_KEY_PATH
          ansible_ssh_common_args: >-
            $inventory_ssh_args -o IdentityFile=$SSH_PRIVATE_KEY_PATH -o ProxyCommand='$inventory_proxy_command'
INVENTORY

if [[ "$SKIP_CONFIGURE" != "true" ]]; then
  cd "$ROOT_DIR"
  export ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg"
  ansible-playbook -i "$tmp_inventory" ansible/playbooks/dcv_only.yml
fi

echo "Sanitizing builder before AMI capture"
ssh $inventory_ssh_args -i "$SSH_PRIVATE_KEY_PATH" -o ProxyCommand="$inventory_proxy_command" "ubuntu@$builder_private_ip" \
  "sudo bash -s" <<'REMOTE_SANITIZE'
set -euo pipefail
systemctl stop dcvserver 2>/dev/null || true
userdel -r user1 2>/dev/null || true
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
cloud-init clean --logs 2>/dev/null || true
rm -rf /tmp/* /var/tmp/*
REMOTE_SANITIZE

echo "Stopping builder for AMI capture"
aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$builder_instance_id" >/dev/null
aws ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$builder_instance_id"

ami_id="$(aws ec2 create-image \
  --region "$AWS_REGION" \
  --instance-id "$builder_instance_id" \
  --name "$AMI_NAME" \
  --description "${PROJECT_NAME} sanitized golden DCV image" \
  --tag-specifications "ResourceType=image,Tags=[{Key=Project,Value=${PROJECT_NAME}},{Key=Role,Value=dcv-golden-ami},{Key=ManagedBy,Value=golden-ami-builder}]" \
  --query 'ImageId' \
  --output text)"

echo "Waiting for AMI $ami_id"
aws ec2 wait image-available --region "$AWS_REGION" --image-ids "$ami_id"

if grep -q '^AMI_ID=' "$ENV_FILE"; then
  sed -i "s#^AMI_ID=.*#AMI_ID=${ami_id}#" "$ENV_FILE"
else
  printf '\nAMI_ID=%s\n' "$ami_id" >>"$ENV_FILE"
fi

if grep -q '^DCV_USE_SPOT=' "$ENV_FILE"; then
  sed -i 's#^DCV_USE_SPOT=.*#DCV_USE_SPOT=true#' "$ENV_FILE"
else
  printf 'DCV_USE_SPOT=true\n' >>"$ENV_FILE"
fi

echo "Terminating temporary builder $builder_instance_id"
aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$builder_instance_id" >/dev/null
aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$builder_instance_id"
cleanup_instance_id=""
rm -f "$tmp_inventory"

echo "Golden AMI ready: $ami_id"
echo "Updated $ENV_FILE with AMI_ID and DCV_USE_SPOT=true"
