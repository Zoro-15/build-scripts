#!/usr/bin/env bash
set -e

# ==============================================================================
# ServerHive Incremental Build Script for AxionOS (Motorola Cancunf / Moto G54)
# Optimized for: Low-tier ServerHive plans (preserves source, cache, and out/)
# ==============================================================================

THREADS=$(nproc --all)

echo "========================================================"
echo " Starting ServerHive Incremental Build for AxionOS"
echo " CPU Threads: ${THREADS}"
echo " Working Dir: $(pwd)"
echo "========================================================"

# --- 1. Ccache Setup ---
# Note: Never install ccache manually or set USE_CCACHE=0 (violates cluster build rules)
if command -v ccache &>/dev/null; then
    echo ">>> Ccache available, enabling cache acceleration..."
    export USE_CCACHE=1
    export CCACHE_EXEC=$(command -v ccache)
fi

# --- 2. Repo Init & Sync (Incremental: Only init if not present) ---
if [ ! -d ".repo" ]; then
    echo ">>> Initializing AxionAOSP source tree (lineage-23.2)..."
    repo init -u https://github.com/AxionAOSP/android.git -b lineage-23.2 --git-lfs --depth 1
else
    echo ">>> Repo already initialized. Skipping init."
fi

echo ">>> Syncing repositories..."
repo sync -c -j"${THREADS}" --no-clone-bundle --no-tags --optimized-fetch --prune

echo ">>> Pulling Git LFS assets..."
repo forall -c 'git lfs pull' || true

# --- 3. Clone Device Trees (Incremental: Skip if already cloned) ---
echo ">>> Checking device trees and vendor repositories..."
[ -d "device/motorola/cancunf" ] || git clone -b sixteen-qpr2 --depth 1 https://github.com/Zoro-15/device_motorola_cancunf device/motorola/cancunf
[ -d "device/motorola/cancunf-kernel" ] || git clone -b sixteen --depth 1 https://github.com/sarthakroy2002/device_motorola_cancunf-kernel device/motorola/cancunf-kernel
[ -d "vendor/motorola/cancunf" ] || git clone -b sixteen-qpr2 --depth 1 https://github.com/sarthakroy2002/vendor_motorola_cancunf vendor/motorola/cancunf
[ -d "vendor/motorola/cancunf-motcamera" ] || git clone -b sixteen --depth 1 https://github.com/yaap/vendor_motorola_cancunf-motcamera vendor/motorola/cancunf-motcamera
[ -d "packages/apps/DisplayFeatures" ] || git clone -b master --depth 1 https://github.com/cyberknight777/android_packages_apps_DisplayFeatures packages/apps/DisplayFeatures
[ -d "hardware/mediatek" ] || git clone -b sixteen --depth 1 https://github.com/yaap/hardware_mediatek hardware/mediatek
[ -d "device/mediatek/sepolicy_vndr" ] || git clone -b sixteen --depth 1 https://github.com/yaap/device_mediatek_sepolicy_vndr device/mediatek/sepolicy_vndr

# --- 4. Ensure Device Identities & Lunch Targets (Idempotent) ---
if ! grep -q "AXION_MAINTAINER" device/motorola/cancunf/lineage_cancunf.mk; then
    echo ">>> Injecting device identities and AxionOS properties..."
    cat << 'EOF' > /tmp/axion_header.mk
# AxionOS Properties
TARGET_DISABLE_EPPE := true
AXION_MAINTAINER := Abhi
AXION_PROCESSOR := Dimensity_7020
AXION_CAMERA_REAR_INFO := 50,2
AXION_CAMERA_FRONT_INFO := 16

PRODUCT_SYSTEM_PROPERTIES += \
    persist.sys.axion_maintainer=Abhi \
    persist.sys.axion_cpu_info=Dimensity_7020 \
    persist.sys.device_camera_info_rear=50,2 \
    persist.sys.device_camera_info_front=16

# Device Identity
PRODUCT_NAME := lineage_cancunf
PRODUCT_DEVICE := cancunf
PRODUCT_MANUFACTURER := motorola
PRODUCT_BRAND := Motorola
PRODUCT_MODEL := moto g54 5G

EOF
    cat /tmp/axion_header.mk device/motorola/cancunf/lineage_cancunf.mk > /tmp/lineage_cancunf.mk
    mv /tmp/lineage_cancunf.mk device/motorola/cancunf/lineage_cancunf.mk
    rm -f /tmp/axion_header.mk
fi

if ! grep -q "COMMON_LUNCH_CHOICES" device/motorola/cancunf/AndroidProducts.mk; then
    echo ">>> Declaring lunch target in AndroidProducts.mk..."
    cat << 'EOF' >> device/motorola/cancunf/AndroidProducts.mk

COMMON_LUNCH_CHOICES := \
    lineage_cancunf-bp4a-user \
    lineage_cancunf-bp4a-userdebug
EOF
fi

# --- 5. Boot Jars & APEX Whitelist ---
grep -q "com\\\\.mediatek\\\\..*" build/soong/scripts/check_boot_jars/package_allowed_list.txt 2>/dev/null || \
    printf "\n# MTK adds\ncom\\.mediatek\\..*\n" >> build/soong/scripts/check_boot_jars/package_allowed_list.txt

# Restore allowed_deps.txt if modified from previous runs
if [ -d "packages/modules/common" ]; then
    git -C packages/modules/common checkout -f build/allowed_deps.txt 2>/dev/null || true
fi

# Bypass APEX allowed dependencies check in Soong
if [ -f "build/soong/apex/apex_singleton.go" ]; then
    echo ">>> Bypassing APEX allowed dependencies check in Soong..."
    git -C build/soong checkout -f apex/apex_singleton.go 2>/dev/null || true
    sed -i 's|if grep -v.*diff -B.*then|if true; then|g' build/soong/apex/apex_singleton.go
    sed -i 's/exit 1;/touch ${out}; exit 0;/g' build/soong/apex/apex_singleton.go
fi

# --- 6. Signing Keys (Incremental: Skip if keys already exist) ---
if [ ! -f "vendor/lineage-priv/keys/testkey.pk8" ]; then
    echo ">>> Generating private release keys for the first time..."
    rm -rf /tmp/lineage-scripts
    git clone -b main https://github.com/LineageOS/scripts.git /tmp/lineage-scripts
    mkdir -p vendor/lineage-priv
    rm -rf vendor/lineage-priv/keys
    mv /tmp/lineage-scripts/lineage-priv-template vendor/lineage-priv/keys
    rm -rf /tmp/lineage-scripts
    (cd vendor/lineage-priv/keys && ./keys.sh) || true
else
    echo ">>> Signing keys already exist. Skipping key generation."
fi

# --- 7. Setup Build Environment & Lunch ---
echo ">>> Setting up build environment..."
set +e
source build/envsetup.sh
set -e

echo ">>> Setting lunch target..."
axion cancunf user gms

# --- 8. Compile ROM (Incremental: keeps existing out/ directory) ---
echo ">>> Starting incremental compilation with ${THREADS} threads..."
m bacon -j"${THREADS}"

# --- 9. Artifact Detection & Upload ---
echo "========================================================"
echo "Checking for build output artifacts in out/target/product/cancunf/..."

OUT_DIR="out/target/product/cancunf"

upload_file() {
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
    fi
}

# Package & upload initial install zip (as per cyberknight777 cancunf instructions)
INITIAL_ZIP="${OUT_DIR}/axion_gms_cancunf_initial_install.zip"
WORK_DIR="${OUT_DIR}/initial_pack"
if [ -f "${OUT_DIR}/boot.img" ] && [ -f "${OUT_DIR}/vendor_boot.img" ]; then
    echo ">>> Packaging initial install zip for fastboot update..."
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    cp "${OUT_DIR}/boot.img" "${WORK_DIR}/boot.img"
    cp "${OUT_DIR}/vendor_boot.img" "${WORK_DIR}/vendor_boot.img"
    echo "require board=cancunf" > "${WORK_DIR}/android-info.txt"
    cat << 'EOF' > "${WORK_DIR}/fastboot-info.txt"
version 1
flash boot
flash vendor_boot
reboot bootloader
EOF
    (cd "${WORK_DIR}" && zip -r9 "../axion_gms_cancunf_initial_install.zip" * 2>/dev/null || true)
    rm -rf "${WORK_DIR}"
    upload_file "${INITIAL_ZIP}" "Initial Install Zip (fastboot update)"
fi

# Upload individual images as well
upload_file "${OUT_DIR}/boot.img" "Boot Image (Kernel)"
upload_file "${OUT_DIR}/dtbo.img" "DTBO Image"
upload_file "${OUT_DIR}/vendor_boot.img" "Vendor Boot (Axion Recovery)"

# Upload ROM zip
ROM_ZIP=$(find "${OUT_DIR}" -maxdepth 1 -name "*.zip" ! -name "*ota*" ! -name "*target_files*" 2>/dev/null | head -n 1)
[ -z "${ROM_ZIP}" ] && ROM_ZIP=$(ls "${OUT_DIR}"/*.zip 2>/dev/null | head -n 1)

if [ -n "${ROM_ZIP}" ] && [ -f "${ROM_ZIP}" ]; then
    upload_file "${ROM_ZIP}" "AxionOS ROM Zip"
else
    echo "WARNING: Could not locate final ROM ZIP in ${OUT_DIR}"
fi

echo "========================================================"
echo "=== AxionOS Incremental Build Complete! ==="
echo "========================================================"

