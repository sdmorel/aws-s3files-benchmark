#!/bin/bash
set -euo pipefail

# ============================================================
# AWS S3 Benchmark Script: Native S3 CLI vs S3 FUSE vs S3 Files
# ============================================================
# Uses fio for accurate I/O benchmarking
# ============================================================

: "${BUCKET_NAME:?BUCKET_NAME is not set}"
: "${FILE_SIZES:?FILE_SIZES is not set}"
: "${NUM_FILES_PER_SIZE:?NUM_FILES_PER_SIZE is not set}"
: "${ENABLE_S3_FUSE:?ENABLE_S3_FUSE is not set}"
: "${ENABLE_S3_FILES:?ENABLE_S3_FILES is not set}"
: "${REGION:?REGION is not set}"

if [ "$ENABLE_S3_FILES" = "true" ]; then
    : "${S3_FILES_ROLE_ARN:?S3_FILES_ROLE_ARN is not set}"
    : "${S3_FILES_FS_ID:?S3_FILES_FS_ID is not set}"
fi

read -ra FILE_SIZES_ARR <<< "$FILE_SIZES"

RESULTS_DIR="/root/benchmark-results"
NATIVE_DIR="/root/native-tests"
FUSE_DIR="/root/fuse-mount"
S3FILES_DIR="/root/s3files-mount"
LOG_FILE="$RESULTS_DIR/benchmark.log"

INSTALL_LOG="$RESULTS_DIR/install.log"

mkdir -p "$RESULTS_DIR"
mkdir -p "$NATIVE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo "Starting S3 Benchmark at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo "Bucket: $BUCKET_NAME"
echo "Region: $REGION"
echo "File Sizes: ${FILE_SIZES_ARR[*]}"
echo "Files per Size: $NUM_FILES_PER_SIZE"
echo "S3 FUSE Enabled: $ENABLE_S3_FUSE"
echo "S3 Files Enabled: $ENABLE_S3_FILES"
echo "============================================================"

convert_to_bytes() {
    local size_str=$1
    local number unit
    number=$(echo "$size_str" | grep -oE '[0-9]+')
    unit=$(echo "$size_str" | grep -oE '[A-Z]+')
    case "$unit" in
        KB) echo $(( number * 1024 )) ;;
        MB) echo $(( number * 1024 * 1024 )) ;;
        GB) echo $(( number * 1024 * 1024 * 1024 )) ;;
        *)  echo "$number" ;;
    esac
}

log_result() {
    local test_name=$1
    local operation=$2
    local file_size=$3
    local bw_mbps=$4
    local iops=$5
    local lat_us=$6

    echo "$test_name,$operation,$file_size,$bw_mbps,$iops,$lat_us" >> "$RESULTS_DIR/results.csv"
    printf "  %-12s | %-15s | Size: %-6s | BW: %s MB/s | IOPS: %s | Lat: %s us\n" \
        "$test_name" "$operation" "$file_size" "$bw_mbps" "$iops" "$lat_us"
}

install_dependencies() {
    echo ""
    echo "[1/6] Installing dependencies..."
    
    dnf update -y >> "$INSTALL_LOG" 2>&1
    dnf install -y awscli fio bc git jq hostname coreutils >> "$INSTALL_LOG" 2>&1
    
    echo "AWS CLI: $(aws --version)"
    echo "fio version: $(fio --version 2>/dev/null || echo 'not installed')"
    echo "jq version: $(jq --version)"
    
    aws sts get-caller-identity --output text >> "$LOG_FILE" 2>&1 || { 
        echo "ERROR: AWS credentials not available"; exit 1; 
    }
}

init_results_csv() {
    echo ""
    echo "[2/6] Initializing results..."
    echo "test_name,operation,file_size,bw_mbps,iops,lat_us" > "$RESULTS_DIR/results.csv"
}

setup_s3_files() {
    if [ "$ENABLE_S3_FILES" != "true" ]; then
        return 0
    fi
    
    echo ""
    echo "[3/6] Setting up S3 Files..."
    
    if [ -z "$S3_FILES_ROLE_ARN" ]; then
        echo "ERROR: S3_FILES_ROLE_ARN is not set but ENABLE_S3_FILES is true"
        exit 1
    fi
    
    mkdir -p "$S3FILES_DIR"
    
    echo "S3 Files file system and mount target should be created by Terraform"
    echo "Attempting to mount existing file system using mount-s3..."
    echo "File System ID: $S3_FILES_FS_ID"
    
    echo "Mounting S3 Files using /usr/sbin/mount.s3files..."
    if ! sudo /usr/sbin/mount.s3files "$S3_FILES_FS_ID" "$S3FILES_DIR" 2>&1; then
        echo "ERROR: Failed to mount S3 Files"
        exit 1
    fi
    
    if mountpoint -q "$S3FILES_DIR"; then
        echo "S3 Files mount successful"
    else
        echo "ERROR: S3 Files mount verification failed"
        exit 1
    fi
    
    echo "$S3_FILES_FS_ID" > "$RESULTS_DIR/s3files_fs_id"
}

setup_s3_fuse() {
    if [ "$ENABLE_S3_FUSE" != "true" ]; then
        return 0
    fi
    
    echo ""
    echo "[4/6] Setting up S3 FUSE..."
    
    echo "Installing s3fs-fuse dependencies..."
    dnf install -y fuse fuse3 fuse3-devel fuse-devel libcurl-devel libxml2-devel gcc-c++ make openssl-devel autoconf automake libtool >> "$INSTALL_LOG" 2>&1
    
    cd /tmp
    if [ ! -d "s3fs-fuse" ]; then
        git clone https://github.com/s3fs-fuse/s3fs-fuse.git >> "$INSTALL_LOG" 2>&1
    fi
    cd s3fs-fuse
    ./autogen.sh >> "$INSTALL_LOG" 2>&1
    ./configure >> "$INSTALL_LOG" 2>&1
    make -j$(nproc) >> "$INSTALL_LOG" 2>&1
    make install >> "$INSTALL_LOG" 2>&1
    ldconfig
    
    # Clean up any stale mount before attempting to mount
    if mountpoint -q "$FUSE_DIR" 2>/dev/null; then
        echo "Cleaning up stale S3 FUSE mount..."
        fusermount -u "$FUSE_DIR" 2>/dev/null || umount -l "$FUSE_DIR" 2>/dev/null || true
    fi
    rm -rf "$FUSE_DIR"
    mkdir -p "$FUSE_DIR"
    
    # Export credentials as environment variables (s3fs v1.97 supports both naming conventions)
    eval $(aws configure export-credentials --format env 2>/dev/null || true)
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
        export AWS_ACCESS_KEY_ID AWSACCESSKEYID="$AWS_ACCESS_KEY_ID"
        export AWS_SECRET_ACCESS_KEY AWSSECRETACCESSKEY="$AWS_SECRET_ACCESS_KEY"
        if [ -n "$AWS_SESSION_TOKEN" ]; then
            export AWS_SESSION_TOKEN AWSSESSIONTOKEN="$AWS_SESSION_TOKEN"
        fi
    fi
    
    echo "Mounting S3 FUSE..."
    local s3fs_ok=false
    if s3fs "$BUCKET_NAME" "$FUSE_DIR" \
        -o url="https://s3.${REGION}.amazonaws.com" \
        -o region="${REGION}" \
        -o use_cache=/tmp \
        -o enable_noobj_cache \
        -o dbglevel=warn \
        -o allow_other \
        2>> "$RESULTS_DIR/s3fs.log"; then
        s3fs_ok=true
    fi
    
    sleep 3
    
    if [ "$s3fs_ok" = true ] && mountpoint -q "$FUSE_DIR"; then
        echo "S3 FUSE mount successful"
    else
        echo "WARNING: S3 FUSE mount verification failed, skipping FUSE tests"
        echo "s3fs log tail:" >> "$LOG_FILE"
        tail -20 "$RESULTS_DIR/s3fs.log" >> "$LOG_FILE" 2>/dev/null || true
        ENABLE_S3_FUSE="false"
    fi
}

generate_fio_config() {
    local target=$1
    local size_str=$2
    local mount_point=$3
    
    local size_bytes
    size_bytes=$(convert_to_bytes "$size_str")
    
    local config_file="$RESULTS_DIR/fio_${target}_${size_str}.fio"
    
    cat > "$config_file" << EOF
[global]
directory=$mount_point
filesize=$size_bytes
size=$size_bytes
ioengine=libaio
direct=1
time_based=1
runtime=30
group_reporting=1
randrepeat=0
do_verify=0
pre_read=0
name=fio-${target}-${size_str}

[seq-read]
name=seq-read
rw=read
bs=$size_bytes
iodepth=1
numjobs=1

[seq-write]
name=seq-write
rw=write
bs=$size_bytes
iodepth=1
numjobs=1
EOF
    
    echo "$config_file"
}

run_fio_benchmark() {
    local target=$1
    local size_str=$2
    local mount_point=$3
    
    echo "  Running fio benchmarks for size $size_str..."
    
    local config_file
    config_file=$(generate_fio_config "$target" "$size_str" "$mount_point")
    
    local output_file="$RESULTS_DIR/fio_${target}_${size_str}.json"
    
    fio "$config_file" --output-format=json --output="$output_file" 2>&1
    
    if [ ! -f "$output_file" ]; then
        echo "  ERROR: fio output file not created"
        return 1
    fi
    
    local bw_read bw_write iops_read iops_write lat_read lat_write
    
    # fio with group_reporting=1 combines read+write under a single job.
    # Read/write metrics may live under the same job; fall back to the first job.
    bw_read=$(jq -r '(.jobs[] | select(.jobname == "seq-read") | .read.bw) // (.jobs[0].read.bw // 0)' "$output_file" 2>/dev/null || echo "0")
    bw_write=$(jq -r '(.jobs[] | select(.jobname == "seq-write") | .write.bw) // (.jobs[0].write.bw // 0)' "$output_file" 2>/dev/null || echo "0")
    iops_read=$(jq -r '(.jobs[] | select(.jobname == "seq-read") | .read.iops) // (.jobs[0].read.iops // 0)' "$output_file" 2>/dev/null || echo "0")
    iops_write=$(jq -r '(.jobs[] | select(.jobname == "seq-write") | .write.iops) // (.jobs[0].write.iops // 0)' "$output_file" 2>/dev/null || echo "0")
    # Latency is in nanoseconds under lat_ns.mean; convert to microseconds.
    lat_read=$(jq -r '(.jobs[] | select(.jobname == "seq-read") | .read.lat_ns.mean) // (.jobs[0].read.lat_ns.mean // 0)' "$output_file" 2>/dev/null || echo "0")
    lat_write=$(jq -r '(.jobs[] | select(.jobname == "seq-write") | .write.lat_ns.mean) // (.jobs[0].write.lat_ns.mean // 0)' "$output_file" 2>/dev/null || echo "0")
    
    # Guard against null/empty values before passing to bc.
    bw_read=${bw_read:-0}
    bw_write=${bw_write:-0}
    lat_read=${lat_read:-0}
    lat_write=${lat_write:-0}
    
    local bw_read_mbps=$(echo "scale=2; $bw_read / 1000000" | bc)
    local bw_write_mbps=$(echo "scale=2; $bw_write / 1000000" | bc)
    local lat_read_us=$(echo "scale=0; $lat_read / 1000" | bc)
    local lat_write_us=$(echo "scale=0; $lat_write / 1000" | bc)
    
    log_result "$target" "seq-read" "$size_str" "$bw_read_mbps" "$iops_read" "$lat_read_us"
    log_result "$target" "seq-write" "$size_str" "$bw_write_mbps" "$iops_write" "$lat_write_us"
}

benchmark_s3_files() {
    if [ "$ENABLE_S3_FILES" != "true" ]; then
        return 0
    fi
    
    if [ ! -f "$RESULTS_DIR/s3files_fs_id" ]; then
        echo "ERROR: S3 Files not set up but ENABLE_S3_FILES is true"
        return 1
    fi
    
    echo ""
    echo "============================================================"
    echo "Running S3 Files Benchmarks"
    echo "============================================================"
    
    for size_str in "${FILE_SIZES_ARR[@]}"; do
        echo ""
        echo "--- S3 Files: File Size = $size_str ---"
        run_fio_benchmark "s3-files" "$size_str" "$S3FILES_DIR"
    done
}

benchmark_s3_fuse() {
    if [ "$ENABLE_S3_FUSE" != "true" ]; then
        echo ""
        echo "[5/6] S3 FUSE benchmarks disabled, skipping..."
        return 0
    fi
    
    if ! mountpoint -q "$FUSE_DIR" 2>/dev/null; then
        echo ""
        echo "[5/6] S3 FUSE not mounted, skipping..."
        return 0
    fi
    
    echo ""
    echo "============================================================"
    echo "Running S3 FUSE Benchmarks"
    echo "============================================================"
    
    for size_str in "${FILE_SIZES_ARR[@]}"; do
        echo ""
        echo "--- S3 FUSE: File Size = $size_str ---"
        run_fio_benchmark "s3-fuse" "$size_str" "$FUSE_DIR"
    done
}

benchmark_native_cli() {
    echo ""
    echo "============================================================"
    echo "Running Native AWS S3 CLI Benchmarks"
    echo "============================================================"
    
    for size_str in "${FILE_SIZES_ARR[@]}"; do
        local size_bytes
        size_bytes=$(convert_to_bytes "$size_str")
        
        echo ""
        echo "--- Native S3 CLI: File Size = $size_str ($size_bytes bytes) ---"
        
        echo "  Creating test file..."
        rm -rf "$NATIVE_DIR"
        mkdir -p "$NATIVE_DIR"
        
        local test_file="$NATIVE_DIR/test_${size_str}.dat"
        dd if=/dev/urandom of="$test_file" bs="$size_bytes" count=1 2>/dev/null
        
        local start_time end_time duration bw_mbps iops
        
        echo "  Testing UPLOAD..."
        start_time=$(date +%s%N)
        aws s3 cp "$test_file" "s3://$BUCKET_NAME/native/test_${size_str}.dat" --no-progress 2>/dev/null
        end_time=$(date +%s%N)
        duration=$(( (end_time - start_time) / 1000000 ))
        
        if [ "$duration" -gt 0 ]; then
            bw_mbps=$(echo "scale=2; ($size_bytes * 8) / ($duration * 1000000)" | bc)
            iops=$(echo "scale=0; 1000 / $duration" | bc)
        else
            bw_mbps="0.00"
            iops="0"
        fi
        
        log_result "native-cli" "upload" "$size_str" "$bw_mbps" "$iops" "$duration"
        
        local metadata_start metadata_end metadata_duration
        echo "  Testing STAT..."
        metadata_start=$(date +%s%N)
        for i in $(seq 1 10); do
            aws s3api head-object --bucket "$BUCKET_NAME" --key "native/test_${size_str}.dat" > /dev/null 2>&1
        done
        metadata_end=$(date +%s%N)
        metadata_duration=$(( (metadata_end - metadata_start) / 1000000 / 10 ))
        
        log_result "native-cli" "stat" "$size_str" "0.00" "0" "$metadata_duration"
        
        local download_start download_end download_duration download_bw
        echo "  Testing DOWNLOAD..."
        download_start=$(date +%s%N)
        aws s3 cp "s3://$BUCKET_NAME/native/test_${size_str}.dat" "$NATIVE_DIR/downloaded.dat" --no-progress 2>/dev/null
        download_end=$(date +%s%N)
        download_duration=$(( (download_end - download_start) / 1000000 ))
        
        if [ "$download_duration" -gt 0 ]; then
            download_bw=$(echo "scale=2; ($size_bytes * 8) / ($download_duration * 1000000)" | bc)
        else
            download_bw="0.00"
        fi
        
        log_result "native-cli" "download" "$size_str" "$download_bw" "0" "$download_duration"
        
        echo "  Cleaning up..."
        aws s3 rm "s3://$BUCKET_NAME/native/test_${size_str}.dat" --quiet 2>/dev/null || true
        rm -rf "$NATIVE_DIR"
    done
}

cleanup_mounts() {
    echo ""
    echo "[6/6] Cleaning up mounts..."
    
    if mountpoint -q "$S3FILES_DIR" 2>/dev/null; then
        echo "Unmounting S3 Files..."
        sudo umount "$S3FILES_DIR" 2>/dev/null || true
    fi
    
    if mountpoint -q "$FUSE_DIR" 2>/dev/null; then
        echo "Unmounting S3 FUSE..."
        fusermount -u "$FUSE_DIR" 2>/dev/null || umount -l "$FUSE_DIR" 2>/dev/null || true
    fi
}

generate_summary() {
    echo ""
    echo "============================================================"
    echo "Benchmark Summary"
    echo "============================================================"
    
    echo ""
    echo "Results CSV:"
    echo "------------------------------------------------------------"
    cat "$RESULTS_DIR/results.csv"
    
    echo ""
    cat > "$RESULTS_DIR/summary.txt" << EOF
===========================================================
S3 BENCHMARK SUMMARY REPORT
===========================================================

Test Configuration:
- Bucket: $BUCKET_NAME
- Region: $REGION
- File Sizes: ${FILE_SIZES_ARR[*]}
- Files per Size: $NUM_FILES_PER_SIZE
- S3 FUSE Enabled: $ENABLE_S3_FUSE
- S3 Files Enabled: $ENABLE_S3_FILES

Results saved to: $RESULTS_DIR/results.csv
fio JSON logs saved to: $RESULTS_DIR/fio_*.json

Commands:
- View CSV: cat $RESULTS_DIR/results.csv
- View summary: cat $RESULTS_DIR/summary.txt
- View full log: cat $RESULTS_DIR/benchmark.log
- View install log: cat $RESULTS_DIR/install.log

Download results:
  scp -i your-key.pem root@<INSTANCE_IP>:/root/benchmark-results/* ./

===========================================================
EOF
    
    cat "$RESULTS_DIR/summary.txt"
    
    echo ""
    echo "Benchmark completed at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "============================================================"
}

main() {
    install_dependencies
    init_results_csv
    setup_s3_files
    setup_s3_fuse
    benchmark_s3_files
    benchmark_s3_fuse
    benchmark_native_cli
    cleanup_mounts
    generate_summary
}

main "$@"