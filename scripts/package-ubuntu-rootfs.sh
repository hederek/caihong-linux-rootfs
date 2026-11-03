#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Build a Ubuntu (GNOME) rootfs image for the OnePlus Pad Pro (caihong).
#
# The image reuses the Caihong kernel and Android boot images: the bootloader
# boots the kernel straight from the Android boot partition and pivots into
# this ext4 root filesystem, so no distribution kernel or initramfs is
# installed here.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$project_dir/caihong-ubuntu-rootfs.ext4.sparse.img"}
base_archive=${2:-"$project_dir/downloads/ubuntu-base-26.04.1-base-arm64.tar.gz"}
base_archive_url=${UBUNTU_BASE_URL:-"https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/26.04.1/release/ubuntu-base-26.04.1-base-arm64.tar.gz"}
base_archive_sha256=${UBUNTU_BASE_SHA256:-5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd}
ubuntu_series=${UBUNTU_SERIES:-resolute}
ubuntu_mirror=${UBUNTU_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu}
build_mirror=${UBUNTU_BUILD_MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/ubuntu}
ubuntu_mirror=${ubuntu_mirror%/}
user_name=${UBUNTU_USER:-hederek}
host_name=${UBUNTU_HOSTNAME:-caihong}
user_password_hash=${UBUNTU_PASSWORD_HASH:-}
user_password=${UBUNTU_PASSWORD:-}
module_tree=${MODULE_TREE:-}
kernel_root=${KERNEL_ROOT:-/}
ssc_bundle=${SSC_BUNDLE:-"$project_dir/firmware-assets/caihong-ssc"}
npu_bundle=${NPU_BUNDLE:-"$project_dir/firmware-assets/caihong-npu"}
firmware_dir=${FIRMWARE_DIR:-"$project_dir/firmware"}
platform_package=${CAIHONG_PLATFORM_PACKAGE:-}
output_format=${OUTPUT_FORMAT:-ext4}
image_size_gib=${IMAGE_SIZE_GIB:-}
image_min_free_mib=${IMAGE_MIN_FREE_MIB:-3072}
image_slack_percent=${IMAGE_SLACK_PERCENT:-20}
sparse_image=${SPARSE_IMAGE:-1}
zstd_level=${ZSTD_LEVEL:-10}
extra_packages=${EXTRA_PACKAGES:-}
image_populator=${IMAGE_POPULATOR:-mke2fs}

if [[ -z $module_tree ]]; then
	module_tree=$kernel_root/lib/modules
fi

fail()
{
	echo "package-ubuntu-rootfs: $*" >&2
	exit 1
}

for tool in curl tar rsync chroot mount mountpoint umount; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
done
if [[ $output_format == ext4 ]]; then
	for tool in blkid du e2fsck mkfs.ext4 truncate; do
		command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
	done
	if [[ $sparse_image == 1 ]]; then
		command -v img2simg >/dev/null 2>&1 || fail "missing host tool: img2simg"
	fi
fi
if (( EUID != 0 )); then
	fail "run as root so ownership, ACLs and xattrs are preserved"
fi

# The kernel module tree and the matching Android boot images come from an
# installed linux-caihong payload; no distribution kernel is downloaded.
module_dirs=()
if [[ -d $module_tree ]]; then
	for candidate in "$module_tree"/*; do
		[[ -d $candidate ]] || continue
		module_dirs+=("$candidate")
	done
fi
(( ${#module_dirs[@]} == 1 )) ||
	fail "expected exactly one kernel release below $module_tree (found ${#module_dirs[@]})"
kernel_release=${module_dirs[0]##*/}
kernel_linux_caihong=$kernel_root/usr/lib/linux-caihong
[[ -f $kernel_linux_caihong/install-current-slot ]] ||
	fail "missing kernel payload: $kernel_linux_caihong/install-current-slot"
[[ -d $ssc_bundle/root/sensors ]] || fail "missing SSC bundle: $ssc_bundle"
[[ -d $npu_bundle/qnn ]] || fail "missing NPU bundle: $npu_bundle"
[[ -f $firmware_dir/SHA256SUMS ]] || fail "missing firmware bundle: $firmware_dir"

packages=(
	ca-certificates curl wget sudo locales tzdata dbus systemd-timesyncd python3
	e2fsprogs dosfstools kmod less nano vim-tiny htop jq file
	network-manager wpasupplicant wireless-regdb iw rfkill dnsmasq-base nftables hostapd
	bluez bluez-tools
	pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils alsa-ucm-conf
	upower power-profiles-daemon polkitd
	usbutils pciutils evtest i2c-tools ethtool tcpdump strace lsof
	mesa-utils vulkan-tools libgl1-mesa-dri mesa-vulkan-drivers libvulkan1
	openssh-server adb dconf-cli gcc libc6-dev libssl-dev
	fonts-noto-cjk fonts-noto-color-emoji fonts-dejavu-core
	fcitx5 fcitx5-chinese-addons fcitx5-config-qt fcitx5-frontend-gtk3
	fcitx5-frontend-gtk4 fcitx5-frontend-qt6
	plasma-desktop plasma-workspace plasma-session-wayland kwin-wayland
	plasma-integration plasma-keyboard
	plasma-nm plasma-pa plasma-widgets-addons powerdevil kscreen
	polkit-kde-agent-1 systemsettings dolphin konsole kate kdeconnect ark
	kde-spectacle breeze kde-config-gtk-style kio-extras xdg-desktop-portal-kde
	qt6-virtualkeyboard-plugin sddm sddm-theme-breeze epiphany-browser
	xserver-xorg xwayland iio-sensor-proxy kamoso gstreamer1.0-tools
	gstreamer1.0-plugins-good gstreamer1.0-plugins-base
	systemd-zram-generator
	meson ninja-build pkg-config libyaml-dev python3-jinja2 python3-ply
	python3-yaml libevent-dev libgnutls28-dev libdrm-dev libudev-dev
	libjpeg-dev libtiff-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
)
if [[ -n $extra_packages ]]; then
	read -r -a extra_packages_array <<< "$extra_packages"
	packages+=("${extra_packages_array[@]}")
fi

# Ubuntu ships a distribution kernel through these packages.  Caihong boots
# the custom Image and DTB from the Android boot partition instead.
# netplan.io and apparmor are intentionally kept: NetworkManager depends on
# netplan in this release, and masking apparmor.service is enough because the
# Caihong kernel does not enable the AppArmor LSM.
unwanted_packages=(
	snapd
	linux-image-generic linux-headers-generic linux-firmware
	initramfs-tools initramfs-tools-core initramfs-tools-bin
)

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir" "$project_dir/build" "$project_dir/downloads"
output_dir=$(cd -- "$output_dir" && pwd)
output="$output_dir/$(basename -- "$output")"
temporary="$output.part"
data_directory=$(mktemp -d "$project_dir/build/ubuntu-rootfs.XXXXXX")
cache_dir="$project_dir/build/apt-cache"
mkdir -p "$cache_dir"

if [[ -e $output || -e $temporary ]]; then
	if [[ ${FORCE:-0} != 1 ]]; then
		fail "refusing to overwrite existing output: $output (set FORCE=1 to replace it)"
	fi
	rm -f -- "$output" "$temporary"
fi

rootfs="$data_directory/rootfs"
image_mount="$data_directory/image-mount"
mkdir -p "$rootfs" "$image_mount"
rootfs_mounted=0
image_mounted=0

unmount_image()
{
	if (( image_mounted )) && mountpoint -q "$image_mount"; then
		umount "$image_mount" || return 1
	fi
	image_mounted=0
}

unmount_rootfs()
{
	if (( rootfs_mounted )); then
		local api_directory
		for api_directory in run sys proc dev; do
			if mountpoint -q "$rootfs/$api_directory"; then
				umount --lazy "$rootfs/$api_directory" || return 1
			fi
		done
		if mountpoint -q "$rootfs"; then
			umount --lazy "$rootfs" || return 1
		fi
	fi
	rootfs_mounted=0
}

save_package_cache()
{
	[[ -d $rootfs/var/cache/apt/archives ]] || return 0
	rsync -a --include='*.deb' --exclude='*' \
		"$rootfs/var/cache/apt/archives/" "$cache_dir/"
}

cleanup()
{
	status=$?
	trap - EXIT HUP INT TERM
	save_package_cache || echo "warning: failed to preserve the apt package cache" >&2
	if ! unmount_image; then
		echo "failed to unmount temporary ext4 image: $image_mount" >&2
		rm -f -- "$temporary"
		exit 1
	fi
	if ! unmount_rootfs; then
		echo "failed to unmount temporary rootfs: $rootfs" >&2
		rm -f -- "$temporary"
		exit 1
	fi
	rm -f -- "$temporary"
	if [[ ${KEEP_WORK_DIR:-0} != 1 ]]; then
		rm -rf -- "$data_directory"
	fi
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

echo "preparing the Ubuntu base root filesystem"
if [[ ! -f $base_archive ]]; then
	echo "downloading $base_archive_url"
	curl -fL --retry 4 --retry-delay 2 -o "$base_archive.part" "$base_archive_url" ||
		fail "failed to download the Ubuntu base archive"
	mv -f -- "$base_archive.part" "$base_archive"
fi
if [[ -n $base_archive_sha256 ]]; then
	actual_sha256=$(sha256sum "$base_archive" | awk '{ print $1 }')
	[[ $actual_sha256 == "$base_archive_sha256" ]] ||
		fail "Ubuntu base archive checksum mismatch: $actual_sha256"
fi
tar -xpf "$base_archive" -C "$rootfs"

# The base archive ships archive.ubuntu.com list files and no CA bundle, so
# point apt at the selected mirror and seed the certificate store before the
# first network operation.
rm -f -- "$rootfs/etc/apt/sources.list" "$rootfs"/etc/apt/sources.list.d/*.sources
rm -rf -- "$rootfs/var/lib/apt/lists"
mkdir -p "$rootfs/etc/apt/sources.list.d" "$rootfs/etc/ssl/certs"
# Bootstrap over plain HTTP: the base archive has no installed certificate
# store, so the first https fetch cannot be verified yet.
cat > "$rootfs/etc/apt/sources.list" <<EOF
deb $build_mirror $ubuntu_series main restricted universe multiverse
deb $build_mirror $ubuntu_series-updates main restricted universe multiverse
deb $build_mirror $ubuntu_series-security main restricted universe multiverse
EOF
if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
	cp /etc/ssl/certs/ca-certificates.crt "$rootfs/etc/ssl/certs/ca-certificates.crt"
fi
cat > "$rootfs/etc/apt/apt.conf.d/99-caihong-build" <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "4";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
# Keep package postinstalls from trying to start services inside the chroot.
cat > "$rootfs/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$rootfs/usr/sbin/policy-rc.d"

rm -f -- "$rootfs/etc/resolv.conf"
cp -L /etc/resolv.conf "$rootfs/etc/resolv.conf"

mount --bind "$rootfs" "$rootfs"
rootfs_mounted=1
mount --make-private "$rootfs"
for api_directory in dev proc sys; do
	mount --bind "/$api_directory" "$rootfs/$api_directory"
	mount --make-private "$rootfs/$api_directory"
done
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$rootfs/run"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
	DEBIAN_FRONTEND=noninteractive SYSTEMD_OFFLINE=1)
for variable in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
	if [[ -n ${!variable:-} ]]; then
		chroot_env+=("$variable=${!variable}")
	fi
done

in_chroot()
{
	chroot "$rootfs" "${chroot_env[@]}" "$@"
}

in_chroot /usr/bin/true || fail "unable to execute the AArch64 rootfs natively"

echo "installing Ubuntu packages"
if [[ -d $cache_dir ]]; then
	mkdir -p "$rootfs/var/cache/apt/archives/partial"
	rsync -a --include='*.deb' --exclude='*' "$cache_dir/" "$rootfs/var/cache/apt/archives/"
fi
in_chroot apt-get update -qq
in_chroot apt-get install -y --no-install-recommends "${packages[@]}"
save_package_cache

for package in "${unwanted_packages[@]}"; do
	if in_chroot dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
		echo "purging distribution package: $package"
		in_chroot apt-get purge -y "$package" || true
	fi
done
in_chroot apt-get clean
rm -rf -- "$rootfs/var/lib/apt/lists"/*
# ca-certificates is installed now, so the shipped image can use https.
cat > "$rootfs/etc/apt/sources.list" <<EOF
deb $ubuntu_mirror $ubuntu_series main restricted universe multiverse
deb $ubuntu_mirror $ubuntu_series-updates main restricted universe multiverse
deb $ubuntu_mirror $ubuntu_series-security main restricted universe multiverse
EOF
rm -f -- "$rootfs/usr/sbin/policy-rc.d"

echo "applying the Caihong Ubuntu overlay"
rsync -aHAX --numeric-ids --chown=0:0 "$project_dir/rootfs/ubuntu/" "$rootfs/"
chmod 0440 "$rootfs/etc/sudoers.d/10-hederek"

echo "configuring locale, console user and first-boot settings"
# en_US is the system locale; zh_CN is generated for Chinese input methods.
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$rootfs/etc/locale.gen"
grep -qx 'en_US.UTF-8 UTF-8' "$rootfs/etc/locale.gen" ||
	printf 'en_US.UTF-8 UTF-8\n' >> "$rootfs/etc/locale.gen"
if ! grep -qx 'zh_CN.UTF-8 UTF-8' "$rootfs/etc/locale.gen"; then
	printf 'zh_CN.UTF-8 UTF-8\n' >> "$rootfs/etc/locale.gen"
fi
in_chroot locale-gen
printf 'LANG=en_US.UTF-8\n' > "$rootfs/etc/locale.conf"
ln -sfn /usr/share/zoneinfo/Asia/Shanghai "$rootfs/etc/localtime"

printf '%s\n' "$host_name" > "$rootfs/etc/hostname"
cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$host_name
::1		localhost ip6-localhost ip6-loopback
EOF

user_groups=()
for group_name in sudo audio input video render plugdev bluetooth; do
	if in_chroot getent group "$group_name" >/dev/null; then
		user_groups+=("$group_name")
	fi
done
in_chroot useradd --create-home --shell /bin/bash \
	--groups "$(IFS=,; printf '%s' "${user_groups[*]}")" "$user_name"
if [[ -n $user_password_hash ]]; then
	printf '%s:%s\n' "$user_name" "$user_password_hash" | chroot "$rootfs" /usr/sbin/chpasswd -e
elif [[ -n $user_password ]]; then
	printf '%s:%s\n' "$user_name" "$user_password" |
		chroot "$rootfs" /usr/bin/chpasswd
else
	in_chroot passwd -d "$user_name"
fi

cat > "$rootfs/etc/fstab" <<'EOF'
# The bootloader passes root=PARTLABEL=linux rootfstype=ext4 on the kernel
# command line; only the root entry is needed here.
PARTLABEL=linux	/	ext4	defaults,noatime	0	1
EOF
: > "$rootfs/etc/machine-id"
# Input methods for Chinese text entry on the Plasma Wayland session.
if ! grep -q '^GTK_IM_MODULE=fcitx' "$rootfs/etc/environment" 2>/dev/null; then
	cat >> "$rootfs/etc/environment" <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
GLFW_IM_MODULE=ibus
EOF
fi

echo "installing the Caihong kernel modules and Android boot images"
rm -rf -- "$rootfs/usr/lib/modules"
mkdir -p "$rootfs/usr/lib/modules"
rsync -aHAX --numeric-ids --chown=0:0 "$module_tree/$kernel_release" \
	"$rootfs/usr/lib/modules/"
rm -rf -- "$rootfs/usr/lib/linux-caihong"
mkdir -p "$rootfs/usr/lib/linux-caihong"
rsync -aHAX --numeric-ids --chown=0:0 \
	"$kernel_linux_caihong/install-current-slot" \
	"$kernel_linux_caihong/kernel-release" \
	"$kernel_linux_caihong/boot-linux.img" \
	"$kernel_linux_caihong/boot-userdata.img" \
	"$rootfs/usr/lib/linux-caihong/"
for private_release in "$kernel_linux_caihong"/modules/*; do
	[[ -d $private_release ]] || continue
	if [[ ${private_release##*/} == "$kernel_release" ]]; then
		mkdir -p "$rootfs/usr/lib/linux-caihong/modules"
		rsync -aHAX --numeric-ids --chown=0:0 "$private_release" \
			"$rootfs/usr/lib/linux-caihong/modules/"
	fi
done
in_chroot depmod -a "$kernel_release"

# Optional: build the Caihong libcamera stack (QCOM ICP/BPS simple pipeline)
# when a source checkout is supplied. Ubuntu's stock libcamera has no
# Caihong tuning, so the camera stays unusable without it.
libcamera_source=${LIBCAMERA_SOURCE:-}
if [[ -n $libcamera_source ]]; then
	[[ -f $libcamera_source/meson.build ]] || fail "LIBCAMERA_SOURCE is not a libcamera tree"
	rm -rf -- "$rootfs/var/tmp/libcamera-src" "$rootfs/var/tmp/libcamera-build"
	mkdir -p "$rootfs/var/tmp/libcamera-src"
	rsync -a --delete --exclude='/.git/' --exclude='/build*/' \
		--exclude='**/__pycache__/' "$libcamera_source/" "$rootfs/var/tmp/libcamera-src/"
	printf '0.7.2+caihong\n' > "$rootfs/var/tmp/libcamera-src/.tarball-version"
	in_chroot meson setup /var/tmp/libcamera-build /var/tmp/libcamera-src \
		--buildtype=release --prefix=/usr --sysconfdir=/etc --libdir=lib \
		-Dwerror=false -Dandroid=disabled -Dcam=enabled -Ddocumentation=disabled \
		-Dgstreamer=enabled -Dipas= -Dlc-compliance=disabled -Dpipelines=simple \
		-Dpycamera=disabled -Dqcam=disabled -Dsoftisp-gpu=disabled -Dtest=false \
		-Dtracing=disabled -Dv4l2=disabled
	in_chroot ninja -C /var/tmp/libcamera-build -j 6
	in_chroot ninja -C /var/tmp/libcamera-build install
	in_chroot ldconfig
	libcamera_commit=$(git -C "$libcamera_source" rev-parse --short HEAD 2>/dev/null || echo unknown)
	install -d -m 0755 "$rootfs/usr/share/caihong"
	printf '%s\n' build=caihong version=0.7.2+caihong \
		"source_commit=$libcamera_commit" build_profile=ubuntu-rootfs-native \
		pipelines=simple ipas=none isp_backend=qcom-camera-icp-bps \
		qcam=disabled v4l2_compat=disabled \
		> "$rootfs/usr/share/caihong/libcamera-build-info"
	chmod 0644 "$rootfs/usr/share/caihong/libcamera-build-info"
	rm -rf -- "$rootfs/var/tmp/libcamera-src" "$rootfs/var/tmp/libcamera-build"
fi

echo "installing Caihong-only runtime firmware"
(cd "$firmware_dir" && sha256sum -c SHA256SUMS >/dev/null)
rm -rf -- "$rootfs/usr/lib/firmware"
mkdir -p "$rootfs/usr/lib/firmware"
rsync -aHAX --numeric-ids --chown=0:0 --exclude=SOURCE.md --exclude=SHA256SUMS \
	"$firmware_dir/." "$rootfs/usr/lib/firmware/"
"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
	"$rootfs/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"

echo "installing sensors, NPU, adb and board tools"
"$project_dir/scripts/ssc/install-rootfs.sh" "$ssc_bundle" "$rootfs"
"$project_dir/scripts/install-caihong-npu.sh" "$npu_bundle" "$rootfs"
"$project_dir/scripts/install-caihong-adbd.sh" "$rootfs" ||
	echo "warning: adbd installation failed; ADB over USB will stay unavailable" >&2

if [[ -x $kernel_root/usr/local/sbin/qbootctl ]]; then
	install -D -m 0755 "$kernel_root/usr/local/sbin/qbootctl" \
		"$rootfs/usr/local/sbin/qbootctl"
fi
install -D -m 0644 "$project_dir/tools/caihong-nvram-mac.c" \
	"$rootfs/tmp/caihong-nvram-mac.c"
in_chroot gcc -O2 -Wall -Wextra -Werror -o /usr/local/libexec/caihong-nvram-mac \
	/tmp/caihong-nvram-mac.c -lcrypto
install -D -m 0644 "$project_dir/tools/caihong-npu-info.c" \
	"$rootfs/tmp/caihong-npu-info.c"
in_chroot gcc -O2 -Wall -Wextra -Werror -o /usr/local/sbin/caihong-npu-info \
	/tmp/caihong-npu-info.c -ldl
rm -f -- "$rootfs/tmp/caihong-nvram-mac.c" "$rootfs/tmp/caihong-npu-info.c"

if [[ -n $platform_package ]]; then
	install -d -m 0755 "$rootfs/tmp/caihong-packages"
	install -m 0644 "$platform_package" \
		"$rootfs/tmp/caihong-packages/${platform_package##*/}"
	CAIHONG_PLATFORM_ROOT="$rootfs" \
		"$project_dir/packaging/caihong-platform/install-caihong-platform" \
		"$rootfs/tmp/caihong-packages/${platform_package##*/}"
	rm -rf -- "$rootfs/tmp/caihong-packages"
fi

echo "enabling services"
systemctl --root="$rootfs" disable systemd-networkd.service \
	systemd-networkd-wait-online.service 2>/dev/null || true
systemctl --root="$rootfs" mask apparmor.service 2>/dev/null || true
systemctl --root="$rootfs" mask systemd-networkd.service \
	systemd-networkd-wait-online.service 2>/dev/null || true
systemctl --root="$rootfs" enable NetworkManager.service bluetooth.service \
	power-profiles-daemon.service ssh.service sddm.service || true
systemctl --root="$rootfs" set-default graphical.target
systemctl --root="$rootfs" disable hostapd.service wpa_supplicant.service 2>/dev/null || true
for unit in caihong-grow-rootfs.service caihong-keyboard.service \
	caihong-bluetooth-autostart.service caihong-adbd.service \
	caihong-hardware-mac.service caihong-mark-boot-successful.service \
	caihong-ssc.service caihong-clean-pogo-kde.service \
	caihong-fix-kwin-brightness.service caihong-pen-autoconnect.timer \
	caihong-pen-charge.timer caihong-pen-pair.timer \
	fstrim.timer; do
	systemctl --root="$rootfs" enable "$unit" 2>/dev/null ||
		echo "warning: could not enable $unit" >&2
done
if [[ -f $rootfs/usr/lib/systemd/system/iio-sensor-proxy.service ]]; then
	systemctl --root="$rootfs" enable iio-sensor-proxy.service 2>/dev/null || true
fi

cat > "$rootfs/etc/caihong-rootfs-build-info" <<EOF
device=caihong
distribution=ubuntu
ubuntu_release=26.04.1
architecture=arm64
boot_roots=PARTLABEL=linux,PARTLABEL=userdata
boot_kernel=android-boot-v2-direct-root
package_mirror=$ubuntu_mirror
kernel_release=$kernel_release
EOF
chmod 0644 "$rootfs/etc/caihong-rootfs-build-info"

echo "verifying the assembled root filesystem"
[[ -x $rootfs/usr/bin/plasmashell ]] || fail "plasmashell is missing"
[[ -x $rootfs/usr/bin/kwin_wayland ]] || fail "kwin_wayland is missing"
[[ -x $rootfs/usr/bin/sddm ]] || fail "sddm is missing"
[[ -f $rootfs/usr/share/wayland-sessions/plasma.desktop ]] ||
	fail "the Plasma Wayland session file is missing"
[[ -x $rootfs/usr/sbin/NetworkManager ]] || fail "NetworkManager is missing"
[[ -f $rootfs/usr/lib/modules/$kernel_release/modules.dep ]] ||
	fail "kernel module dependencies were not generated"
[[ -f $rootfs/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin ]] ||
	fail "audio DSP topology is missing"
[[ -d $rootfs/usr/lib/firmware/qcom/sm8650 ]] || fail "SM8650 firmware is missing"
if [[ -e $rootfs/boot/vmlinuz || -e $rootfs/boot/initrd.img ]]; then
	fail "a distribution kernel was installed into the root filesystem"
fi
if [[ -e $rootfs/usr/lib/firmware/ath12k ]]; then
	echo "Wi-Fi firmware present"
fi

rm -f -- "$rootfs/etc/resolv.conf"
printf 'nameserver 1.1.1.1\n' > "$rootfs/etc/resolv.conf"
unmount_rootfs

echo "creating $output"
if [[ $output_format == tar ]]; then
	bsdtar --acls --xattrs -cpf - -C "$rootfs" . |
		zstd -T0 "-$zstd_level" -o "$temporary"
	zstd -t "$temporary"
else
	used_bytes=$(du -sx --block-size=1 "$rootfs" | awk 'NR == 1 { print $1 }')
	percent_free=$((used_bytes * image_slack_percent / 100))
	minimum_free=$((image_min_free_mib * 1024 * 1024))
	if (( percent_free < minimum_free )); then
		free_bytes=$minimum_free
	else
		free_bytes=$percent_free
	fi
	required_bytes=$((used_bytes + free_bytes))
	if [[ -n $image_size_gib ]]; then
		image_bytes=$((image_size_gib * 1024 * 1024 * 1024))
		(( image_bytes >= required_bytes )) ||
			fail "IMAGE_SIZE_GIB=$image_size_gib is too small for the assembled tree"
	else
		round_bytes=$((256 * 1024 * 1024))
		image_bytes=$(((required_bytes + round_bytes - 1) / round_bytes * round_bytes))
	fi

	raw_image="$data_directory/rootfs.raw.img"
	truncate -s "$image_bytes" "$raw_image"
	case "$image_populator" in
		mke2fs)
			mkfs.ext4 -q -F -L linux -m 0 \
				-E lazy_itable_init=0,lazy_journal_init=0 -d "$rootfs" "$raw_image"
			;;
		mount)
			mkfs.ext4 -q -F -L linux -m 0 \
				-E lazy_itable_init=0,lazy_journal_init=0 "$raw_image"
			mount -o loop "$raw_image" "$image_mount"
			image_mounted=1
			rsync -aHAX --numeric-ids "$rootfs/" "$image_mount/"
			sync -f "$image_mount"
			unmount_image
			;;
		*) fail "IMAGE_POPULATOR must be mke2fs or mount" ;;
	esac
	e2fsck -fn "$raw_image"
	[[ $(blkid -s LABEL -o value "$raw_image") == linux ]] ||
		fail "generated ext4 image does not have LABEL=linux"
	if [[ $sparse_image == 1 ]]; then
		img2simg "$raw_image" "$temporary"
	else
		mv -- "$raw_image" "$temporary"
	fi
	echo "ext4 logical size: $image_bytes bytes"
fi
mv -- "$temporary" "$output"

echo "created $output"
du -h "$output"
sha256sum "$output"
