#!/usr/bin/env bash
set -e

# ==============================================================================
# Script to Generate Initial Install Zip for Moto G54 (cancunf)
# Based on Cyberknight777 specifications
# ==============================================================================

# Detect working directory
if [ -f "boot.img" ] && [ -f "vendor_boot.img" ]; then
    OUT_DIR="."
elif [ -d "out/target/product/cancunf" ]; then
    OUT_DIR="out/target/product/cancunf"
elif [ -d "../target/product/cancunf" ]; then
    OUT_DIR="../target/product/cancunf"
else
    echo "ERROR: Could not find build output directory."
    echo "Please run this script from ~/cancunf_build or ~/cancunf_build/out/target/product/cancunf"
    exit 1
fi

echo "========================================================"
echo " Packaging Initial Install Zip for cancunf"
echo "========================================================"

# 1. Locate the ROM zip
ROM_ZIP=$(find "${OUT_DIR}" -maxdepth 1 -name "*.zip" ! -name "*ota*" ! -name "*target_files*" ! -name "*initial_install*" 2>/dev/null | head -n 1)
[ -z "${ROM_ZIP}" ] && ROM_ZIP=$(ls "${OUT_DIR}"/*.zip 2>/dev/null | grep -v "initial_install" | head -n 1)

if [ -z "${ROM_ZIP}" ]; then
    echo "ERROR: Could not find compiled ROM zip in ${OUT_DIR}"
    exit 1
fi

echo "Found ROM Zip: ${ROM_ZIP}"
ZIP_NAME=$(basename "${ROM_ZIP}")

# Determine flavor (GMS vs Vanilla)
if echo "${ZIP_NAME}" | grep -qi "gms"; then
    VARIANT="gms"
else
    VARIANT="vanilla"
fi

INITIAL_ZIP_NAME="axion_${VARIANT}_cancunf_initial_install.zip"
WORK_DIR="${OUT_DIR}/initial_pack"

echo "Target Initial Zip: ${INITIAL_ZIP_NAME}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# 2. Get boot.img and vendor_boot.img
if [ -f "${OUT_DIR}/boot.img" ] && [ -f "${OUT_DIR}/vendor_boot.img" ]; then
    echo ">>> Using freshly built boot.img and vendor_boot.img from out directory..."
    cp "${OUT_DIR}/boot.img" "${WORK_DIR}/boot.img"
    cp "${OUT_DIR}/vendor_boot.img" "${WORK_DIR}/vendor_boot.img"
else
    echo ">>> Extracting boot.img and vendor_boot.img from ${ROM_ZIP} using payload-dumper-go..."
    if ! command -v payload-dumper-go &> /dev/null; then
        echo ">>> Installing payload-dumper-go..."
        curl -sL https://github.com/ssut/payload-dumper-go/releases/download/1.3.0/payload-dumper-go_1.3.0_linux_amd64.tar.gz | tar -xz -C /tmp
        PAYLOAD_DUMPER="/tmp/payload-dumper-go"
    else
        PAYLOAD_DUMPER="payload-dumper-go"
    fi
    "${PAYLOAD_DUMPER}" -p boot,vendor_boot -o "${WORK_DIR}" "${ROM_ZIP}"
fi

# 3. Create android-info.txt
echo ">>> Creating android-info.txt..."
echo "require board=cancunf" > "${WORK_DIR}/android-info.txt"

# 4. Create fastboot-info.txt (Cyberknight specification)
echo ">>> Creating fastboot-info.txt..."
cat << 'EOF' > "${WORK_DIR}/fastboot-info.txt"
version 1
flash boot
flash vendor_boot
reboot bootloader
EOF

# 5. Build zip with -r9
echo ">>> Zipping initial install package..."
(cd "${WORK_DIR}" && zip -r9 "../${INITIAL_ZIP_NAME}" *)

FINAL_INITIAL_ZIP="${OUT_DIR}/${INITIAL_ZIP_NAME}"
echo "SUCCESS: Created ${FINAL_INITIAL_ZIP}"
rm -rf "${WORK_DIR}"

# 6. Upload artifacts to gofile.io
echo "========================================================"
echo "Uploading artifacts to gofile.io..."

upload_file() {
    local file="$1"
    local desc="$2"
    if [ -f "${file}" ]; then
        echo ">>> Uploading ${desc} (${file})..."
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

upload_file "${FINAL_INITIAL_ZIP}" "Initial Install Zip"
[ -f "${OUT_DIR}/boot.img" ] && upload_file "${OUT_DIR}/boot.img" "boot.img (Kernel)"
[ -f "${OUT_DIR}/vendor_boot.img" ] && upload_file "${OUT_DIR}/vendor_boot.img" "vendor_boot.img (Axion Recovery)"
upload_file "${ROM_ZIP}" "AxionOS ROM Zip"

echo "========================================================"
echo "All done! Ready to flash on your device."
echo "========================================================"
