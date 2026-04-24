# DCV + PiVPN on AWS

This repository builds a VPN-first AWS environment for private Ubuntu Desktop Amazon DCV hosts.
Terraform creates the infrastructure.
Ansible configures the operating systems, VPN, desktop stack, artifacts, and validation checks.

This `README.md` is the single documentation source of truth for this project.

Manual map:

- chapters `1` to `6`: architecture, behavior, and repository layout
- chapters `7` to `10`: operator scripts and local prerequisites
- chapter `11`: full `.env` configuration reference
- chapter `12`: AWS permissions and IAM model
- chapters `13` to `21`: recommended values, workflows, artifacts, runtime behavior, and validation
- chapters `22` to `25`: troubleshooting, security, cleanup, and documentation policy

## 1. What This Project Builds

- `1` Ubuntu `24.04` EC2 instance in a public subnet for `PiVPN + WireGuard + NAT`.
- `X` Ubuntu `24.04` EC2 instances in a private subnet for `Amazon DCV`.
- DCV instances launch as Spot by default for cost reduction.
- Full Ubuntu GNOME desktop on the DCV hosts through `ubuntu-desktop`.
- First-build DCV bootstrap now also installs `Google Chrome`, `Docker`, `VS Code`, and `Flutter`.
- Private-only DCV access: connect to the VPN first, then reach DCV and SSH over private IPs.
- Each DCV root EBS volume is retained on termination for persistence.
- One S3 folder per VPN user for connection files and DCV access information.
- Static private IP support for the VPN host and DCV hosts.
- Static public VPN IP support through an Elastic IP.
- A VPN-only keyless self-service helper so users can start or stop their own DCV EC2 instance without AWS Console access.

## 2. Architecture

### Public Subnet

- Ubuntu `24.04` VPN server.
- PiVPN with WireGuard.
- NAT for private DCV hosts.
- Elastic IP recommended for a stable VPN endpoint.
- Always-on control point for the environment.

### Private Subnet

- One or more Ubuntu `24.04` DCV servers.
- Spot market mode enabled by default (`DCV_USE_SPOT=true`).
- No public IPs.
- SSH and DCV access only through the VPN path.
- Fixed private IPs can be pinned in `.env`.
- The per-host root EBS volume is configured to survive termination.

### S3

- One folder per VPN user.
- Stores VPN `.conf` files.
- Stores `connection-info-<user>.txt`.
- Stores the helper URL and ready-to-use DCV power commands inside the connection info file.

## 3. Access Model

The intended user flow is:

1. Import `userX.conf` into the WireGuard client.
2. Connect to the VPN.
3. If the DCV instance is stopped, open the internal self-service page or use the curl helper commands to start it.
4. Open the DCV client to the private DCV IP from `connection-info-<user>.txt`.
5. Log in to the Ubuntu desktop with the dedicated DCV username and password.

The intended admin flow is:

1. Run `./start.sh`.
2. Use the menu to create, check, scale, SSH, view logs, reset passwords, or control DCV power.

## 4. Important Behavior

### VPN Host

- Should stay on.
- Is the only public entry point.
- Also acts as the NAT instance.
- Holds the least-privilege AWS role used by the self-service DCV power helper.

### DCV Host Poweroff

- DCV and VPN instances are configured with `instance_initiated_shutdown_behavior = "stop"`.
- If a DCV user powers off Ubuntu from the GNOME desktop, the EC2 instance stops instead of terminating.
- A stopped DCV instance cannot be reached by DCV or SSH until it is started again.

### Spot Interruption Warnings

- DCV hosts run a local watcher service for the Spot interruption metadata signal.
- When interruption is announced, users are warned inside Ubuntu using `wall` and desktop notifications when possible.
- DCV hosts disconnect idle clients after the configured idle timeout and stop themselves shortly after the session has no active connections.

### Elastic IP

- With `CREATE_VPN_EIP=true`, the VPN public IP stays stable across EC2 stop/start.
- With `CREATE_VPN_EIP=false` plus `VPN_EIP_ALLOCATION_ID=eipalloc-...`, the same VPN public IP can also be reused across future destroy/create cycles.

### Static Private IPs

- `VPN_PRIVATE_IP` pins the VPN host private IP.
- `DCV_PRIVATE_IPS_CSV` pins the DCV private IPs.
- This is the recommended way to keep client-facing DCV endpoints stable.

## 5. Automation Layers

### Terraform

Terraform creates:

- VPC.
- Public and private subnets.
- Internet gateway.
- Route tables.
- VPN/NAT EC2 instance.
- Private DCV EC2 instances.
- Spot instance market options for DCV instances when enabled.
- DCV root EBS volumes with deletion disabled on termination.
- Security groups.
- Optional S3 bucket.
- Per-user S3 folder markers.
- Initial per-user connection info objects.
- VPN IAM instance profile for self-service DCV power control, or attach a pre-created equivalent when configured.
- Elastic IP logic for the VPN endpoint.

### Ansible

Ansible configures:

- Baseline packages.
- UFW.
- Unattended upgrades.
- Fail2ban.
- PiVPN and WireGuard.
- NAT persistence.
- DCV host hardening and network guard logic.
- Ubuntu GNOME desktop installation.
- Amazon DCV installation and service recovery.
- VPN artifacts and S3 uploads.
- VPN-only self-service DCV power control helper.
- Validation checks.

## 6. Repository Layout

- `setup.sh`: local bootstrap and `.env` preparation.
- `create.sh`: Terraform + Ansible + validation flow.
- `check.sh`: readiness checks and remote validation.
- `destroy.sh`: destroy flow, S3 artifact cleanup, Elastic IP prompt.
- `start.sh`: interactive controller for the whole environment.
- `scripts/`: shared lower-level shell helpers.
- `scripts/create_golden_ami.sh`: create a Golden AMI from a prepared DCV instance and persist `AMI_ID` into `.env`.
- `terraform/`: infrastructure code.
- `ansible/`: playbooks and roles.
- `artifacts/`: local generated user artifacts after Ansible runs.
- `.env.example`: starting configuration template.

## 7. Control Scripts

### `./setup.sh`

What it does:

- installs missing local packages on Ubuntu or Debian-like systems
- installs Terraform if missing
- installs AWS CLI
- creates `.venv/`
- installs Python requirements
- installs Ansible collections
- detects or creates an SSH keypair
- creates `.env` from `.env.example` if needed
- updates `.env` SSH paths
- generates missing `DCV_PASSWORD_<USER>` values
- tries to detect your public IP and set `ALLOWED_ADMIN_CIDR`

### `./create.sh`

What it does:

1. validates `.env`
2. initializes Terraform
3. applies Terraform
4. generates inventory
5. runs the Ansible site playbook
6. runs the validation playbook

### `./check.sh`

What it does:

- shell syntax checks
- Terraform formatting and validation when available locally
- Ansible syntax checks when collections are installed locally
- remote validation against live hosts when Terraform outputs exist

### `./destroy.sh`

What it does:

- loads the current stack context
- asks whether to preserve or destroy the VPN Elastic IP when relevant
- removes per-user S3 artifact prefixes before Terraform destroy
- destroys the infrastructure
- optionally releases a reused Elastic IP
- removes local `artifacts/<user>/` directories after successful destroy

### `./start.sh`

Current menu actions:

- setup
- create everything
- Terraform only
- Ansible only
- scale DCV host count and AMI mode
- check the environment
- regenerate inventory
- show Terraform outputs
- SSH to the VPN host
- SSH to a DCV host
- admin DCV power `status`, `start`, and `stop`
- show DCV build logs
- reset one user password
- reset all user passwords
- destroy and recreate
- destroy

## 8. Quick Start

### Fresh Clone

```bash
git clone <your-repo-url>
cd dcv_improvised
./setup.sh
./check.sh
./create.sh
```

### Guided Menu

```bash
./start.sh
```

Recommended first menu path:

1. `S`
2. `1`
3. `4`

### Minimal Direct Flow

```bash
./setup.sh
./create.sh
./check.sh
```

## 9. Local Requirements

The project expects these tools locally:

- `terraform`
- `aws`
- `ansible-playbook`
- `ansible-galaxy`
- `jq`
- `curl`
- `openssl`
- `ssh-keygen`
- `unzip`
- `python3`
- `pip`

## 10. Spot + Golden AMI Workflow

Recommended flow for fast and cheap replacements:

1. Deploy once and let Ansible complete the full DCV toolchain install.
2. Create a clean Golden AMI from a configured DCV host:

```bash
./scripts/create_golden_ami.sh --dcv-index 1
```

3. Confirm `.env` now has `AMI_ID=ami-...` and `DCV_USE_SPOT=true`.
4. Apply/scale again; new DCV Spot hosts launch from the Golden AMI and retain their root EBS volumes on termination.

Useful `.env` knobs:

- `DCV_USE_SPOT=true|false`
- `DCV_SPOT_MAX_PRICE=`
- `DCV_IDLE_TIMEOUT_MINUTES=10`
- `DCV_STOP_AFTER_IDLE_DISCONNECT_SECONDS=60`
- `AMI_ID=ami-...`

If you do not want to install them manually, use:

```bash
./setup.sh
```

## 10. `.env` Is the Central Control Plane

All configurable values live in `.env`.
This is the single control point for AWS credentials, sizing, IPs, users, passwords, artifacts, and install behavior.

Create it with:

```bash
cp .env.example .env
```

or just run:

```bash
./setup.sh
```

## 11. `.env` Reference

### AWS and Region

`AWS_ACCESS_KEY_ID`

- local AWS access key
- required unless you use another valid AWS credential provider chain

`AWS_SECRET_ACCESS_KEY`

- local AWS secret key
- required unless you use another valid AWS credential provider chain

`AWS_SESSION_TOKEN`

- only required for temporary STS-style credentials

`AWS_REGION`

- AWS region for all resources
- example: `ap-south-1`

`AWS_AVAILABILITY_ZONE`

- single AZ used by the public and private subnets
- example: `ap-south-1a`

### Project and Network

`PROJECT_NAME`

- naming prefix for resources

`VPC_CIDR`

- main VPC range
- default style: `10.20.0.0/16`

`PUBLIC_SUBNET_CIDR`

- public subnet for the VPN/NAT host
- example: `10.20.1.0/24`

`PRIVATE_SUBNET_CIDR`

- private subnet for DCV hosts
- example: `10.20.2.0/24`

`VPN_CLIENT_CIDR`

- WireGuard client network
- example: `10.8.0.0/24`

`ALLOWED_ADMIN_CIDR`

- temporary direct SSH range for the VPN host
- recommended: your public IP with `/32`
- example: `198.51.100.10/32`

`VPN_PRIVATE_IP`

- fixed private IP for the VPN host
- example: `10.20.1.10`
- recommended for stable private addressing

`DCV_PRIVATE_IPS_CSV`

- comma-separated fixed private IP list for the DCV hosts
- example: `10.20.2.10,10.20.2.11,10.20.2.12`
- recommended for stable client-facing DCV endpoints
- keep the number of IPs equal to `DCV_INSTANCE_COUNT`

### Compute and Storage

`VPN_INSTANCE_TYPE`

- EC2 size for the VPN/NAT host
- current low-cost test recommendation: `t2.micro`

`DCV_INSTANCE_TYPE`

- EC2 size for DCV hosts
- reliable starting point: `t3.large`
- workable but tighter: `t3.medium`

`DCV_INSTANCE_COUNT`

- number of DCV EC2 instances
- should match the number of users in `VPN_USERS_CSV`

`DCV_SWAP_SIZE_GB`

- swap space added on DCV hosts before the heavy desktop install
- practical default: `4`

`DCV_CONFIG_SERIAL`

- how many DCV hosts Ansible configures at once
- `1` is slowest but safest
- higher values are faster but put more load on the VPN/NAT path

`DCV_SELF_SERVICE_PORT`

- internal HTTPS port on the VPN host for user self-service power control
- default: `8444`
- users reach it only after connecting to the VPN

`VPN_ROOT_VOLUME_SIZE_GB`

- root disk size for the VPN host
- `8` is the supported lean minimum

`DCV_ROOT_VOLUME_SIZE_GB`

- root disk size for each DCV host
- use a larger value than the VPN host
- desktop hosts need more room

### VPN Public IP Strategy

`CREATE_VPN_EIP`

- `true`: Terraform creates and attaches an Elastic IP
- public IP stays stable across EC2 stop/start
- a future destroy/create usually gets a new EIP unless you preserve and reuse it

`VPN_EIP_ALLOCATION_ID`

- existing EIP allocation ID like `eipalloc-0123456789abcdef0`
- use it together with `CREATE_VPN_EIP=false` if you want the same VPN public IP across future destroy/create too

`VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME`

- optional pre-created EC2 instance profile name for the VPN host
- use this when your AWS user cannot create IAM roles or instance profiles
- if set, Terraform skips IAM role and instance profile creation and attaches this existing profile to the VPN host instead
- the profile must already allow `ec2:DescribeInstances`, `ec2:DescribeInstanceStatus`, `ec2:StartInstances`, and `ec2:StopInstances` for the project DCV instances
- your AWS user still needs permission to pass that profile to EC2

### SSH

`SSH_PUBLIC_KEY_PATH`

- local SSH public key path for the EC2 key pair import

`SSH_PRIVATE_KEY_PATH`

- local SSH private key path used by admin scripts

`SSH_KEY_NAME`

- EC2 key pair name

### User Mapping and Passwords

`VPN_USERS_CSV`

- comma-separated user list
- example: `user1,user2,user3`
- each user is mapped 1:1 to a DCV host

`DCV_PASSWORD_<USER>`

- password for that user on the matching DCV host
- example: `DCV_PASSWORD_USER1=Qwerty@12345`

`DCV_SUDO_<USER>`

- per-user sudo toggle
- example: `DCV_SUDO_USER1=true`
- set `false` for tighter least privilege

### S3 and State

`CREATE_S3_BUCKET`

- `true`: Terraform creates the artifacts bucket
- `false`: bucket already exists

`S3_BUCKET_NAME`

- artifacts bucket name
- used for VPN profiles, connection info, and helper access details

`TF_STATE_BUCKET_NAME`

- optional extra key you may add to `.env` manually
- if set, Terraform state is stored in S3 instead of locally

`TF_STATE_KEY`

- key path used for remote Terraform state
- default style: `terraform/dcv-improvised.tfstate`

Important remote-state note:

- if `TF_STATE_BUCKET_NAME` matches `S3_BUCKET_NAME`, pre-create the bucket first
- then set `CREATE_S3_BUCKET=false`

### DCV Installation

`AMI_ID`

- leave blank to use the latest Ubuntu `24.04` base AMI
- set a custom AMI for faster DCV scaling

`NICE_DCV_DOWNLOAD_URL`

- DCV server package URL

`DCV_BOOTSTRAP_TIMEOUT_SECONDS`

- total wait budget for the heavy GNOME + DCV bootstrap

`DCV_BOOTSTRAP_POLL_INTERVAL_SECONDS`

- polling interval for bootstrap progress checks

## 12. AWS Permissions and IAM Model

This project uses three separate permission layers.
Keeping them separate is important for security and for understanding where a failure comes from.

### 12.1 Permission Layers

`Local operator AWS identity`

- this is the AWS credential chain on your laptop or controller machine
- Terraform uses it to create and destroy AWS infrastructure
- Ansible uses it locally for S3 artifact upload and cleanup
- `destroy.sh` also uses it for S3 cleanup and optional Elastic IP release

`VPN EC2 instance profile`

- this is the IAM role attached to the always-on VPN host
- the keyless self-service helper on the VPN host uses it at runtime
- it lets the VPN host describe, start, and stop only the project DCV instances
- users never see or handle AWS keys directly

`End users`

- end users do not need AWS credentials
- end users do not need AWS Console access
- end users do not need the old helper SSH key
- end users only need:
  - `user*.conf` for WireGuard VPN access
  - their DCV username
  - their DCV password

### 12.2 Local Operator AWS Permissions

The local operator identity needs different permissions depending on which features are enabled.

Important exactness note:

- the action groups below describe the functional permissions this repo needs
- the AWS Terraform provider also performs supporting `Describe*`, `Get*`, and `List*` reads while refreshing state
- in practice, least-privilege IAM for Terraform usually allows the create, update, delete, and related read actions for the exact resource families used by the stack
- this repo intentionally creates the VPN IAM role and instance profile through an untagged AWS provider alias, so `iam:TagRole` and `iam:TagInstanceProfile` are not required just for create

#### What Your Current `.env` Needs

With the current repo settings shown in [`.env`](/home/tempadmin/PROJECTS/dcv_improvised/.env):

- `CREATE_S3_BUCKET=false`
- `CREATE_VPN_EIP=true`
- `VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME=` is blank
- `TF_STATE_BUCKET_NAME` is not set

the local operator does not currently need:

- S3 bucket-creation permissions for the artifacts bucket
- remote Terraform backend bucket permissions
- IAM tagging permissions for the VPN runtime role or instance profile

but the local operator does currently need:

- EC2/VPC create, read, tag, and destroy permissions for the stack resources
- Elastic IP allocate, associate, disassociate, describe, and release permissions
- S3 object upload and delete permissions for per-user artifacts in the existing bucket
- the full Terraform-managed IAM role and instance-profile lifecycle permissions listed below

#### Core Read Permissions

These are needed almost all the time:

| Service | Actions | Why the project needs them |
| --- | --- | --- |
| `sts` | `GetCallerIdentity` | Terraform uses the AWS account ID to build the least-privilege runtime EC2 role policy. |
| `ec2` | `DescribeInstances`, `DescribeInstanceStatus`, `DescribeImages`, `DescribeVpcs`, `DescribeSubnets`, `DescribeRouteTables`, `DescribeInternetGateways`, `DescribeSecurityGroups`, `DescribeAddresses`, `DescribeKeyPairs` | Terraform, readiness checks, inventory generation, and helper scripts all need to discover live AWS state. |
| `s3` | `ListBucket`, `GetBucketLocation`, `GetObject` | Needed when the bucket already exists, when artifacts are checked, and when cleanup logic verifies S3 state. |
| `iam` | `PassRole` | Needed whenever the VPN EC2 instance is launched with a runtime instance profile. If you use a pre-created instance profile, this can be the only IAM permission the local operator needs. |

#### VPC and Network Create/Delete Permissions

These are required because Terraform creates the VPC layer:

| Service | Actions | Why the project needs them |
| --- | --- | --- |
| `ec2` | `CreateVpc`, `DeleteVpc` | Build and remove the project VPC. |
| `ec2` | `CreateSubnet`, `DeleteSubnet` | Build the public and private subnets. |
| `ec2` | `CreateRouteTable`, `DeleteRouteTable`, `AssociateRouteTable`, `DisassociateRouteTable`, `CreateRoute`, `DeleteRoute` | Build public and private routing, including private default routing through the VPN/NAT host. |
| `ec2` | `CreateInternetGateway`, `AttachInternetGateway`, `DetachInternetGateway`, `DeleteInternetGateway` | Provide public internet access for the public subnet. |
| `ec2` | `CreateSecurityGroup`, `DeleteSecurityGroup`, `AuthorizeSecurityGroupIngress`, `RevokeSecurityGroupIngress`, `AuthorizeSecurityGroupEgress`, `RevokeSecurityGroupEgress` | Create and manage the VPN and DCV security groups. |

#### EC2 Compute Permissions

These are required because Terraform creates and destroys the instances and because helper scripts inspect them:

| Service | Actions | Why the project needs them |
| --- | --- | --- |
| `ec2` | `RunInstances`, `TerminateInstances` | Create and destroy the VPN and DCV EC2 instances. |
| `ec2` | `CreateTags`, `DeleteTags` | Tag VPN and DCV instances so user mapping and least-privilege runtime control works. |
| `ec2` | `ImportKeyPair`, `DeleteKeyPair` | Import the local SSH public key into EC2 and remove it on destroy. |

#### Elastic IP Permissions

These are required only when you use a static public VPN IP:

| Service | Actions | Why the project needs them |
| --- | --- | --- |
| `ec2` | `AllocateAddress`, `ReleaseAddress` | Create and release a Terraform-managed Elastic IP. |
| `ec2` | `AssociateAddress`, `DisassociateAddress` | Attach and detach the Elastic IP from the VPN instance. |
| `ec2` | `DescribeAddresses` | Resolve current Elastic IP state for Terraform outputs and destroy behavior. |

#### S3 Bucket and Artifact Permissions

These are required because Terraform and Ansible create and manage artifact files:

| Service | Actions | Why the project needs them |
| --- | --- | --- |
| `s3` | `CreateBucket`, `DeleteBucket` | Only needed when `CREATE_S3_BUCKET=true`. |
| `s3` | `PutBucketOwnershipControls`, `PutBucketPublicAccessBlock`, `PutEncryptionConfiguration`, `PutBucketVersioning`, `PutBucketTagging`, `DeleteBucketTagging` | Configure the artifacts bucket securely when Terraform creates it. The bucket-tagging permissions are only needed when Terraform creates the bucket because the default AWS provider applies tags. |
| `s3` | `PutObject`, `DeleteObject`, `GetObject`, `ListBucket` | Upload VPN profiles and connection info, remove legacy helper files, and clean per-user prefixes on destroy. |

#### IAM Permissions for Full Automation

These are required only when Terraform is allowed to create the VPN runtime role and instance profile itself:

| Service | Actions | Why the project needs them |
| --- | --- | --- |
| `iam` | `CreateRole`, `DeleteRole` | Create and remove the runtime role attached to the VPN host. |
| `iam` | `GetRole` | Terraform refreshes the created role after create and during plan, apply, and destroy. |
| `iam` | `PutRolePolicy`, `GetRolePolicy`, `ListRolePolicies`, `DeleteRolePolicy` | Attach, inspect, enumerate, and remove the inline least-privilege EC2 control policy. |
| `iam` | `ListAttachedRolePolicies` | Terraform checks for attached managed policies on the role during refresh, even though this repo does not attach any managed policies itself. |
| `iam` | `CreateInstanceProfile`, `DeleteInstanceProfile` | Create and remove the EC2 instance profile wrapper for the runtime role. |
| `iam` | `GetInstanceProfile` | Terraform refreshes the instance profile after create and during future plan, apply, and destroy runs. |
| `iam` | `AddRoleToInstanceProfile`, `RemoveRoleFromInstanceProfile`, `ListInstanceProfilesForRole` | Bind or unbind the runtime role to the instance profile and enumerate role/profile bindings during refresh. |
| `iam` | `PassRole` | Allow EC2 to launch the VPN host with the runtime role or a pre-created role. |

#### Practical Apply-Only IAM Policy For The VPN Runtime Role

If your admin wants the smallest policy that is still practical for `terraform apply` with this repo's automatic VPN runtime role creation, this is the correct minimum:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDcvImprovisedIamAutomation",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:CreateInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:ListInstanceProfilesForRole",
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
```

What this practical apply-only policy covers:

- creating the VPN runtime role
- reading the role back after creation
- attaching the inline EC2 control policy
- reading and enumerating the inline policy state during refresh
- checking that no managed policies are attached to the role
- creating the VPN runtime instance profile
- reading the instance profile back after creation
- adding the role to the instance profile
- enumerating the role-to-instance-profile binding during refresh
- passing the role to the VPN EC2 instance at launch time

What it still does not cover:

- deleting the IAM role or instance profile during destroy
- removing the role from the instance profile during destroy
- deleting the inline role policy during destroy

#### Practical Full-Lifecycle IAM Policy For The VPN Runtime Role

If you want one policy that covers create, refresh, and destroy for the Terraform-managed VPN runtime role path, use this:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDcvImprovisedIamTerraformLifecycle",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:DeleteRole",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:DeleteRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:CreateInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:ListInstanceProfilesForRole",
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
```

This full-lifecycle policy is the practical answer if you want to stop discovering IAM read or destroy gaps one permission at a time.

### 12.3 Which Permissions Are Optional

Some permissions are only needed in certain modes:

- if `CREATE_S3_BUCKET=false`, bucket-creation permissions are not needed
- if `CREATE_VPN_EIP=false` and you do not use any Elastic IP, address allocation permissions are not needed
- if `CREATE_VPN_EIP=false` and you reuse an existing EIP, Terraform still needs address association permissions
- if `VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME` is set, Terraform skips IAM role and instance profile creation
- if `VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME` is set, the local operator normally only needs `iam:PassRole` on that pre-created role or instance profile, not the full IAM action set above

### 12.4 VPN Runtime Instance Profile Permissions

The VPN host needs a runtime IAM role because the self-service helper runs on the VPN host and calls the EC2 API to start or stop the user's dedicated DCV instance.

The runtime role policy used by this repo is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DescribeProjectDcvInstances",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "StartStopProjectDcvInstances",
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances",
        "ec2:StopInstances"
      ],
      "Resource": "arn:aws:ec2:<REGION>:<ACCOUNT_ID>:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Project": "<PROJECT_NAME>",
          "aws:ResourceTag/Role": "dcv"
        }
      }
    }
  ]
}
```

What each runtime permission does:

- `ec2:DescribeInstances`: lets the helper resolve which instance belongs to `user1`, `user2`, and so on
- `ec2:DescribeInstanceStatus`: lets the helper wait until the started DCV instance passes AWS status checks
- `ec2:StartInstances`: lets the helper power on a stopped DCV instance
- `ec2:StopInstances`: lets the helper power off a running DCV instance

Why the tag conditions matter:

- they stop the helper from starting or stopping unrelated EC2 instances
- only instances tagged with this repo's `Project` value and `Role=dcv` are controllable

### 12.5 Runtime Trust Policy

The runtime role must trust EC2 so it can be attached to the VPN host:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### 12.6 Fallback When Your AWS User Cannot Create IAM Resources

If Terraform fails with `iam:CreateRole`, `iam:CreateInstanceProfile`, or similar IAM errors:

1. ask an AWS admin to pre-create the runtime EC2 instance profile
2. set `VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME=<existing-profile-name>` in `.env`
3. rerun `./create.sh`

In this fallback mode:

- Terraform skips `aws_iam_role.vpn_dcv_control`
- Terraform skips `aws_iam_role_policy.vpn_dcv_control`
- Terraform skips `aws_iam_instance_profile.vpn_dcv_control`
- the VPN EC2 instance attaches the existing instance profile instead

Important:

- the existing instance profile must contain the runtime permissions shown above
- your AWS user must still be allowed to pass that role/profile to EC2
- if `iam:PassRole` is missing, the next failure usually happens when the VPN instance is launched

### 12.7 What Permission Errors Mean in Practice

If you see:

- `iam:CreateRole`: your AWS user cannot create the runtime role automatically
- `iam:GetRole`: Terraform created or found the role, but cannot read it back during refresh
- `iam:ListRolePolicies`: Terraform cannot enumerate inline policies on the runtime role during refresh
- `iam:ListAttachedRolePolicies`: Terraform cannot enumerate attached managed policies on the runtime role during refresh
- `iam:CreateInstanceProfile`: your AWS user cannot create the EC2 instance profile automatically
- `iam:GetInstanceProfile`: Terraform created or found the instance profile, but cannot read it back during refresh
- `iam:ListInstanceProfilesForRole`: Terraform cannot enumerate the role-to-instance-profile binding during refresh
- `iam:PassRole`: your AWS user can see the role/profile but cannot attach it to the VPN EC2 instance
- `iam:DeleteRole` or `iam:DeleteInstanceProfile`: create worked, but your user does not have enough IAM permission for full Terraform destroy
- `ec2:AllocateAddress`: your AWS user cannot create a Terraform-managed Elastic IP
- `s3:CreateBucket`: your AWS user cannot create the artifacts bucket, so use a pre-created bucket and set `CREATE_S3_BUCKET=false`

## 13. Recommended Values

### Cost-Optimized Test VPN Host

- `VPN_INSTANCE_TYPE=t2.micro`
- `VPN_ROOT_VOLUME_SIZE_GB=8`

### Safer DCV First Run

- `DCV_INSTANCE_TYPE=t3.large`
- `DCV_SWAP_SIZE_GB=4`
- `DCV_CONFIG_SERIAL=1`

### Faster But Riskier Parallel Build

- increase `DCV_CONFIG_SERIAL`
- remember that the VPN/NAT host is still the gateway for the private hosts

## 14. Standard Workflows

### Create Everything

```bash
./create.sh
```

### Refresh Config Only

```bash
./scripts/run_ansible.sh
```

### Terraform Only

```bash
./scripts/terraform_apply.sh
```

### Destroy Everything

```bash
./destroy.sh
```

### Destroy and Rebuild

```bash
./start.sh
```

Then choose `X`.

## 15. Connection Artifacts

After Ansible finishes, artifacts are available in:

- local `artifacts/<user>/`
- `s3://<bucket>/<user>/`

Each user folder contains:

- `<user>.conf`
- `connection-info-<user>.txt`

What each file is for:

- `<user>.conf`: import into the WireGuard client
- `connection-info-<user>.txt`: quick reference for VPN endpoint, DCV private IP, DCV username, DCV password, internal self-service helper URL, and curl commands

## 16. DCV Self-Service Power Control

This project now supports VPN-only keyless self-service start and stop for DCV hosts.

### How It Works

- the VPN host stays on
- the VPN host has a least-privilege EC2 instance role
- each DCV instance is tagged with the project name, role, and assigned VPN user
- the VPN host runs an internal HTTPS helper bound to its private IP
- the helper is reachable only after the user connects to WireGuard
- users authenticate with the same DCV username and password they use for the desktop login
- the helper starts, stops, or checks only the single DCV instance mapped to that VPN user

### Browser Flow

Example for `user1`:

1. connect to the VPN with `user1.conf`
2. open `https://10.20.1.10:8444/`
3. accept the self-signed certificate warning the first time
4. sign in with:
   username: `user1`
   password: the same DCV password shown in `connection-info-user1.txt`
5. use the `Start`, `Stop`, or `Refresh` buttons

### Curl Commands

Example for `user1`:

```bash
curl -ksS -u user1:'<YOUR_DCV_PASSWORD>' https://10.20.1.10:8444/status
curl -ksS -u user1:'<YOUR_DCV_PASSWORD>' -X POST https://10.20.1.10:8444/api/start
curl -ksS -u user1:'<YOUR_DCV_PASSWORD>' -X POST https://10.20.1.10:8444/api/stop
```

### Very Important Answer: Do These Commands Need Any Extra SSH Key?

No.

- `user1.conf` is still required because it is how the machine joins the WireGuard VPN
- no extra helper SSH key is required anymore
- the internal helper uses HTTPS Basic Auth with the same DCV username and password

So the correct model is:

1. connect to the VPN with `user1.conf`
2. open the helper URL or run the curl command
3. authenticate with the same DCV username and password
4. start the instance if needed
5. connect to the DCV desktop on the private IP

### Why This Is Still Secure

- it is reachable only after VPN connection
- the helper listens on the VPN host private IP
- UFW restricts the helper port to the VPN CIDR
- the VPN host EC2 role can start and stop only tagged DCV instances in this project
- users authenticate with their own dedicated DCV credentials
- each authenticated user can operate only the DCV instance tagged for that user

### What Happens If A User Powers Off Ubuntu From GNOME?

- the DCV EC2 instance stops
- it is not terminated
- its root EBS volume stays
- the private IP remains stable
- the user reconnects to the VPN and uses the helper to start it again

## 17. Admin DCV Power Control

Admins can control DCV power through:

```bash
./start.sh
```

Then choose:

- `P` for DCV power control

That admin path runs the same VPN-host helper, but through the admin SSH path to the VPN server.

## 18. Elastic IP Behavior

### Mode 1: Terraform-Managed EIP

Configuration:

- `CREATE_VPN_EIP=true`
- `VPN_EIP_ALLOCATION_ID=` blank

Behavior:

- Terraform creates the EIP
- Terraform attaches it to the VPN host
- stop/start keeps the same public IP
- destroy/create normally gets a different public IP

### Mode 2: Reused Existing EIP

Configuration:

- `CREATE_VPN_EIP=false`
- `VPN_EIP_ALLOCATION_ID=eipalloc-...`

Behavior:

- Terraform reuses your existing EIP
- stop/start keeps the same public IP
- destroy/create can keep the same public IP too

### Destroy Prompt

When a static EIP is present, `./destroy.sh` shows the live public IP and asks:

```text
Do you want to destroy the Elastic IP (<vpn-public-ip>) attached to the VPN server? [y/N]:
```

Behavior:

- `Y` or `y`: destroy or release the EIP too
- `N`, `n`, or `Enter`: preserve it

If the EIP was Terraform-managed and you preserve it, the script updates `.env` so the next create reuses that allocation.

## 19. Stop, Start, Reboot, and Poweroff Semantics

### DCV Guest Poweroff

- GNOME poweroff on a DCV host maps to EC2 stop
- the root EBS volume persists
- OS state and data on disk persist
- RAM does not persist

### DCV Stop

- instance is unreachable until started again
- private IP remains stable on the ENI

### DCV Start

- instance starts again with the same private IP
- user reconnects over VPN
- DCV services recover through the repo's service guards

### VPN Host Stop

- should be avoided during normal use
- if the VPN host is stopped, users lose the access path to the private subnet and the self-service helper

### Reboot Note

The repo includes recovery guards so DCV hosts reassert:

- `ssh.service`
- `systemd-networkd`
- `gdm3`
- `dcvserver`
- the default DCV session

## 20. Scaling and AMI Strategy

### Typical Path

- keep `AMI_ID` blank
- set `DCV_INSTANCE_COUNT`, `VPN_USERS_CSV`, and `DCV_PRIVATE_IPS_CSV`
- apply Terraform
- run Ansible
- expect a fresh Ubuntu Desktop + GNOME + DCV build on each host

### Faster Path

- build one clean golden DCV host
- create a custom AMI from it
- sanitize user-specific or sensitive data first
- set `AMI_ID`
- increase host count
- apply Terraform

Important:

- the current repo supports using a custom `AMI_ID`
- it does not yet automate Packer or AMI creation
- current Terraform creates each DCV instance separately from the same AMI
- it does not create one live DCV host and clone it during the same run

## 21. Validation Flow

`./check.sh` runs:

- shell syntax checks
- Terraform formatting and validation when possible
- Ansible syntax checks
- remote validation when Terraform outputs exist

Remote validation checks include:

- VPN host reachability
- WireGuard config and service
- DCV desktop bootstrap completion
- SSH stability settings
- network guard services
- DCV service state
- DCV session existence
- private host internet egress
- UFW
- fail2ban
- lynis
- DCV-to-DCV east-west ICMP reachability
- VPN DCV control helper presence and keyless HTTPS endpoint authentication

## 22. Logs and Troubleshooting

### DCV Desktop Build Log

Path on each DCV host:

```text
/var/log/dcv-desktop-bootstrap.log
```

Admin shortcut:

```bash
./start.sh
```

Then choose `L`.

### If DCV Build Looks Stuck

1. check `./start.sh` option `L`
2. run `./check.sh`
3. if needed, rerun `./scripts/run_ansible.sh`

### If a DCV Host Reboots From the Desktop

1. wait a few minutes
2. run `./check.sh`
3. if needed, rerun `./scripts/run_ansible.sh`

### If Users Cannot Reach the Helper

Check:

- VPN is connected
- user is trying the VPN host private IP, not the public IP
- user is signing in with the same DCV username and password shown in `connection-info-<user>.txt`
- DCV host is still part of the stack

### If `create.sh` Fails With `AccessDenied`

Check the AWS action in the error text.

Common examples:

- `iam:CreateRole`: your AWS user cannot create the runtime role automatically
- `iam:CreateInstanceProfile`: your AWS user cannot create the runtime instance profile automatically
- `iam:PassRole`: your AWS user can see the role/profile but cannot attach it to the VPN host
- `ec2:AllocateAddress`: your AWS user cannot create a Terraform-managed Elastic IP
- `s3:CreateBucket`: your AWS user cannot create the artifacts bucket

What to do:

1. compare the failing action with chapter `12`
2. either ask for the missing permission
3. or switch to the documented fallback mode such as:
   - pre-created S3 bucket with `CREATE_S3_BUCKET=false`
   - pre-created instance profile with `VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME=...`

### If `destroy.sh` Leaves S3 User Folders Behind

Current behavior is to remove per-user prefixes before Terraform destroy.
If old folders remain from a destroy that happened before this logic existed, run `./destroy.sh` again with the current code.

## 23. Security Model

- all configurable values live in `.env`
- private DCV hosts have no public IPs
- VPN host uses IMDSv2
- UFW is enabled
- fail2ban is enabled
- unattended upgrades are enabled
- S3 buckets are private, versioned, and encrypted when Terraform creates them
- AWS credentials stay local and are not uploaded to S3
- operator AWS permissions and VPN runtime AWS permissions are intentionally separated
- the DCV power helper uses a least-privilege instance role on the VPN host
- the DCV power helper is restricted to project-tagged DCV instances
- the keyless helper is reachable only through the VPN path and authenticates each user with their own DCV credentials

## 24. Cleaning Local Generated Files

If you want the repo to feel like a fresh clone without touching AWS resources:

```bash
./scripts/clean_local_generated.sh
```

If you also want to remove local artifacts:

```bash
./scripts/clean_local_generated.sh --include-artifacts
```

This cleanup preserves:

- `.env`
- `.venv/`
- `terraform/terraform.tfstate`
- `terraform/terraform.tfstate.backup`

## 25. Single Documentation Policy

This file is the complete manual.

The old files in `docs/` are kept only as compatibility pointers.
If documentation needs to change, update `README.md`.
