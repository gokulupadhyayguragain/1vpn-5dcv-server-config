variable "project_name" {
  type        = string
  description = "Project prefix used for resource naming."
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy resources in."
}

variable "availability_zone" {
  type        = string
  description = "Single AZ used by public/private subnets."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block."
}

variable "public_subnet_cidr" {
  type        = string
  description = "Public subnet CIDR for VPN/NAT."
}

variable "private_subnet_cidr" {
  type        = string
  description = "Private subnet CIDR for DCV servers."
}

variable "vpn_private_ip" {
  type        = string
  default     = ""
  description = "Optional static private IP for VPN/NAT instance in public subnet."
}

variable "dcv_private_ips" {
  type        = list(string)
  default     = []
  description = "Optional static private IP list for DCV instances in private subnet."
}

variable "vpn_client_cidr" {
  type        = string
  description = "VPN client address pool CIDR."
}

variable "dcv_self_service_port" {
  type        = number
  default     = 8444
  description = "Internal HTTPS port exposed on the VPN host for VPN-only DCV power self-service."

  validation {
    condition     = var.dcv_self_service_port >= 1 && var.dcv_self_service_port <= 65535
    error_message = "dcv_self_service_port must be between 1 and 65535."
  }
}

variable "allowed_admin_cidr" {
  type        = string
  description = "Temporary direct SSH CIDR to VPN server."
}

variable "vpn_instance_type" {
  type        = string
  description = "EC2 instance type for VPN + NAT server."
}

variable "create_vpn_eip" {
  type        = bool
  default     = true
  description = "Whether to allocate and associate a new Elastic IP to the VPN instance."
}

variable "vpn_eip_allocation_id" {
  type        = string
  default     = ""
  description = "Optional existing Elastic IP allocation ID to associate to VPN instance."
}

variable "vpn_dcv_control_instance_profile_name" {
  type        = string
  default     = ""
  description = "Optional pre-created EC2 instance profile name for the VPN host DCV power helper. Set this when your AWS user cannot create IAM roles or instance profiles."
}

variable "dcv_instance_type" {
  type        = string
  description = "EC2 instance type for private DCV servers."
}

variable "dcv_instance_count" {
  type        = number
  description = "Number of DCV instances in private subnet; keep this equal to the VPN user count for dedicated mappings."

  validation {
    condition     = var.dcv_instance_count > 0
    error_message = "dcv_instance_count must be greater than zero."
  }
}

variable "dcv_use_spot" {
  type        = bool
  default     = true
  description = "Whether DCV instances should launch as Spot instances for lower cost."
}

variable "dcv_spot_max_price" {
  type        = string
  default     = ""
  description = "Optional max hourly Spot price for DCV instances. Empty uses the current Spot market price."
}

variable "vpn_root_volume_size_gb" {
  type        = number
  description = "Root volume size for the VPN + NAT instance."

  validation {
    condition     = var.vpn_root_volume_size_gb >= 8
    error_message = "vpn_root_volume_size_gb must be at least 8 GB."
  }
}

variable "dcv_root_volume_size_gb" {
  type        = number
  description = "Root volume size for DCV instances."

  validation {
    condition     = var.dcv_root_volume_size_gb >= 16
    error_message = "dcv_root_volume_size_gb must be at least 16 GB."
  }
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to SSH public key file used by key pair."
}

variable "ssh_key_name" {
  type        = string
  description = "Name for imported AWS EC2 key pair."
}

variable "ami_id" {
  type        = string
  default     = ""
  description = "Optional custom AMI ID; empty means latest Ubuntu 24.04 LTS."
}

variable "create_s3_bucket" {
  type        = bool
  description = "Whether Terraform should create the S3 bucket."
}

variable "s3_bucket_name" {
  type        = string
  default     = ""
  description = "Optional S3 bucket name. If empty and create enabled, generated name is used."
}

variable "vpn_users" {
  type        = list(string)
  description = "VPN client usernames used for S3 folder prefixes and profile creation."

  validation {
    condition     = length([for user in var.vpn_users : trimspace(user) if trimspace(user) != ""]) > 0
    error_message = "vpn_users must contain at least one non-empty username."
  }
}
