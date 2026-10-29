#!/usr/bin/env bash

# Nokia 6.1 (PL2) Mainline Bringup for Crave
THREADS=$(nproc --all 2>/dev/null || echo 8)

export GOMEMLIMIT=10GiB
export GOGC=40
export ALLOW_MISSING_DEPENDENCIES=true

# Init base manifest
[ -d ".repo" ] || repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --depth 1

# Configure mainline device local manifest
mkdir -p .repo/local_manifests
rm -f .repo/local_manifests/PL2.xml .repo/local_manifests/mainline_pl2.xml

cat << 'EOF' > .repo/local_manifests/mainline_pl2.xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project path="device/nokia/PL2_mainline" 
           name="Zoro-15/aosp-mainline-plate_two" 
           revision="lineage-24.0" 
           remote="github" />

  <project path="kernel/nokia/sdm630-mainline" 
           name="Zoro-15/android_kernel_nokia_sdm630-mainline" 
           revision="qcom-sdm660-7.2.y" 
           remote="github" />

  <project path="device/mainline/common" 
           name="me-cafebabe-aosp-mainline/android_device_mainline_common" 
           revision="lineage-24.0" 
           remote="github" />

  <project path="hardware/mainline/common" 
           name="me-cafebabe-aosp-mainline/android_hardware_mainline_common" 
           revision="lineage-24.0" 
           remote="github" />

  <project path="kernel/mainline/configs" 
           name="me-cafebabe-aosp-mainline/android_kernel_mainline_configs" 
           revision="lineage-24.0" 
           remote="github" />
</manifest>
EOF

# Sync sources
if [ -f "/opt/crave/resync.sh" ]; then
    /opt/crave/resync.sh || true
else
    repo sync -c -j"${THREADS}" --force-sync --no-clone-bundle --no-tags --prune || true
fi

# Ensure latest upstream commits on mainline trees
for dir in device/nokia/PL2_mainline kernel/nokia/sdm630-mainline device/mainline/common hardware/mainline/common kernel/mainline/configs; do
    if [ -d "$dir" ]; then
        REMOTE=$(git -C "$dir" remote | grep -E '^github$|^origin$' | head -n 1)
        [ -z "$REMOTE" ] && REMOTE=$(git -C "$dir" remote | head -n 1)
        BRANCH=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "lineage-24.0")
        [ "$BRANCH" = "HEAD" ] && BRANCH="lineage-24.0"
        git -C "$dir" fetch "$REMOTE" "$BRANCH" 2>/dev/null && git -C "$dir" reset --hard FETCH_HEAD 2>/dev/null || true
    fi
done

# Fix external vendor variants
[ -f "external/libjxl/Android.bp" ] && sed -i 's/vendor_available: true,//g' external/libjxl/Android.bp || true
[ -f "external/dng_sdk/Android.bp" ] && sed -i 's/vendor_available: true,//g' external/dng_sdk/Android.bp || true

# Setup build & lunch
source build/envsetup.sh 2>&1 || true

lunch lineage_PL2_mainline-trunk_staging-userdebug || \
lunch lineage_PL2_mainline-ap2a-userdebug || \
lunch lineage_PL2_mainline-userdebug || \
breakfast PL2_mainline || true

LOG_DIR="build_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOG_DIR}"

# Stage 1: Blueprint & makefile validation
m nothing -k -j"${THREADS}" 2>&1 | tee "${LOG_DIR}/stage1_nothing.log" || true

# Stage 5: Core partition builds
m bootimage systemimage vendorimage -k -j"${THREADS}" 2>&1 | tee "${LOG_DIR}/stage5_full_partitions.log" || true

# Artifact & Log Upload Helpers (GoFile / BashUpload)
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

# Package and upload logs
tar -czf "${LOG_DIR}.tar.gz" "${LOG_DIR}" 2>/dev/null || true
upload_to_gofile "${LOG_DIR}.tar.gz" "Build Logs (${LOG_DIR})"

# Upload generated partition images
OUT_DIR_PL2="out/target/product/PL2_mainline"
for img in boot.img system.img vendor.img; do
    IMG_PATH="${OUT_DIR_PL2}/${img}"
    if [ -f "${IMG_PATH}" ]; then
        upload_to_gofile "${IMG_PATH}" "Nokia 6.1 Mainline ${img}"
    fi
done

# Print build error summary if any occurred
if grep -E -iq "^FAILED:|^error:|^fatal:" "${LOG_DIR}/stage1_nothing.log" "${LOG_DIR}/stage5_full_partitions.log" 2>/dev/null; then
    echo "=== Build Error Summary ==="
    grep -E -i "^FAILED:|^error:|^fatal:" "${LOG_DIR}/stage1_nothing.log" "${LOG_DIR}/stage5_full_partitions.log" 2>/dev/null | sort -u | head -n 30 || true
    echo "Full logs available in ${LOG_DIR}.tar.gz"
fi
