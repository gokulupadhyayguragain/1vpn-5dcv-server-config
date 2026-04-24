# Final All Permissions For `dcv-improvised`

Use this one document for the AWS admin.

## Target

```text
Deploy user: arn:aws:iam::582478037114:user/Gokul
Region: ap-south-1
Project: dcv-improvised
Artifact bucket: 5dcv-1-vpn-server-tf-state-file-bucket
```

## Admin Must Do

1. If admin wants Terraform to create the VPN runtime role/profile, attach `docs/operator-deploy-policy.json` to `Gokul`.
2. If the VPN runtime role/profile already exists, attach `docs/operator-existing-role-policy.json` to `Gokul` instead.
3. Allow access to the existing S3 bucket listed above.
4. Make sure no SCP, permissions boundary, bucket policy, or region restriction blocks these actions.
5. Make sure EC2 quota allows:
   - one `t2.micro` VPN instance
   - five `t3.medium` DCV instances
   - Spot usage in `ap-south-1`

## Existing Role/Profile Mode

Use this mode if the admin already created the VPN runtime IAM role/profile and you do not want Terraform to create or destroy IAM.

Current AWS check:

```text
Role exists: dcv-improvised-vpn-dcv-control-role
Role inline policy exists: dcv-improvised-vpn-dcv-control-policy
Instance profile exists: dcv-improvised-vpn-dcv-control-profile
Instance profile role binding: missing
```

I already created the runtime role policy and the instance profile from the CLI. The only blocked step was adding the role to the instance profile, because AWS requires `iam:PassRole`.

Admin must grant `Gokul`:

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

After that, I can run:

```bash
aws iam add-role-to-instance-profile \
  --instance-profile-name dcv-improvised-vpn-dcv-control-profile \
  --role-name dcv-improvised-vpn-dcv-control-role
```

Then set this in `.env` before running Terraform:

```text
VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME=dcv-improvised-vpn-dcv-control-profile
```

In this mode, `Gokul` does not need:

```text
iam:CreateRole
iam:CreateInstanceProfile
iam:PutRolePolicy
iam:AddRoleToInstanceProfile
iam:DeleteRole
iam:DeleteRolePolicy
iam:DeleteInstanceProfile
iam:RemoveRoleFromInstanceProfile
```

`Gokul` still needs:

```text
iam:PassRole
```

scoped to:

```text
arn:aws:iam::582478037114:role/dcv-improvised-*
```

## OperatorDeployPolicy

This is the required create/apply policy. It intentionally does not require IAM delete permissions. The VPN/DCV IAM roles can be left in the account if the rest of the stack is later cleaned up.

This same policy is also saved as:

```text
docs/operator-deploy-policy.json
```

## OperatorExistingRolePolicy

Use this policy when the VPN role and instance profile already exist and `.env` has `VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME` set.

This same policy is also saved as:

```text
docs/operator-existing-role-policy.json
```

It removes IAM create/delete permissions and keeps only `iam:PassRole`.

Attach it to:

```text
arn:aws:iam::582478037114:user/Gokul
```

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadState",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity",
        "ec2:Describe*",
        "iam:Get*",
        "iam:List*",
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageProjectEc2VpcEbsSpot",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:AssociateAddress",
        "ec2:AssociateRouteTable",
        "ec2:AttachInternetGateway",
        "ec2:AttachVolume",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CancelSpotInstanceRequests",
        "ec2:CreateInternetGateway",
        "ec2:CreateRoute",
        "ec2:CreateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSubnet",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateVpc",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteKeyPair",
        "ec2:DeleteRoute",
        "ec2:DeleteRouteTable",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSubnet",
        "ec2:DeleteTags",
        "ec2:DeleteVolume",
        "ec2:DeleteVpc",
        "ec2:DetachInternetGateway",
        "ec2:DetachVolume",
        "ec2:DisassociateAddress",
        "ec2:DisassociateRouteTable",
        "ec2:ImportKeyPair",
        "ec2:ModifySubnetAttribute",
        "ec2:ModifyVpcAttribute",
        "ec2:ReleaseAddress",
        "ec2:RequestSpotInstances",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RunInstances",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:TerminateInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageArtifacts",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:DeleteObject",
        "s3:DeleteObjectTagging",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:GetObjectTagging",
        "s3:ListBucket",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutObject",
        "s3:PutObjectTagging"
      ],
      "Resource": [
        "arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket",
        "arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket/*"
      ]
    },
    {
      "Sid": "ManageProjectRolesForApply",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:CreateRole",
        "iam:GetInstanceProfile",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:ListRolePolicies",
        "iam:PutRolePolicy"
      ],
      "Resource": [
        "arn:aws:iam::582478037114:role/dcv-improvised-*",
        "arn:aws:iam::582478037114:instance-profile/dcv-improvised-*"
      ]
    },
    {
      "Sid": "PassProjectRolesToEc2",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::582478037114:role/dcv-improvised-*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "NoKeySsmAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeInstanceInformation",
        "ssm:GetCommandInvocation",
        "ssm:SendCommand",
        "ssm:StartSession",
        "ssm:TerminateSession"
      ],
      "Resource": "*"
    }
  ]
}
```

## Optional IAM Cleanup Policy

Only attach this if you want Terraform to remove the project IAM roles/profiles during a full cleanup. It is not required for create/apply.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DeleteProjectIamRolesAndProfiles",
      "Effect": "Allow",
      "Action": [
        "iam:DeleteInstanceProfile",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::582478037114:role/dcv-improvised-*",
        "arn:aws:iam::582478037114:instance-profile/dcv-improvised-*"
      ]
    }
  ]
}
```

## EC2 Trust Policy

Use this trust policy for the VPN role and the shared DCV role:

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

## VPN Runtime Policy

Attach this to the VPN instance role.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances",
        "ec2:StopInstances"
      ],
      "Resource": "arn:aws:ec2:ap-south-1:582478037114:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Project": "dcv-improvised",
          "aws:ResourceTag/Role": "dcv"
        }
      }
    }
  ]
}
```

## Shared DCV Runtime Role

Use one shared DCV role for all five DCV instances.

Attach this AWS managed policy:

```text
arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

## Optional Existing Bucket Policy

If the bucket policy is blocking `Gokul`, add an allow like this to the bucket policy.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDcvUserArtifacts",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::582478037114:user/Gokul"
      },
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket"
    },
    {
      "Sid": "AllowDcvUserArtifactObjects",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::582478037114:user/Gokul"
      },
      "Action": [
        "s3:DeleteObject",
        "s3:DeleteObjectTagging",
        "s3:GetObject",
        "s3:GetObjectTagging",
        "s3:PutObject",
        "s3:PutObjectTagging"
      ],
      "Resource": "arn:aws:s3:::5dcv-1-vpn-server-tf-state-file-bucket/*"
    }
  ]
}
```

## Final Runtime Shape

```text
1 VPN instance role
1 shared DCV instance role
5 DCV instances using the same shared DCV role
```

## Expected Behavior

```text
VPN instance runs 24/7.
DCV instances are started when needed.
DCV instances are stopped/powered off to save cost.
Use stop, not terminate, until persistent data volumes and AMI rebuild automation are complete.
```
