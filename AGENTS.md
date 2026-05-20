# AGENTS.md

Project guidelines for AI coding agents working in this repository.

## Project Overview

OpenTofu module that deploys EC2 + S3 to benchmark Native S3 CLI vs S3 FUSE vs AWS S3 Files.

## Build / Lint / Validate

```bash
# Format all HCL
tofu fmt -recursive

# Check format without writing
tofu fmt -check -recursive

# Validate (init first)
tofu init -backend=false && tofu validate

# Validate a module standalone
cd modules/s3-bucket && tofu init -backend=false && tofu validate
```

- Uses **OpenTofu** (`tofu` CLI), not Terraform.
- Nix dev shell available: `nix develop` or `nix-shell` (provides `tofu`, `awscli2`).
- **No automated tests.** All testing is manual via `tofu apply`.

## Manual Testing Workflow

1. `cp terraform.tfvars.example terraform.tfvars` (gitignored)
2. Fill in `vpc_id`, `subnet_id`, and a globally unique `bucket_name`.
3. `tofu init && tofu apply -var-file=terraform.tfvars`
4. Check `instance_public_ip` output.
5. Benchmark runs automatically on boot. Results are on the EC2 instance.

## Architecture & Execution Flow

- Root module calls `./modules/s3-bucket` and `./modules/ec2-benchmark`.
- The benchmark script (`scripts/benchmark.sh`) is **uploaded to S3** by the EC2 module, then downloaded by EC2 user-data. This avoids the 16 KB user-data limit.
- Script runs as **`root`** on Amazon Linux 2023 and writes results to `/root/benchmark-results/`.
- Benchmark targets:
  - **Native S3**: `aws s3 cp`, `aws s3api head-object` (measured with `date +%s%N`).
  - **S3 FUSE**: Mounts bucket with `s3fs-fuse` compiled from source, then runs `fio`.
  - **S3 Files**: Mounts with `mount.s3files` (requires `amazon-efs-utils`), then runs `fio`.

## Provider Versions

- `modules/s3-bucket/main.tf` requires AWS provider `>= 6.0`.
- `modules/ec2-benchmark/main.tf` requires AWS provider `>= 5.0`.
- Root module has no explicit provider constraint; it inherits from modules.

## Conventions & Gotchas

- **Resource naming**: Primary resource = `this` (e.g., `aws_s3_bucket.this`). Secondary = descriptive (e.g., `aws_iam_role.ec2_s3_role`).
- **S3 Files availability**: S3 Files is generally available in 34 AWS Regions (April 2026). Check the AWS Region Table for current availability. Set `enable_s3_files = true` only in supported regions or the apply will fail.
- **SSH user discrepancy**: Some outputs reference `ec2-user` and `/home/ec2-user/`, but the actual benchmark runs as `root` and writes to `/root/benchmark-results/`.
- **Script env vars**: Required vars use `: "${VAR:?message}"`; optional use `: "${VAR:-default}"`. Functions must declare `local` variables.

## Security Patterns (Enforced)

- **IAM**: Instance profiles only (no access keys). Least-privilege S3 permissions with resource-specific ARNs.
- **EC2**: IMDSv2 enforced (`http_tokens = "required"`), encrypted gp3 root volume (50 GB), SSH restricted by `ssh_cidr_blocks`.
- **S3**: Public access blocked by default, server-side encryption enabled (`aws:kms`).

## File Organization

```
├── main.tf                  # Root module wiring
├── variables.tf             # Root variables
├── outputs.tf               # Root outputs
├── terraform.tfvars.example # Example configuration (copy to terraform.tfvars)
├── terraform.tfvars         # Local values (gitignored)
├── LICENSE                  # MIT license
├── flake.nix / shell.nix    # Nix dev environments
├── flake.lock               # Nix lock file
├── modules/
│   ├── s3-bucket/           # S3 bucket + lifecycle/encryption
│   └── ec2-benchmark/       # EC2 + IAM + S3 Files mount
├── scripts/
│   ├── benchmark.sh         # Runtime benchmark script
│   └── destroy.sh           # Safe teardown script
├── results/
│   ├── benchmark.log        # Sanitized sample benchmark log
│   ├── summary.txt            # Sanitized sample summary
│   └── *.csv                # Raw benchmark result data
└── examples/
    └── complete/            # Example root configuration
```
