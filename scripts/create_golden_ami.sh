#!/usr/bin/env bash
set -euo pipefail

# GOLDEN AMI CREATION ENTRY BLOCK
# CREATES A BOOT-VOLUME-ONLY AMI FROM A CONFIGURED DCV INSTANCE, THEN WRITES AMI_ID INTO .env FOR FUTURE SPOT LAUNCHES.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
DCV_INDEX=1
WAIT_FOR_AVAILABLE=true
AMI_NAME=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dcv-index)
			DCV_INDEX="$2"
			shift 2
			;;
		--name)
			AMI_NAME="$2"
			shift 2
			;;
		--no-wait)
			WAIT_FOR_AVAILABLE=false
			shift
			;;
		--env-file)
			ENV_FILE="$2"
			shift 2
			;;
		*)
			echo "ERROR: Unknown argument: $1" >&2
			echo "Usage: $0 [--dcv-index N] [--name AMI_NAME] [--no-wait] [--env-file PATH]" >&2
			exit 1
			;;
	esac
done

if [[ ! "$DCV_INDEX" =~ ^[1-9][0-9]*$ ]]; then
	echo "ERROR: --dcv-index must be a positive integer." >&2
	exit 1
fi

source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/validate_env.sh" --scope=terraform "$ENV_FILE"

if [[ -z "$AMI_NAME" ]]; then
	AMI_NAME="${PROJECT_NAME}-dcv-golden-$(date +%Y%m%d%H%M%S)"
fi

cd "$ROOT_DIR/terraform"

if ! terraform output -json dcv_instance_ids >/dev/null 2>&1; then
	echo "ERROR: Terraform output dcv_instance_ids is missing. Run terraform apply first." >&2
	exit 1
fi

instance_id="$(terraform output -json dcv_instance_ids | jq -r ".[$((DCV_INDEX - 1))]")"

if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
	echo "ERROR: Could not resolve DCV instance id for index ${DCV_INDEX}." >&2
	exit 1
fi

echo "Creating Golden AMI from instance ${instance_id} with name ${AMI_NAME}"

ami_id="$(aws ec2 create-image \
	--region "$AWS_REGION" \
	--instance-id "$instance_id" \
	--name "$AMI_NAME" \
	--description "${PROJECT_NAME} golden DCV image with preinstalled toolchain" \
	--no-reboot \
	--tag-specifications "ResourceType=image,Tags=[{Key=Project,Value=${PROJECT_NAME}},{Key=Role,Value=dcv-golden-ami}]" \
	--query 'ImageId' \
	--output text)"

if [[ -z "$ami_id" || "$ami_id" == "None" ]]; then
	echo "ERROR: AMI creation did not return an AMI ID." >&2
	exit 1
fi

if [[ "$WAIT_FOR_AVAILABLE" == "true" ]]; then
	echo "Waiting for AMI ${ami_id} to become available..."
	aws ec2 wait image-available --region "$AWS_REGION" --image-ids "$ami_id"
fi

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

echo "Golden AMI ready: ${ami_id}"
echo "Updated ${ENV_FILE}: AMI_ID=${ami_id}, DCV_USE_SPOT=true"
