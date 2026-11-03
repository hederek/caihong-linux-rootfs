#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Collect Caihong (OnePlus Pad Pro) Ubuntu runtime diagnostics into one archive
# so display, input, Wi-Fi, Bluetooth, audio, power and camera problems can be
# triaged without a round trip.
#
#   bash caihong-check.sh           # writes /tmp/caihong-check-<stamp>.tar.zst
set -Eeuo pipefail

stamp=$(date -u +%Y%m%dT%H%M%SZ)
work=$(mktemp -d "${TMPDIR:-/tmp}/caihong-check.XXXXXX")
out=${1:-/tmp/caihong-check-$stamp.tar.zst}
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

save()
{
	local name=$1
	shift
	{
		echo "\$ $*"
		"$@" 2>&1 || true
	} > "$work/$name.txt"
}

save uname uname -a
save cmdline cat /proc/cmdline
save os cat /etc/os-release
save build-info cat /etc/caihong-rootfs-build-info
save uptime uptime
save systemd-failed systemctl --failed --no-pager --no-legend
save systemd-running systemctl is-system-running
save journal-errors journalctl -b -p err --no-pager -q
save dmesg dmesg
save drm sh -c 'for d in /sys/class/drm/card*-*; do [ -e "$d/status" ] && echo "$d: $(cat "$d/status") $(head -1 "$d/modes" 2>/dev/null)"; done'
save session env
save loginctl loginctl list-sessions --no-legend
save plasma sh -c 'pgrep -a -f "plasmashell|kwin_wayland|sddm|ksmserver"'
save kwin-output cat "$HOME/.config/kwinoutputconfig.json"
save touch libinput list-devices
save input sh -c 'grep -E "^(N|H|B):" /proc/bus/input/devices | head -60'
save audio wpctl status
save pactl pactl list short sinks
save alsa aplay -l
save ucm ls -R /usr/share/alsa/ucm2/conf.d/sm8650
save net nmcli device status
save net-conn nmcli -f NAME,DEVICE,STATE connection show
save wifi iw dev
save rfkill rfkill list
save bluetooth bluetoothctl list
save bluetooth-devices bluetoothctl devices
save power upower -d
save battery sh -c 'for f in /sys/class/power_supply/*; do echo "== $f"; cat "$f/uevent" 2>/dev/null; done'
save usb lsusb -tv
save modules lsmod
save sensors sh -c 'ls /sys/bus/iio/devices 2>/dev/null; iio-sensor-proxy --version 2>/dev/null || true'
save camera sh -c 'ls -l /dev/video* /dev/media* 2>/dev/null; cam -l 2>/dev/null || true; v4l2-ctl --list-devices 2>/dev/null || true'
save camera-ipa ls -l /usr/lib/libcamera/ipa 2>/dev/null
save ssd sh -c 'ls -l /usr/local/libexec/caihong-ssc /usr/local/libexec/caihong-ssc/* 2>/dev/null'
save npu cat /usr/share/caihong-npu/libdir 2>/dev/null
save disk df -h
save thermal sh -c 'for z in /sys/class/thermal/thermal_zone*; do echo "$z $(cat "$z/type" 2>/dev/null) $(cat "$z/temp" 2>/dev/null)"; done'

tar --zstd -cf "$out" -C "$work" .
echo "wrote $out"
