data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_eip" "vpn_existing" {
  count = var.create_vpn_eip || var.vpn_eip_allocation_id == "" ? 0 : 1
  id    = var.vpn_eip_allocation_id
}

data "aws_iam_policy_document" "vpn_dcv_control_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "vpn_dcv_control" {
  statement {
    sid = "DescribeProjectDcvInstances"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus"
    ]
    resources = ["*"]
  }

  statement {
    sid = "StartStopProjectDcvInstances"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances"
    ]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Role"
      values   = ["dcv"]
    }
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 3
}

locals {
  ubuntu_ami_id                        = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_2404.id
  normalized_project                   = trim(replace(lower(var.project_name), "/[^a-z0-9-]/", "-"), "-")
  generated_name                       = substr("${local.normalized_project}-${random_id.bucket_suffix.hex}", 0, 63)
  effective_bucket                     = var.s3_bucket_name != "" ? var.s3_bucket_name : local.generated_name
  create_vpn_dcv_control_iam_resources = trimspace(var.vpn_dcv_control_instance_profile_name) == ""
  normalized_vpn_users = [
    for user in var.vpn_users : trimspace(user)
    if trimspace(user) != ""
  ]
  normalized_vpn_user_set = toset(local.normalized_vpn_users)
  dcv_hosts = {
    for index, instance in aws_instance.dcv : "dcv-${index + 1}" => instance.private_ip
  }
  user_dcv_assignments = {
    for index, user in local.normalized_vpn_users : user => {
      host_name  = "dcv-${index + 1}"
      private_ip = aws_instance.dcv[index].private_ip
    }
  }
  vpn_public_endpoint_mode                        = var.create_vpn_eip ? "terraform_managed_elastic_ip" : (var.vpn_eip_allocation_id != "" ? "existing_elastic_ip" : "ephemeral_public_ip")
  effective_vpn_public_ip                         = var.create_vpn_eip ? aws_eip.vpn[0].public_ip : (var.vpn_eip_allocation_id != "" ? data.aws_eip.vpn_existing[0].public_ip : aws_instance.vpn_nat.public_ip)
  effective_vpn_eip_allocation_id                 = local.vpn_public_endpoint_mode == "terraform_managed_elastic_ip" ? aws_eip.vpn[0].id : (local.vpn_public_endpoint_mode == "existing_elastic_ip" ? var.vpn_eip_allocation_id : "")
  effective_vpn_dcv_control_instance_profile_name = local.create_vpn_dcv_control_iam_resources ? aws_iam_instance_profile.vpn_dcv_control[0].name : trimspace(var.vpn_dcv_control_instance_profile_name)
}

# SCALING NOTE BLOCK
# KEEP DCV_INSTANCE_COUNT MATCHED TO VPN USER COUNT FOR DEDICATED 1:1 ASSIGNMENTS, OR SPLIT INTO POOLS LATER FOR LARGER FLEETS.
resource "aws_key_pair" "main" {
  key_name   = var.ssh_key_name
  public_key = file(var.ssh_public_key_path)
}

resource "aws_iam_role" "vpn_dcv_control" {
  provider           = aws.untagged
  count              = local.create_vpn_dcv_control_iam_resources ? 1 : 0
  name               = "${var.project_name}-vpn-dcv-control-role"
  assume_role_policy = data.aws_iam_policy_document.vpn_dcv_control_assume_role.json
}

resource "aws_iam_role_policy" "vpn_dcv_control" {
  provider = aws.untagged
  count    = local.create_vpn_dcv_control_iam_resources ? 1 : 0
  name     = "${var.project_name}-vpn-dcv-control-policy"
  role     = aws_iam_role.vpn_dcv_control[0].id
  policy   = data.aws_iam_policy_document.vpn_dcv_control.json
}

resource "aws_iam_instance_profile" "vpn_dcv_control" {
  provider = aws.untagged
  count    = local.create_vpn_dcv_control_iam_resources ? 1 : 0
  name     = "${var.project_name}-vpn-dcv-control-profile"
  role     = aws_iam_role.vpn_dcv_control[0].name
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "vpn" {
  name        = "${var.project_name}-vpn-sg"
  description = "VPN/NAT instance security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_admin_cidr]
  }

  ingress {
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpn_client_cidr]
  }

  # SELF-SERVICE HTTPS BLOCK
  # EXPOSES THE INTERNAL DCV POWER HELPER ONLY TO VPN CLIENT ADDRESSES SO USERS CAN START OR STOP THEIR OWN DCV INSTANCE AFTER CONNECTING TO WIREGUARD.
  ingress {
    from_port   = var.dcv_self_service_port
    to_port     = var.dcv_self_service_port
    protocol    = "tcp"
    cidr_blocks = [var.vpn_client_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "dcv" {
  name        = "${var.project_name}-dcv-sg"
  description = "Private DCV server security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.public_subnet_cidr]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpn_client_cidr]
  }

  # EAST-WEST ACCESS BLOCK
  # ALLOWS DCV HOSTS THAT SHARE THIS SECURITY GROUP TO REACH EACH OTHER FOR PING, SSH TESTING, AND PRIVATE-SUBNET TROUBLESHOOTING.
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "dcv_user" {
  count       = var.dcv_instance_count
  name        = "${var.project_name}-dcv-${count.index + 1}-user-sg"
  description = "Per-user DCV web access for ${local.normalized_vpn_users[count.index]}"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(var.vpn_client_cidr, count.index + 2)}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-dcv-${count.index + 1}-user-sg"
    Role    = "dcv-user-access"
    VpnUser = local.normalized_vpn_users[count.index]
  }
}

resource "aws_instance" "vpn_nat" {
  ami                                  = local.ubuntu_ami_id
  instance_type                        = var.vpn_instance_type
  subnet_id                            = aws_subnet.public.id
  vpc_security_group_ids               = [aws_security_group.vpn.id]
  key_name                             = aws_key_pair.main.key_name
  iam_instance_profile                 = local.effective_vpn_dcv_control_instance_profile_name
  instance_initiated_shutdown_behavior = "stop"
  source_dest_check                    = false
  associate_public_ip_address          = true
  private_ip                           = var.vpn_private_ip != "" ? var.vpn_private_ip : null

  root_block_device {
    volume_size = var.vpn_root_volume_size_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/templates/user_data_nat_vpn.sh.tftpl", {
    private_subnet_cidr = var.private_subnet_cidr
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${var.project_name}-vpn"
    Role = "vpn"
  }
}

resource "aws_eip" "vpn" {
  count  = var.create_vpn_eip ? 1 : 0
  domain = "vpc"
}

resource "aws_eip_association" "vpn_new" {
  count         = var.create_vpn_eip ? 1 : 0
  instance_id   = aws_instance.vpn_nat.id
  allocation_id = aws_eip.vpn[0].id
}

resource "aws_eip_association" "vpn_existing" {
  count         = var.create_vpn_eip || var.vpn_eip_allocation_id == "" ? 0 : 1
  instance_id   = aws_instance.vpn_nat.id
  allocation_id = var.vpn_eip_allocation_id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "private_default_via_vpn" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.vpn_nat.primary_network_interface_id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_instance" "dcv" {
  count                                = var.dcv_instance_count
  ami                                  = local.ubuntu_ami_id
  instance_type                        = var.dcv_instance_type
  subnet_id                            = aws_subnet.private.id
  vpc_security_group_ids               = [aws_security_group.dcv.id, aws_security_group.dcv_user[count.index].id]
  key_name                             = aws_key_pair.main.key_name
  instance_initiated_shutdown_behavior = var.dcv_use_spot ? null : "stop"
  associate_public_ip_address          = false
  private_ip                           = length(var.dcv_private_ips) == var.dcv_instance_count ? var.dcv_private_ips[count.index] : null

  root_block_device {
    volume_size           = var.dcv_root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = false
  }

  dynamic "instance_market_options" {
    for_each = var.dcv_use_spot ? [1] : []
    content {
      market_type = "spot"

      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
        max_price                      = var.dcv_spot_max_price != "" ? var.dcv_spot_max_price : null
      }
    }
  }

  user_data = templatefile("${path.module}/templates/user_data_dcv.sh.tftpl", {})

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name    = "${var.project_name}-dcv-${count.index + 1}"
    Role    = "dcv"
    VpnUser = local.normalized_vpn_users[count.index]
  }
}

# SCALING NOTE BLOCK
# REUSE AN EXISTING SHARED BUCKET WHEN YOU WANT A SINGLE BUCKET FOR ARTIFACTS AND OPTIONAL REMOTE STATE.
resource "aws_s3_bucket" "vpn_artifacts" {
  count         = var.create_s3_bucket ? 1 : 0
  bucket        = local.effective_bucket
  force_destroy = false
}

resource "aws_s3_bucket_ownership_controls" "vpn_artifacts" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.vpn_artifacts[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "vpn_artifacts" {
  count                   = var.create_s3_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.vpn_artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vpn_artifacts" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.vpn_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "vpn_artifacts" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.vpn_artifacts[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "vpn_user_folders" {
  for_each = local.normalized_vpn_user_set
  bucket   = local.effective_bucket
  key      = "${each.value}/.keep"
  content  = "folder marker"

  depends_on = [
    aws_s3_bucket.vpn_artifacts,
    aws_s3_bucket_ownership_controls.vpn_artifacts,
    aws_s3_bucket_public_access_block.vpn_artifacts,
    aws_s3_bucket_server_side_encryption_configuration.vpn_artifacts,
    aws_s3_bucket_versioning.vpn_artifacts
  ]
}

resource "aws_s3_object" "vpn_connection_info" {
  for_each = local.user_dcv_assignments
  bucket   = local.effective_bucket
  key      = "${each.key}/connection-info-${each.key}.txt"
  content = join("\n", [
    "PROJECT=${var.project_name}",
    "USER=${each.key}",
    "VPN_ENDPOINT=${local.effective_vpn_public_ip}",
    "VPN_PORT=51820",
    "DCV_USERNAME=${each.key}",
    "DCV_PORT=8443",
    "DCV_HOST_NAME=${each.value.host_name}",
    "DCV_PRIVATE_IP=${each.value.private_ip}",
    "DCV_WEB_URL=https://${each.value.private_ip}:8443",
    "REGION=${var.aws_region}",
    "S3_BUCKET=${local.effective_bucket}",
    "NOTE=RUN ANSIBLE TO GENERATE THE USER VPN PROFILE AND FINAL PASSWORD ENTRY"
  ])

  depends_on = [
    aws_s3_bucket.vpn_artifacts,
    aws_s3_bucket_ownership_controls.vpn_artifacts,
    aws_s3_bucket_public_access_block.vpn_artifacts,
    aws_s3_bucket_server_side_encryption_configuration.vpn_artifacts,
    aws_s3_bucket_versioning.vpn_artifacts
  ]
}
