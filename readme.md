
# 📱 AviumUI ROM Building Guide for Motorola Cancunf

This guide will help you set up your environment and build **AviumUI** for the **Motorola Cancunf** device.


---

## 🔄 Setup Git Config



## 📁 Step 1: Create Source Directory

```bash
mkdir avium
cd avium
```

---

## 🌐 Step 2: Initialize and Sync AviumUI Source

```bash
# Initialize local repository
repo init -u https://github.com/AviumUI/android_manifests -b avium-16.2 --git-lfs

# Sync
repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
```

---

## 🔄 Step 3: Pull Git LFS Files

```bash
avium get_gms # Pull GApps (for GApps build)

repo forall -c 'git lfs pull'
```

---

## 📱 Step 4: Clone Device Trees and Vendor Repos

```bash
git clone -b sixteen-qpr2 https://github.com/sarthakroy2002/device_motorola_cancunf device/motorola/cancunf

git clone -b sixteen https://github.com/sarthakroy2002/device_motorola_cancunf-kernel device/motorola/cancunf-kernel

git clone -b sixteen-qpr2 https://github.com/sarthakroy2002/vendor_motorola_cancunf vendor/motorola/cancunf

git clone -b sixteen https://github.com/yaap/vendor_motorola_cancunf-motcamera vendor/motorola/cancunf-motcamera

git clone -b master https://github.com/cyberknight777/android_packages_apps_DisplayFeatures packages/apps/DisplayFeatures
```

---

## 🧱 Step 5: Clone HALs and SEPolicy

```bash
git clone -b sixteen https://github.com/yaap/hardware_mediatek hardware/mediatek

git clone -b sixteen https://github.com/yaap/device_mediatek_sepolicy_vndr device/mediatek/sepolicy_vndr
```

---

## 🛠️ Step 6: Rename Device Makefile

```bash
mv device/motorola/cancunf/custom_cancunf.mk device/motorola/cancunf/lineage_cancunf.mk
```

---

## 🧾 Step 7: Update Build Configuration

#### Replace all `custom` references with `lineage`:
```bash
micro device/motorola/cancunf/AndroidProducts.mk
```

#### Replace all `custom` references with `lineage` and add the flags mentioned below:
```bash
micro device/motorola/cancunf/lineage_cancunf.mk
```
```bash
# AVIUM_VERSION_APPEND_TIME_OF_DAY is a boolean flag to indicate
# whether to append time of day to the build date.
AVIUM_VERSION_APPEND_TIME_OF_DAY := false
# Maintainer
# AVIUM_MAINTAINER is a string that represents the maintainer of the build.
AVIUM_MAINTAINER := Abhi #Non breaking space

# Settings
# Soc model name
AVIUM_SETTINGS_SOC_MODEL_NAME := Mediatek® Dimensity 7010
# Device code name
AVIUM_SETTINGS_DEVICE_CODENAME := cancunf

# GMS
# WITH_GMS is a boolean flag to indicate 
# whether to include Google Mobile Services (GMS) in the build.
WITH_GMS := true
# Google Sans
# Enable this to set default fonts to Google Sans.
# This also works when building vanilla, but you
# need to sync vendor/pixel/gsans repo.
TARGET_USES_GSANS := false
# LatinIMEGooglePrebuilt
# Only works on vanilla builds,
# GMS builds will use the Google IME from GMS.
TARGET_INCLUDE_GOOGLEIME := false
TARGET_GOOGLEIME_OVERRIDE_IME := false

# Spoof Props
# Set to true to enable spoofing fake props.
# For letting apps think they are running on a locked device.
AVIUM_FORCE_SET_FAKE_PROP := true

# Blur Effect
# The blur usually enabled on Android 16 QPR2.
# If the blur not enabled, set to true to force enable blur for SystemUI.
TARGET_FORCE_ENABLE_BLUR := true
```

---

## 🧬 Step 8: Cherry-pick HardwareManager fix

```bash
git -C device/motorola/cancunf remote add 2by2 https://github.com/2by2-Project-Devices/android_device_motorola_cancunf.git
git -C device/motorola/cancunf fetch 2by2
git -C device/motorola/cancunf cherry-pick 42403f68003b2ed3de8d508042c4d7696b2f4f60

micro device/motorola/cancunf/app/MotoActions/src/org/lineageos/settings/device/TouchKeyHandler.java # Manually fix merge conflict

private static final int GESTURE_WAKELOCK_DURATION = 3000; # Add in TouchKeyHandler class

git -C device/motorola/cancunf add app/MotoActions/src/org/lineageos/settings/device/TouchKeyHandler.java
git -C device/motorola/cancunf cherry-pick --continue
```
---

## 🧪 Step 9: Pick Required Commits

```bash
git -C build/soong remote add yaap https://github.com/yaap/build_soong.git
git -C build/soong fetch yaap sixteen
git -C build/soong cherry-pick yaap/sixteen

micro build/soong/scripts/check_boot_jars/package_allowed_list.txt # Fix merge conflicts

git -C build/soong add scripts/check_boot_jars/package_allowed_list.txt

git -C build/soong cherry-pick --continue

export HOME=/home/username/avium # If using serverhive (change username)
```
---

## 🔑 Step 10: Setup Signing Keys

```bash
git clone -b main https://github.com/LineageOS/scripts.git /tmp/lineage-scripts
mkdir -p vendor/lineage-priv
mv /tmp/lineage-scripts/lineage-priv-template vendor/lineage-priv/keys
rm -rf /tmp/lineage-scripts

cd vendor/lineage-priv/keys
./keys.sh
cd ../../..
```

---

## 🚀 Step 11: Build the ROM

```bash
. build/envsetup.sh
lunch lineage_cancunf-bp4a-user
m bacon -j$(nproc --all)
```

## ⚡ Ccache & Cloud Builders (Crave / ServerHive)

> [!CAUTION]
> **Important for Crave.io builds:**
> Crave has its own built-in cluster caching system. 
> - **DO NOT** install `ccache` in Crave containers (`apt-get install ccache`).
> - **DO NOT** disable cache (`export USE_CCACHE=0`) — Crave monitors this and will permanently ban accounts that disable caching.
> - Let Crave handle caching natively without overriding `CCACHE_DIR`.

For local/standard Linux PC builds:

```bash
export USE_CCACHE=1
ccache -M 50G
```

---

## ✅ Notes

- Recommended: **Ubuntu 20.04+**, **32GB RAM or more**, **300GB+ storage**
- Final output will be in: `out/target/product/cancunf/`
- Resume build if interuppted:
  ```bash
  m bacon -j$(nproc --all)
  ```

---

Happy Building! 🚀
