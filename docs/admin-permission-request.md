# AWS Permission Request For `dcv-improvised`

Ask the AWS admin to attach the policy object named `operatorDeployPolicy` from:

`docs/aws-minimal-permissions.json`

to this deploy user:

`arn:aws:iam::582478037114:user/Gokul`

This is for:

- Region: `ap-south-1`
- Project: `dcv-improvised`
- Artifact bucket: `5dcv-1-vpn-server-tf-state-file-bucket`

## What I Have To Do

1. Use `Gokul` to run Terraform and Ansible.
2. Create one always-on VPN/NAT EC2 instance.
3. Create five private DCV EC2 instances.
4. Start/stop DCV instances automatically to save cost.
5. Store VPN/DCV connection artifacts in S3.
6. Use only two runtime roles:
   - one VPN role
   - one shared DCV role for all five DCV instances

## What I Need From Admin

1. If Terraform should create the VPN runtime role/profile, attach `operatorDeployPolicy` to `Gokul`.
2. If the VPN runtime role/profile already exists, attach `docs/operator-existing-role-policy.json` to `Gokul` instead.
3. Give `Gokul` access to this S3 bucket:
   - `arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket`
   - `arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket/*`
4. Ensure EC2 Spot usage is allowed in `ap-south-1`.
5. Ensure EC2 quota is enough for:
   - one `t2.micro` VPN instance
   - five `t3.medium` DCV instances

## Existing Role/Profile Mode

If the IAM role is already created, do not create it again and do not grant destroy permissions.

AWS currently shows:

```text
Role exists: dcv-improvised-vpn-dcv-control-role
Role inline policy exists: dcv-improvised-vpn-dcv-control-policy
Instance profile exists: dcv-improvised-vpn-dcv-control-profile
Instance profile role binding: missing
```

I already created the runtime role policy and instance profile from the CLI. The only blocked step was attaching the role to the instance profile, because `Gokul` is missing `iam:PassRole`.

Admin should grant this to `Gokul`:

```json
{
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": "arn:aws:iam::582478037114:role/dcv-improvised-*",
  "Condition": {
    "StringEquals": {
      "iam:PassedToService": "ec2.amazonaws.com"
    }
  }
}
```

Then I can attach the existing role to the existing instance profile:

```bash
aws iam add-role-to-instance-profile \
  --instance-profile-name dcv-improvised-vpn-dcv-control-profile \
  --role-name dcv-improvised-vpn-dcv-control-role
```

Then set this in `.env`:

```text
VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME=dcv-improvised-vpn-dcv-control-profile
```

With that setting, Terraform skips creating the VPN IAM role/profile. `Gokul` only needs `iam:PassRole` for the existing role, not IAM create/delete.

## Permission Sufficiency

For the current repo and current `.env`, `operatorDeployPolicy` is intended to be sufficient for Terraform create/apply and normal updates of this stack when Terraform creates the runtime profile.

If admin creates the runtime instance profile first and `.env` sets `VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME`, then `docs/operator-existing-role-policy.json` is sufficient and smaller.

It intentionally does not require IAM delete permissions. The project IAM roles and instance profiles can be left in the AWS account if the rest of the stack is later cleaned up.

Permission errors should not occur during create/apply after this policy is attached unless something outside the IAM policy blocks the deploy user.

Admin should also verify these are not blocking `Gokul`:

```text
AWS Organizations SCP                 # can deny actions even when IAM allows them
permissions boundary on Gokul      # can cap the user's effective permissions
S3 bucket policy                      # can deny bucket access even when IAM allows it
S3 bucket ownership/account mismatch  # can cause 403 on the artifact bucket
region restrictions                   # can block ap-south-1 usage
EC2 service quotas                    # can block required instance count/types
Spot service quota/capacity           # can block Spot DCV instances
```

The artifact bucket access was retested with `Gokul` and basic read/write/delete object checks passed. Admin should still keep this bucket access available:

```text
arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket
arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket/*
```

## Runtime Roles

### VPN Role

The VPN role is attached to the always-on VPN/NAT instance.

It needs:

```text
ec2:DescribeInstances        # find the DCV instance assigned to each VPN user
ec2:DescribeInstanceStatus  # wait until a started DCV instance is ready
ec2:StartInstances          # start stopped DCV instances when users need them
ec2:StopInstances           # stop DCV instances after disconnect/idle
```

The start/stop permission is restricted to EC2 instances tagged:

```text
Project=dcv-improvised
Role=dcv
```

### Shared DCV Role

The shared DCV role is attached to all five DCV instances.

It needs this AWS managed policy:

```text
AmazonSSMManagedInstanceCore # allows keyless SSM management instead of SSH keys
```

## Operator Deploy Permissions

These permissions are for `Gokul`, the user running Terraform/Ansible.

### Identity

```text
sts:GetCallerIdentity # Terraform reads account ID to build correct ARNs
```

### Read Existing AWS State

```text
ec2:Describe* # Terraform checks AMIs, VPCs, subnets, routes, SGs, EC2, EIP, volumes
iam:Get*      # Terraform checks role/profile/policy state
iam:List*     # Terraform checks inline policies and role/profile bindings
```

### VPC And Networking

```text
ec2:CreateVpc                    # create project VPC
ec2:DeleteVpc                    # destroy project VPC
ec2:ModifyVpcAttribute           # enable DNS support/hostnames
ec2:CreateSubnet                 # create public/private subnets
ec2:DeleteSubnet                 # destroy public/private subnets
ec2:ModifySubnetAttribute        # enable public IP mapping on public subnet
ec2:CreateInternetGateway        # create internet gateway
ec2:AttachInternetGateway        # attach gateway to VPC
ec2:DetachInternetGateway        # detach gateway during destroy
ec2:DeleteInternetGateway        # delete gateway during destroy
ec2:CreateRouteTable             # create public/private route tables
ec2:DeleteRouteTable             # delete route tables
ec2:CreateRoute                  # add internet route and private route through VPN/NAT
ec2:DeleteRoute                  # remove routes during destroy
ec2:AssociateRouteTable          # attach route tables to subnets
ec2:DisassociateRouteTable       # detach route tables during destroy
ec2:CreateSecurityGroup          # create VPN and DCV security groups
ec2:DeleteSecurityGroup          # delete VPN and DCV security groups
ec2:AuthorizeSecurityGroupIngress # allow VPN, SSH, DCV, and internal traffic
ec2:AuthorizeSecurityGroupEgress  # allow outbound traffic
ec2:RevokeSecurityGroupIngress    # remove inbound rules during destroy
ec2:RevokeSecurityGroupEgress     # remove outbound rules during destroy
```

### EC2 Instances

```text
ec2:RunInstances       # launch VPN and DCV EC2 instances
ec2:TerminateInstances # destroy EC2 instances when tearing down stack
ec2:StartInstances     # admin/project scripts can start DCV instances
ec2:StopInstances      # admin/project scripts can stop DCV instances
ec2:CreateTags         # tag resources with Project, Role, VpnUser
ec2:DeleteTags         # remove tags during cleanup
```

### Elastic IP For VPN

```text
ec2:AllocateAddress    # allocate static public IP for VPN
ec2:AssociateAddress   # attach static public IP to VPN instance
ec2:DisassociateAddress # detach static public IP during destroy/recreate
ec2:ReleaseAddress     # release static public IP if destroying permanently
```

### EBS Volumes

```text
ec2:CreateVolume # create persistent data volumes when separate data disk is enabled
ec2:AttachVolume # attach data volume to DCV instance
ec2:DetachVolume # detach data volume during rebuild/destroy
ec2:DeleteVolume # delete volume only during full cleanup
```

### Spot Instances

```text
ec2:RequestSpotInstances       # request Spot capacity for cost-saving DCV instances
ec2:CancelSpotInstanceRequests # cancel Spot requests during cleanup
```

### SSH Key Pair

The current repo still imports an EC2 SSH key.

```text
ec2:ImportKeyPair # import local public key into EC2
ec2:DeleteKeyPair # delete imported key pair on destroy
```

Later, this can be removed after the repo is fully converted to SSM-only/no-key management.

### S3 Artifacts

```text
s3:GetBucketLocation       # verify bucket region
s3:ListBucket              # list user artifact prefixes
s3:GetObject               # read generated connection info/VPN files
s3:PutObject               # upload generated connection info/VPN files
s3:DeleteObject            # cleanup generated files during destroy
s3:GetObjectTagging        # Terraform reads object tags
s3:PutObjectTagging        # Terraform writes object tags
s3:DeleteObjectTagging     # cleanup object tags
s3:CreateBucket            # only needed if CREATE_S3_BUCKET=true
s3:DeleteBucket            # only needed if Terraform-created bucket is destroyed
s3:PutBucketOwnershipControls # secure bucket ownership settings
s3:PutBucketPublicAccessBlock # block public bucket access
s3:PutBucketVersioning        # enable bucket versioning
s3:PutEncryptionConfiguration # enable bucket encryption
```

Current `.env` has `CREATE_S3_BUCKET=false`, so bucket create/delete may be optional if admin gives access to the existing bucket.

### IAM Role And Instance Profile Lifecycle

```text
iam:CreateRole                  # create VPN/DCV runtime roles; not needed in existing role/profile mode
iam:GetRole                     # Terraform reads role state
iam:PutRolePolicy               # attach inline VPN start/stop policy; not needed in existing role/profile mode
iam:GetRolePolicy               # Terraform reads inline policy state
iam:ListRolePolicies            # Terraform lists inline policies
iam:ListAttachedRolePolicies    # Terraform checks managed policies
iam:CreateInstanceProfile       # create EC2 instance profile wrapper; not needed in existing role/profile mode
iam:GetInstanceProfile          # Terraform reads profile state
iam:AddRoleToInstanceProfile    # bind role to EC2 instance profile; not needed in existing role/profile mode
iam:ListInstanceProfilesForRole # Terraform checks role/profile binding
iam:PassRole                    # allow EC2 instances to launch with these roles
```

These should be restricted to:

```text
arn:aws:iam::582478037114:role/dcv-improvised-*
arn:aws:iam::582478037114:instance-profile/dcv-improvised-*
```

IAM delete permissions are optional. Do not grant these unless you want Terraform to delete the project IAM roles/profiles during full cleanup:

```text
iam:DeleteRole
iam:DeleteRolePolicy
iam:DeleteInstanceProfile
iam:RemoveRoleFromInstanceProfile
```

### SSM No-Key Management

```text
ssm:DescribeInstanceInformation # see SSM-managed EC2 instances
ssm:GetCommandInvocation        # read command result
ssm:SendCommand                 # run setup/check commands without SSH
ssm:StartSession                # open SSM shell session
ssm:TerminateSession            # close SSM shell session
```

## What Was Already Tested

The current deploy user `Gokul` works for:

```text
aws sts get-caller-identity
terraform init
terraform validate
terraform plan
ec2:CreateVpc
ec2:AllocateAddress
ec2:CreateVolume
ec2:ImportKeyPair
ec2:RequestSpotInstances
ec2:RunInstances
ec2:TerminateInstances
s3:GetBucketLocation
s3:ListBucket
s3:PutObject
s3:DeleteObject
iam:CreateRole
iam:CreateInstanceProfile
iam:PutRolePolicy
iam:AddRoleToInstanceProfile
```

The current deploy user `Gokul` still needs this for create/apply:

```text
iam:PassRole
```

Scope it to:

```text
arn:aws:iam::582478037114:role/dcv-improvised-*
```

With this condition:

```text
iam:PassedToService=ec2.amazonaws.com
```

## Will Auto Start/Stop Work?

Yes, after permissions are granted, the VPN role can start and stop DCV instances.

Use `stop`, not `terminate`, for automatic cost saving:

- `stop` saves compute cost and keeps the EC2 instance/root volume.
- `terminate` deletes the instance and is risky unless persistent data volumes and AMI rebuild automation are fully completed.

Current repo supports VPN-only self-service start/stop. Full automatic start-on-VPN-connect and stop-on-disconnect requires adding/enabling the WireGuard watcher automation.
