#!/usr/bin/env bash
set -e

# ==============================================================================
# LineageOS 24.0 (Android 17) Build Script for Nokia 6.1 (PL2)
# Optimized for ServerHive Bare-Metal Server
# ==============================================================================

echo "========================================================"
echo "=== LineageOS 24.0 (Android 17) Build for Nokia 6.1 (PL2) ==="
echo "========================================================"

# Auto-manage build directory on ServerHive (separate from cancunf)
if [ ! -d ".repo" ]; then
    BUILD_DIR="${HOME}/pl2_build"
    echo "--> Setting up build directory in ${BUILD_DIR}..."
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"
else
    echo "--> Working inside current build repository: $(pwd)"
fi

# 1. Base Git & Ccache Environment
git config --global user.name >/dev/null 2>&1 || git config --global user.name "Zoro-15"
git config --global user.email >/dev/null 2>&1 || git config --global user.email "rajkavi4315@gmail.com"

if ! command -v ccache &>/dev/null; then
    (sudo apt-get update -y && sudo apt-get install -y ccache) 2>/dev/null || \
    (apt-get update -y && apt-get install -y ccache) 2>/dev/null || true
fi

if command -v ccache &>/dev/null; then
    export USE_CCACHE=1
    export CCACHE_EXEC=$(which ccache)
    export CCACHE_DIR="${HOME}/.ccache"
    ccache -M 50G 2>/dev/null || true
else
    export USE_CCACHE=0
    unset CCACHE_DIR
    unset CCACHE_EXEC
fi

# 2. Base Manifest Initialization
if [ ! -d ".repo" ]; then
    echo "--> Initializing LineageOS 24.0 manifest..."
    repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --depth=1
else
    echo "--> Repo already initialized. Skipping repo init."
fi

# 3. Local Manifest for Nokia 6.1 (PL2)
echo "--> Configuring PL2 local manifest..."
mkdir -p .repo/local_manifests

cat << 'EOF' > .repo/local_manifests/PL2.xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <!-- Device tree -->
  <project path="device/nokia/PL2" name="nokia-msm8998/android_device_nokia_PL2" revision="lineage-24.0" remote="github" />
  <project path="device/nokia/sdm660-common" name="nokia-msm8998/android_device_nokia_sdm660-common" revision="lineage-24.0" remote="github" />

  <!-- Kernel sources (Linux 4.19 unified tree) -->
  <project path="kernel/nokia/sdm660" name="nokia-msm8998/android_kernel_nokia_sdm660_419" revision="lineage-23.2" remote="github" />

  <!-- Proprietary vendor blobs -->
  <project path="vendor/nokia/PL2" name="nokia-msm8998/proprietary_vendor_nokia_PL2" revision="lineage-24.0" remote="github" />
  <project path="vendor/nokia/sdm660-common" name="nokia-msm8998/proprietary_vendor_nokia_sdm660-common" revision="lineage-24.0" remote="github" />
</manifest>
EOF

# 4. Source Sync
echo "--> Syncing source repositories..."
if [ -f "/opt/crave/resync.sh" ]; then
    /opt/crave/resync.sh
else
    repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags --prune
fi

# Pull Git LFS objects if needed
echo "--> Pulling Git LFS dependencies..."
repo forall -c 'git lfs pull' || true

# 5. Build Setup & Compilation
echo "--> Setting up build environment..."
source build/envsetup.sh

echo "--> Selecting target and starting compilation..."
breakfast PL2 || lunch lineage_PL2-trunk_staging-userdebug || lunch lineage_PL2-userdebug || lunch lineage_PL2-ap4a-userdebug

LOG_FILE="build_a17_PL2.log"
echo "--> Compiling LineageOS 24.0 (logging to ${LOG_FILE})..."
m bacon -j$(nproc --all) 2>&1 | tee "${LOG_FILE}" || mka bacon -j$(nproc --all) 2>&1 | tee -a "${LOG_FILE}"

# 6. Artifact Upload via GoFile
echo "========================================================"
echo "Uploading build artifacts to gofile.io..."
echo "========================================================"

upload_to_gofile() {
    local file="$1"
    local desc="$2"
    if [ -f "${file}" ]; then
        echo ">>> Uploading ${desc} (${file}) to gofile.io..."
        local resp
        resp=$(curl --silent --show-error --max-time 1800 -X POST https://upload.gofile.io/uploadfile -F "file=@${file}" 2>&1) || true
        
        local url=""
        if command -v jq &>/dev/null; then
            url=$(echo "${resp}" | jq -r '.data.downloadPage // empty' 2>/dev/null || true)
        fi
        if [ -z "${url}" ] && command -v python3 &>/dev/null; then
            url=$(python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('data', {}).get('downloadPage', ''))" <<< "${resp}" 2>/dev/null || true)
        fi
        if [ -z "${url}" ]; then
            url=$(echo "${resp}" | grep -o '"downloadPage":"[^"]*' | cut -d'"' -f4 2>/dev/null || true)
        fi

        echo "--------------------------------------------------------"
        if [ -n "${url}" ] && [[ "${url}" == http* ]]; then
            echo "${desc} Download URL: ${url}"
            echo "${url}" > "${file}.gofile.url"
        else
            echo "WARNING: Failed to parse gofile URL for ${desc}."
            echo "Raw response: ${resp}"
            echo ">>> Trying fallback to bashupload.com..."
            local fallback_url
            fallback_url=$(curl --silent --show-error --max-time 600 https://bashupload.com/ -T "${file}" 2>&1 | grep "wget" | awk '{print $2}' || true)
            if [ -n "${fallback_url}" ]; then
                echo "${desc} Fallback Download: ${fallback_url}"
                echo "${fallback_url}" > "${file}.bashupload.url"
            fi
        fi
        echo "--------------------------------------------------------"
    fi
}

OUT_DIR="out/target/product/PL2"

# Locate ROM Zip
ROM_ZIP=$(find "${OUT_DIR}" -maxdepth 1 -name "lineage-24*.zip" ! -name "*ota*" ! -name "*target_files*" 2>/dev/null | head -n 1)
[ -z "${ROM_ZIP}" ] && ROM_ZIP=$(ls "${OUT_DIR}"/*.zip 2>/dev/null | head -n 1)

if [ -n "${ROM_ZIP}" ] && [ -f "${ROM_ZIP}" ]; then
    upload_to_gofile "${ROM_ZIP}" "LineageOS 24.0 ROM Zip"
else
    echo "Notice: Final ROM zip not found. Build may have encountered an error."
    echo ">>> Uploading build log for diagnosis..."
    upload_to_gofile "${LOG_FILE}" "PL2 Build Log"
fi

# Upload kernel and recovery partitions if present
[ -f "${OUT_DIR}/boot.img" ] && upload_to_gofile "${OUT_DIR}/boot.img" "Boot Image (Kernel)"
[ -f "${OUT_DIR}/recovery.img" ] && upload_to_gofile "${OUT_DIR}/recovery.img" "Recovery Image"
[ -f "${OUT_DIR}/vendor_boot.img" ] && upload_to_gofile "${OUT_DIR}/vendor_boot.img" "Vendor Boot Image"
[ -f "${OUT_DIR}/dtbo.img" ] && upload_to_gofile "${OUT_DIR}/dtbo.img" "DTBO Image"

echo "========================================================"
echo "=== LineageOS 24.0 (PL2) Process Completed ==="
echo "========================================================"
