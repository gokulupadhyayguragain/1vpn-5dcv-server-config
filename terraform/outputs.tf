output "vpn_public_ip" {
  value       = local.effective_vpn_public_ip
  description = "Public IP of VPN/NAT server."
}

output "vpn_public_endpoint_mode" {
  value       = local.vpn_public_endpoint_mode
  description = "How the VPN public endpoint IP is provided."
}

output "vpn_public_ip_is_static" {
  value       = local.vpn_public_endpoint_mode != "ephemeral_public_ip"
  description = "Whether the VPN public IP stays stable across EC2 stop/start."
}

output "vpn_eip_allocation_id" {
  value       = local.effective_vpn_eip_allocation_id
  description = "Elastic IP allocation ID when the VPN endpoint uses an Elastic IP."
}

output "vpn_private_ip" {
  value       = aws_instance.vpn_nat.private_ip
  description = "Private IP of VPN/NAT server."
}

output "dcv_private_ips" {
  value       = [for instance in aws_instance.dcv : instance.private_ip]
  description = "Private IP list for DCV instances."
}

output "dcv_instance_ids" {
  value       = [for instance in aws_instance.dcv : instance.id]
  description = "EC2 instance IDs for DCV hosts."
}

output "dcv_hosts" {
  value       = { for index, instance in aws_instance.dcv : "dcv-${index + 1}" => instance.private_ip }
  description = "Map of DCV host names to private IPs."
}

output "dcv_user_assignments" {
  value       = { for index, user in local.normalized_vpn_users : user => aws_instance.dcv[index].private_ip }
  description = "Map of VPN users to their dedicated DCV private IP."
}

output "s3_bucket_name" {
  value       = local.effective_bucket
  description = "S3 bucket holding VPN connection artifacts."
}

output "vpn_users" {
  value       = var.vpn_users
  description = "VPN user list for profile creation."
}
