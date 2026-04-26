# DCV Improvised Final Runbook

Last verified: 2026-04-26

## Final Verified State

The project passed a full lifecycle test:

1. Destroyed the existing Terraform stack.
2. Preserved the VPN Elastic IP for reuse.
3. Recreated all infrastructure.
4. Reconfigured VPN and all five DCV hosts with Ansible.
5. Ran validation successfully with zero failed hosts.
6. Regenerated and emailed fresh user artifacts.

Current endpoint:

- VPN public IP: `13.205.147.210`
- VPN EIP allocation ID: `eipalloc-012b1a18643dd189a`
- VPN public endpoint mode: `existing_elastic_ip`
- S3 artifact bucket: `5dcv-1-vpn-server-tf-state-file-bucket`

Current user-to-host mapping:

| User | VPN Client IP | DCV Private IP | DCV URL |
| --- | --- | --- | --- |
| `user1` | `10.8.0.2` | `10.20.2.10` | `https://10.20.2.10:8443` |
| `user2` | `10.8.0.3` | `10.20.2.11` | `https://10.20.2.11:8443` |
| `user3` | `10.8.0.4` | `10.20.2.12` | `https://10.20.2.12:8443` |
| `user4` | `10.8.0.5` | `10.20.2.13` | `https://10.20.2.13:8443` |
| `user5` | `10.8.0.6` | `10.20.2.14` | `https://10.20.2.14:8443` |

## Normal User Flow

Each user must use only their own WireGuard profile and connection info file.

1. Import `artifacts/<user>/<user>.conf` into WireGuard.
2. Connect WireGuard.
3. Wait a few minutes if the assigned DCV instance was stopped.
4. Open the DCV URL from `artifacts/<user>/connection-info-<user>.txt`.
5. Log in with the matching username and password from the connection info file.

Auto-start behavior:

- When a user reconnects to VPN, the VPN watcher detects the active WireGuard peer.
- It starts only that user's assigned DCV instance.
- AWS Spot start can take a few minutes.
- If Spot capacity is temporarily unavailable, the watcher retries on the next timer run.

Auto-stop behavior:

- DCV idle disconnect is configured for 10 minutes.
- Stopped DCV hosts reduce cost.
- The VPN server remains running so users can reconnect and trigger auto-start.

## Isolation Model

Each user has a dedicated DCV instance.

Isolation is enforced in two layers:

- Terraform security groups allow DCV web port `8443` only from the matching user's deterministic VPN `/32`.
- UFW on each DCV host allows only the matching user's VPN client IP to port `8443`.

DCV-to-DCV behavior:

- Peer SSH `22` between DCV hosts is denied.
- Peer DCV desktop `8443` between DCV hosts is denied.
- Private app/test traffic between DCV hosts remains allowed, so ports like `3000` can be used for development tests.

## Main Commands

Interactive menu:

```bash
./start.sh
```

Full create and configure:

```bash
./create.sh
```

Terraform only:

```bash
./scripts/terraform_apply.sh
```

Ansible only:

```bash
./scripts/run_ansible.sh
```

Validation:

```bash
source scripts/load_local_tooling.sh
source scripts/load_env.sh .env
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventories/hosts.yml ansible/playbooks/validate.yml
```

Send current artifacts by email:

```bash
RESEND_API_KEY='...' \
RESEND_TO='gokulupadhyayguragain@gmail.com' \
RESEND_FROM='DCV Access <onboarding@resend.dev>' \
./scripts/email_artifacts_resend.sh
```

## Destroy And Recreate

Recommended destroy/recreate while keeping the same VPN public IP:

```bash
./destroy.sh
./create.sh
```

When `destroy.sh` asks about destroying the Elastic IP, press `Enter` or answer `n` to preserve it.

That changes `.env` to:

```bash
CREATE_VPN_EIP=false
VPN_EIP_ALLOCATION_ID=eipalloc-012b1a18643dd189a
```

The next `./create.sh` reuses the same static public IP.

Only answer `y` to the Elastic IP prompt when you intentionally want to release the static VPN public IP permanently.

## Golden AMI Status

Current verified rebuild used the base Ubuntu AMI because `.env` has:

```bash
AMI_ID=
```

So the normal rebuild is proven, but it is slow because every DCV host installs Ubuntu desktop, Chrome, VS Code, Docker, Flutter, and NICE DCV from scratch.

Golden AMI automation exists, but it is not automatically run by `./create.sh`.

There are two AMI scripts:

```bash
./scripts/create_golden_ami.sh --dcv-index 1
./scripts/build_dcv_golden_ami.sh
```

Recommended practical path after a successful full build:

```bash
./scripts/create_golden_ami.sh --dcv-index 1
```

That creates an AMI from a configured DCV host and writes the new AMI ID into `.env`:

```bash
AMI_ID=ami-...
DCV_USE_SPOT=true
```

Future `./create.sh` runs will then launch DCV hosts from that AMI. Ansible still runs afterward to apply user passwords, firewall rules, VPN artifacts, watchers, and validation.

Use the golden AMI when you want faster Spot replacement or faster destroy/create cycles.

## Final Test Results

The final lifecycle test completed successfully:

- Terraform destroy completed after preserving the VPN EIP.
- Terraform create completed with `35 added, 0 changed, 0 destroyed`.
- VPN was recreated on the same public IP: `13.205.147.210`.
- All five DCV Spot instances were recreated with fixed private IPs.
- VPN profile generation completed.
- S3 artifact upload completed.
- NICE DCV server and add-on package installation completed in the correct order.
- DCV users and default sessions were created.
- Idle-stop and Spot interruption watchers were installed.
- Validation passed across `vpn-server` and all five DCV hosts.
- Fresh artifacts were emailed to `gokulupadhyayguragain@gmail.com`.

Fresh email delivery ID:

```text
7941f672-42c6-4eae-91bc-013592ba3c27
```

## Important Notes

- The Resend API key was pasted during operations. Rotate it in Resend.
- Fresh WireGuard profiles are generated after every full destroy/create. Old emailed `.conf` files should be discarded after a rebuild.
- Keep `VPN_EIP_ALLOCATION_ID` if you want the same VPN public IP.
- Keep `DCV_PRIVATE_IPS_CSV` unchanged if you want stable per-user DCV private IPs.
- Do not delete the pre-created instance profile `dcv-improvised-vpn-dcv-control-profile` unless you also restore IAM creation permissions.
