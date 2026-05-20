# AWS S3 Benchmark: Native CLI vs s3fs-fuse vs S3 Files

[![OpenTofu](https://img.shields.io/badge/OpenTofu-1.0+-623CE4.svg)](https://opentofu.org/)
[![AWS Provider](https://img.shields.io/badge/AWS-5.0+-FF9900.svg)](https://registry.terraform.io/providers/hashicorp/aws/latest)

OpenTofu module that deploys EC2 + S3 to benchmark **Native S3 CLI** vs **s3fs-fuse** vs **AWS S3 Files** using [fio](https://fio.readthedocs.io/) for filesystem mounts and CLI timing for native operations.

## What This Benchmarks

The module provisions an S3 bucket, IAM roles, an EC2 instance, and (optionally) an S3 Files filesystem, then runs automated benchmarks:

| Method | Tool | Metric |
|--------|------|--------|
| **Native S3 CLI** | `aws s3 cp`, `aws s3api head-object` | Duration per operation (ms) |
| **s3fs-fuse** | [s3fs-fuse](https://github.com/s3fs-fuse/s3fs-fuse) v1.97 | fio: IOPS, throughput, latency |
| **AWS S3 Files** | `mount.s3files` (native NFS) | fio: IOPS, throughput, latency |

File sizes tested: 1 KB, 100 KB, 1 MB, 10 MB, 100 MB (configurable).

## Architecture

[![Architecture Diagram](https://excalidraw.com/#json=-qa40GhI-CnW5T5r3Dby6,FGL36noxGWkirThVJy9tug)](https://excalidraw.com/#json=-qa40GhI-CnW5T5r3Dby6,FGL36noxGWkirThVJy9tug)

```
┌───────────────────────────────────────────────────────────────┐
│                         AWS Account                            │
│                                                                │
│  ┌──────────────────────┐      ┌──────────────────────────┐  │
│  │     S3 Bucket        │◄────►│     EC2 Instance         │  │
│  │  · Versioning        │      │     t3.medium (default)  │  │
│  │  · SSE-KMS           │      │     Amazon Linux 2023     │  │
│  │  · Block Public      │      │                          │  │
│  │    Access            │      │     ├─ AWS CLI v2       │  │
│  └──────────────────────┘      │     ├─ s3fs-fuse v1.97   │  │
│           ▲                    │     └─ S3 Files (mount) │  │
│           └────── IAM Role (ec2-s3-role) ──────────────────┘ │
└───────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Prerequisites

- [OpenTofu](https://opentofu.org/) installed (or use the Nix shell below)
- AWS credentials configured with appropriate permissions
- An existing VPC and subnet
- An EC2 key pair (optional, for SSH access)

### Nix Shell

If you use [Nix](https://nixos.org/), a dev shell with all required tools is included:

```bash
# Flakes (recommended)
nix develop

# Or with nix-shell (legacy)
nix-shell
```

The shell provides:

| Tool | Purpose |
|------|---------|
| `tofu` | OpenTofu CLI (infrastructure provisioning) |
| `aws` | AWS CLI v2 (resource inspection, S3 bucket cleanup) |

Both `flake.nix` and `shell.nix` are provided, so you can use whichever fits your workflow.

### 2. Configuration

Create a `terraform.tfvars` file (see `terraform.tfvars.example`):

```hcl
region               = "eu-south-2"
bucket_name          = "my-unique-benchmark-bucket-12345"  # globally unique
vpc_id               = "vpc-xxxxxxxx"
subnet_id            = "subnet-xxxxxxxx"
key_name             = "my-key-pair"
instance_type        = "t3.micro"
file_sizes           = ["1KB", "100KB", "1MB", "10MB", "100MB"]
num_files_per_size   = 10
enable_s3_fuse      = true
enable_s3_files     = true   # Only in supported regions
ssh_cidr_blocks     = ["YOUR_IP/32"]
```

> **Note:** S3 Files is generally available in 34 AWS Regions (April 2026). Check the [AWS Region Table](https://aws.amazon.com/about-aws/global-infrastructure/regional-product-services/) for current availability.

### 3. Deploy

```bash
tofu init
tofu plan -var-file=terraform.tfvars
tofu apply -var-file=terraform.tfvars
```

After apply, the benchmark runs automatically on boot (~10 minutes including s3fs-fuse compilation).

### 4. Access Results

```bash
# SSH into the instance (use root, benchmark runs as root)
ssh -i your-key.pem root@<INSTANCE_IP>

# View results
cat /root/benchmark-results/results.csv
cat /root/benchmark-results/summary.txt
cat /root/benchmark-results/benchmark.log

# Download fio JSON logs for detailed latency percentiles
ls /root/benchmark-results/fio_*.json

# Download all results to local machine
scp -i your-key.pem root@<INSTANCE_IP>:/root/benchmark-results/* ./
```

### 5. Destroy

> **Important:** `tofu destroy` may fail due to the S3 Files filesystem lock on the bucket. Use the provided destroy script instead:

```bash
./scripts/destroy.sh
```

The script handles:
- Force-deleting the S3 Files filesystem via boto3
- Emptying the S3 bucket (including versioned objects and delete markers)
- Polling for the bucket lock to release (AWS takes 5-10 min after FS deletion)
- Cleaning up all IAM roles, security groups, and EC2 instances

Options: `--skip-confirmation`, `--keep-bucket`, `--dry-run`

## Project Structure

```
├── main.tf                     # Root module wiring
├── variables.tf                # Root variables
├── outputs.tf                  # Root outputs
├── terraform.tfvars.example    # Example configuration
├── flake.nix / shell.nix       # Nix development environments
├── LICENSE                     # MIT license
├── modules/
│   ├── s3-bucket/              # S3 bucket + versioning/encryption
│   └── ec2-benchmark/          # EC2 + IAM + S3 Files mount
├── scripts/
│   ├── benchmark.sh            # Runtime benchmark script (uploaded to S3)
│   └── destroy.sh              # Safe teardown script
├── results/
│   ├── benchmark.log           # Sanitized sample benchmark log
│   ├── summary.txt             # Sanitized sample summary
│   └── *.csv                   # Raw benchmark result data
└── examples/
    └── complete/               # Example root configuration
```

## Configuration Options

### Root Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `bucket_name` | S3 bucket name (globally unique) | *required* |
| `region` | AWS region | `"us-east-1"` |
| `vpc_id` | VPC ID | *required* |
| `subnet_id` | Subnet ID | *required* |
| `instance_type` | EC2 instance type | `"t3.medium"` |
| `key_name` | EC2 key pair name | `""` |
| `file_sizes` | File sizes to benchmark | `["1KB", "100KB", "1MB", "10MB", "100MB"]` |
| `num_files_per_size` | Files per size (CLI tests) | `10` |
| `enable_s3_fuse` | Enable s3fs-fuse benchmarks | `true` |
| `enable_s3_files` | Enable S3 Files benchmarks | `true` |
| `ssh_cidr_blocks` | Allowed SSH CIDRs | `["0.0.0.0/0"]` |

### S3 Bucket Module

| Variable | Description | Default |
|----------|-------------|---------|
| `bucket_name` | Bucket name | *required* |
| `region` | AWS region | *required* |
| `versioning_enabled` | Enable versioning | `true` |
| `block_public_access` | Block public access | `true` |

### EC2 Benchmark Module

| Variable | Description | Default |
|----------|-------------|---------|
| `bucket_name` | S3 bucket name | *required* |
| `bucket_arn` | S3 bucket ARN | *required* |
| `vpc_id` | VPC ID | *required* |
| `subnet_id` | Subnet ID | *required* |
| `instance_type` | EC2 instance type | `"t3.medium"` |
| `benchmark_config.file_sizes` | File sizes to test | `["1KB", "100KB", "1MB", "10MB", "100MB"]` |
| `benchmark_config.num_files_per_size` | Files per size | `5` |
| `benchmark_config.enable_s3_fuse` | Run s3fs-fuse tests | `true` |
| `enable_s3_files` | Run S3 Files tests | `true` |

## Benchmark Methodology

### Native S3 CLI

Measures time for sequential operations (upload, stat, download) using `date +%s%N` nanosecond timestamps over 10 files per size.

### s3fs-fuse and S3 Files

Uses [fio](https://fio.readthedocs.io/) v3.32 with `libaio` engine and `direct=1` to bypass the page cache:

- **30-second sustained runs** per size and operation
- **Sequential read/write** workloads
- Metrics: IOPS, throughput (MB/s), average latency (μs)

### Key Differences

| | s3fs-fuse | S3 Files |
|---|---|---|
| Architecture | Userspace (FUSE) | Kernel module (NFS) |
| Cache | Local disk (`use_cache=/tmp`) | EFS-backed high-performance layer |
| Consistency | Eventual (with `enable_noobj_cache`) | Strong read-after-write |
| Credentials | Manual injection of IAM temp creds | Automatic instance profile |
| Installation | Compile from source | Package (`amazon-efs-utils`) |

## Benchmark Results (t3.micro, eu-south-2)

### Sequential Read IOPS

| Size | s3fs-fuse | S3 Files | FUSE vs Files |
|------|----------:|---------:|-------------:|
| 1 KB | 30,546 | 1,452 | 21x |
| 100 KB | 13,213 | 750 | 18x |
| 1 MB | 1,590 | 30 | 53x |
| 10 MB | 114 | 16 | 7x |
| 100 MB | 14 | 2 | 7x |

### Read Latency (μs)

| Size | s3fs-fuse | S3 Files | FUSE vs Files |
|------|----------:|---------:|-------------:|
| 1 KB | 34 | 686 | 0.05x |
| 100 KB | 75 | 1,389 | 0.05x |
| 1 MB | 503 | 33,580 | 0.02x |
| 10 MB | 8,761 | 67,888 | 0.13x |
| 100 MB | 71,089 | 493,593 | 0.14x |

### Read Throughput (MB/s)

| Size | s3fs-fuse | S3 Files | FUSE vs Files |
|------|----------:|---------:|-------------:|
| 1 KB | 30.5 | 1.4 | 21x |
| 1 MB | 1,620 | 30 | 54x |
| 10 MB | 1,164 | 164 | 7x |
| 100 MB | 1,496 | 210 | 7x |

> s3fs-fuse benefits heavily from its local disk cache. For cold reads (first access without cache), performance converges toward S3 Files levels.

## Security

- **IAM**: Instance profiles only (no access keys). Least-privilege S3 permissions with resource-specific ARNs.
- **EC2**: IMDSv2 enforced (`http_tokens = "required"`), encrypted gp3 root volume, SSH restricted by `ssh_cidr_blocks`.
- **S3**: Public access blocked by default, server-side encryption enabled.
- **S3 Files**: IAM roles for both the service-linked role and EC2 instance profile, NFS access restricted to the EC2 security group.

## Troubleshooting

### S3 FUSE Mount Fails

```bash
sudo cat /root/benchmark-results/s3fs.log
# Verify IAM permissions
aws sts get-caller-identity
```

### S3 Files Mount Fails

S3 Files is only available in [certain regions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files.html). Check that `enable_s3_files = true` is set only in supported regions.

### Benchmark Script Crashes on Large Files

On instances with limited RAM (e.g., t3.micro with 1 GiB), fio tests with files ≥ 200 MB can cause OOM kills. Stick to file sizes ≤ 100 MB on memory-constrained instances, or use `instance_type = "t3.medium"` (4 GiB RAM).

### Destroy Fails with "Bucket has an S3 file system attached"

Use `./scripts/destroy.sh` instead of `tofu destroy`. It handles the S3 Files filesystem force-delete and bucket lock propagation.

## License

MIT

## References

- [AWS S3 Files Documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files.html)
- [s3fs-fuse GitHub Repository](https://github.com/s3fs-fuse/s3fs-fuse)
- [fio - Flexible I/O Tester](https://fio.readthedocs.io/)
- [OpenTofu Documentation](https://opentofu.org/docs/)
