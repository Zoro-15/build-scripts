#!/usr/bin/env bash
set -e -x

# ==============================================================================
# Crave Build Script for AviumUI (Motorola Cancunf / Moto G54)
# ==============================================================================

THREADS=$(nproc --all 2>/dev/null || echo 8)
echo "=== Starting AviumUI Build for cancunf (${THREADS} threads) ==="

# --- 1. Memory Tuning for Soong (Go) ---
export GOMEMLIMIT=10GiB
export GOGC=40

# --- 2. Sync ROM Source ---
repo init -u https://github.com/AviumUI/android_manifests -b avium-16.2 --git-lfs --depth 1
if [ -f /opt/crave/resync.sh ]; then
    /opt/crave/resync.sh
else
    repo sync -c -j"${THREADS}" --force-sync --no-clone-bundle --no-tags --prune
fi
repo forall -c 'git lfs pull' || true

# --- 3. Device Trees & Vendor Dependencies ---
# Smart sync: fetches & resets to latest upstream without re-downloading whole trees
sync_repo() {
    local dir="$1" url="$2" branch="$3"
    if [ -d "${dir}/.git" ]; then
        echo ">>> Updating ${dir} (${branch})..."
        git -C "${dir}" fetch origin "${branch}" --depth 1 && git -C "${dir}" reset --hard FETCH_HEAD
    else
        rm -rf "${dir}"
        echo ">>> Cloning ${dir} (${branch})..."
        git clone -b "${branch}" --depth 1 "${url}" "${dir}"
    fi
}

sync_repo device/motorola/cancunf           https://github.com/Zoro-15/device_motorola_cancunf           sixteen-qpr2
sync_repo device/motorola/cancunf-kernel    https://github.com/sarthakroy2002/device_motorola_cancunf-kernel  sixteen-qpr2
sync_repo vendor/motorola/cancunf           https://github.com/sarthakroy2002/vendor_motorola_cancunf    sixteen-qpr2
sync_repo vendor/motorola/cancunf-motcamera  https://github.com/yaap/vendor_motorola_cancunf-motcamera   sixteen
sync_repo packages/apps/DisplayFeatures     https://github.com/cyberknight777/android_packages_apps_DisplayFeatures master
sync_repo hardware/mediatek                https://github.com/yaap/hardware_mediatek                  sixteen
sync_repo device/mediatek/sepolicy_vndr     https://github.com/yaap/device_mediatek_sepolicy_vndr      sixteen


# --- 4. AviumUI Properties & Lunch Targets ---
DEVICE_MK="device/motorola/cancunf/lineage_cancunf.mk"
if [ -f "${DEVICE_MK}" ] && ! grep -q "AVIUM_MAINTAINER" "${DEVICE_MK}"; then
    cat << 'EOF' >> "${DEVICE_MK}"

# AviumUI Properties
TARGET_DISABLE_EPPE := true
AVIUM_VERSION_APPEND_TIME_OF_DAY := false
AVIUM_MAINTAINER := Abhi
AVIUM_SETTINGS_SOC_MODEL_NAME := Dimensity 7020
AVIUM_SETTINGS_DEVICE_CODENAME := cancunf
WITH_GMS := true
TARGET_USES_GSANS := false
TARGET_INCLUDE_GOOGLEIME := false
TARGET_GOOGLEIME_OVERRIDE_IME := false
AVIUM_FORCE_SET_FAKE_PROP := true
TARGET_FORCE_ENABLE_BLUR := true
EOF
fi

PRODUCTS_MK="device/motorola/cancunf/AndroidProducts.mk"
if [ -f "${PRODUCTS_MK}" ] && ! grep -q "COMMON_LUNCH_CHOICES" "${PRODUCTS_MK}"; then
    cat << 'EOF' >> "${PRODUCTS_MK}"

COMMON_LUNCH_CHOICES := \
    lineage_cancunf-bp4a-user \
    lineage_cancunf-bp4a-userdebug
EOF
fi

BOOT_JARS="build/soong/scripts/check_boot_jars/package_allowed_list.txt"
if [ -f "${BOOT_JARS}" ] && ! grep -q "com\.mediatek" "${BOOT_JARS}"; then
    printf "\n# MTK adds\ncom\\.mediatek\\..*\n" >> "${BOOT_JARS}"
fi

# Fix APEX allowed dependencies check for MediaTek OEM AIDL interfaces
ALLOWED_DEPS="packages/modules/common/build/allowed_deps.txt"
if [ -f "${ALLOWED_DEPS}" ] && ! grep -q "oemnetd_aidl_interface" "${ALLOWED_DEPS}"; then
    echo ">>> Adding MTK oemnetd_aidl_interface to APEX allowed dependencies..."
    echo "oemnetd_aidl_interface-java(minSdkVersion:30)" >> "${ALLOWED_DEPS}"
    (grep '^#' "${ALLOWED_DEPS}"; grep -v '^#' "${ALLOWED_DEPS}" | sort -u) > "${ALLOWED_DEPS}.tmp" && mv "${ALLOWED_DEPS}.tmp" "${ALLOWED_DEPS}"
fi

# --- 5. Signing Keys ---
if [ ! -f "vendor/lineage-priv/keys/testkey.pk8" ]; then
    echo ">>> Generating private release keys..."
    rm -rf /tmp/lineage-scripts
    git clone -b main --depth 1 https://github.com/LineageOS/scripts.git /tmp/lineage-scripts
    mkdir -p vendor/lineage-priv
    mv /tmp/lineage-scripts/lineage-priv-template vendor/lineage-priv/keys
    rm -rf /tmp/lineage-scripts
    (cd vendor/lineage-priv/keys && ./keys.sh) || true
fi

# --- 6. Build Environment & Compilation ---
# Note: Crave has a built-in cluster cache. Do not install ccache, override CCACHE_DIR, or set USE_CCACHE=0.

source build/envsetup.sh || true

# Merge split parts for GMS / wallpapers if function is available
if command -v merge_files &>/dev/null; then
    merge_files || true
fi

lunch lineage_cancunf-bp4a-user || lunch lineage_cancunf-bp4a-userdebug
m bacon -j"${THREADS}"

# --- 7. Artifact Packaging & Upload ---
echo "========================================================"
echo "Checking for build output artifacts in out/target/product/cancunf/..."

OUT_DIR="out/target/product/cancunf"

upload_to_gofile() {
    local file="$1"
    local desc="$2"
    if [ -f "${file}" ]; then
        echo ">>> Uploading ${desc} (${file}) to gofile.io..."
        local server
        server=$(curl -s --max-time 30 https://api.gofile.io/servers 2>/dev/null | grep -o '"name":"[^"]*' | head -n 1 | cut -d'"' -f4 || true)
        [ -z "${server}" ] && server="store1"

        local resp
        resp=$(curl --silent --show-error --max-time 1800 -X POST "https://${server}.gofile.io/contents/uploadfile" -F "file=@${file}" 2>&1) || true
        
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
            # Fallback to bashupload if gofile fails
            echo ">>> Trying fallback to bashupload.com..."
            local fallback_url
            fallback_url=$(curl --silent --show-error --max-time 600 https://bashupload.com/ -T "${file}" 2>&1 | grep "wget" | awk '{print $2}' || true)
            if [ -n "${fallback_url}" ]; then
                echo "${desc} Fallback Download: ${fallback_url}"
                echo "${fallback_url}" > "${file}.bashupload.url"
            fi
        fi
        echo "--------------------------------------------------------"
    else
        echo ">>> File not found: ${file}"
    fi
}

# Package & upload initial install zip for fastboot update
INITIAL_ZIP="${OUT_DIR}/avium_gms_cancunf_initial_install.zip"
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
    (cd "${WORK_DIR}" && zip -r9 "../avium_gms_cancunf_initial_install.zip" * 2>/dev/null || true)
    rm -rf "${WORK_DIR}"
    upload_to_gofile "${INITIAL_ZIP}" "Initial Install Zip (fastboot update)"
fi

# Upload individual images
upload_to_gofile "${OUT_DIR}/boot.img" "Boot Image (Kernel)"
upload_to_gofile "${OUT_DIR}/dtbo.img" "DTBO Image"
upload_to_gofile "${OUT_DIR}/vendor_boot.img" "Vendor Boot (Avium Recovery)"
[ -f "${OUT_DIR}/recovery.img" ] && upload_to_gofile "${OUT_DIR}/recovery.img" "Recovery Image"

# Upload ROM zip
ROM_ZIP=$(find "${OUT_DIR}" -maxdepth 1 -name "*.zip" ! -name "*ota*" ! -name "*target_files*" ! -name "*initial_install*" 2>/dev/null | head -n 1)
[ -z "${ROM_ZIP}" ] && ROM_ZIP=$(ls "${OUT_DIR}"/*.zip 2>/dev/null | grep -v "initial_install" | head -n 1)

if [ -n "${ROM_ZIP}" ] && [ -f "${ROM_ZIP}" ]; then
    upload_to_gofile "${ROM_ZIP}" "AviumUI ROM Zip"
else
    echo "WARNING: Could not locate final ROM ZIP in ${OUT_DIR}"
fi

echo "========================================================"
echo "=== AviumUI Crave Build Finished Successfully! ==="
echo "========================================================"
