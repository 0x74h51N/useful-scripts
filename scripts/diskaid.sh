#!/usr/bin/env bash
set -euo pipefail

declare -A MSG=(
	[must_root]="This script must be run as root or with sudo."
	[missing_dep]="This script using %s, it is missing, install it!"
	[cannot_read_utils]="Error: Cannot locate or read utils file at %s"
	[invalid_options]="Invalid options. Use -h/--help for usage."
	[missing_input]="Error: missing -m|--mnt-pnt <mount_point> or -p| --partition <disk> or -h/--help"
	[new_mnt]="Mount point not found, creating mount point: %s"
	[new_mnt_err]="Unable to create mount point %s"
	[new_mnt_mnt_err]="Failed to mount %s to %s"
	[unable_determine_device]="Unable to determine device for mount point '%s'."
	[checking_partition]="Checking device partition for %s"
	[health_check]="Healt check initiated for %s"
	[test_type_err]="Invalid self-test argument: '%s'. Must be 'short' or 'long'."
	[long_test_inf]="Long self-test may take up to an hour and could worsen failing disks."
	[long_test_appr]="Proceed with long self-test on this device? (y/N): "
	[long_test_abrt]="Self-test aborted."
	[test_init]="Smart self test initiated for %s"
	[wait_info]="Waiting %s seconds for test to complete..."
	[wait_err]="Test may have already completed or invalid date format."
	[health_check_warn]="Healt check warning: \n%s"
	[badlock_info]="Badlock check initiated"
	[disk_in_use]="Please stop using this disk '%s': %s"
	[unmounting]="Unmounting %s volume at %s"
	[failed_unmount]="Failed to unmount %s"
	[creating_mountdir]="Creating mount point directory %s"
	[failed_mkdir]="Failed to mkdir %s"
	[running_fsck]="Running fsck.ext4 on %s"
	[dry_check]="Running dry‑run filesystem check (no‑write)…"
	[fix_apprv]="Proceed with full repair (this may risk data loss)? (y/N): "
	[running_xfs]="Running xfs_repair on %s"
	[running_ntfsfix]="Running ntfsfix on %s"
	[no_repair_support]="No automatic repair support for filesystem type '%s'."
	[remount_ntfs]="Remounting NTFS volume as read-write"
	[remount_rw]="Remounting volume as read-write"
	[complete]="Disk aid completed successfully."
)

usage() {
	cat <<EOF
########################################################################
#                            diskaid.sh                                #
# -------------------------------------------------------------------- #
#                                                                      #
#   This script performs disk partition checks and repair operations   #
#   using tools like smartctl, fsck, ntfsfix, xfs_repair, and mount.   #
#   It can automatically detect partitions, unmount them if needed,    #
#   attempt repairs, remount them as read-write,                       #
#   and run disk health checks or SMART self-tests.                    #
#                                                                      #
# -------------------------------------------------------------------- #
#                                                                      #
#           WARNING:                                                   #
#     Using this script on degraded, failing, or in-use disks may      #
#     result in permanent data loss.                                   #
#                                                                      #
#     Especially on old or heavily used SATA disks, long tests or      #
#     repair operations may trigger complete failure.                  #
#                                                                      #
#     Do NOT use while disk is under critical use or if power loss     #
#     is a risk during execution.                                      #
#                                                                      #
#      This script provides NO WARRANTY. USE AT YOUR OWN RISK.         #
#                                                         0x74h51N     #
#                                                                      #
########################################################################

Usage: $0 -m <mount_point> [OPTIONS]

Check (and optionally repair) a mounted filesystem.

Required:
  -m, --mnt-pnt DIR    Mount point to check (e.g. "/mnt/Partition Label")
  
      or
  
  -d, --device         Partition of disk to check (e.g. /dev/sdc1)

Options:
 
  -c, --check
        Run SMART health dump (smartctl -a).  Diagnostic only—no repairs.

  -b, --badblock
        Scan disk for unreadable sectors (badblocks -sv).  
        Finds bad sectors but does not mark them on NTFS; use e2fsck -c for ext*

  -f, --fix
        Repair filesystem metadata:
          • ext2/3/4 → fsck.ext4 -y
          • XFS      → xfs_repair
          • NTFS     → ntfsfix  # Only metadata/journal repair, NOT full bad‑cluster fixes.

  -t, --test TYPE
        Run SMART self‑test (short|long).  Test firmware‑level remapping.

  -h, --help           Show this help message and exit

Examples:
# Just check and remount read‑write
  $0 -m /run/media/user/MyDisk

  # Run SMART check and self-test on a disk partition
  $0 -p /dev/sda1 --check --test short

  # Force repair via fsck or ntfsfix without mount path
  $0 -p /dev/sdb1 --fix
EOF
}

if ((EUID != 0)); then
	error "${MSG[must_root]}"
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
UTILS="$ROOT_DIR/utils/utils.sh"

if [[ ! -r "$UTILS" ]]; then
	printf "${MSG[cannot_read_utils]}\n" "$UTILS" >&2
	exit 1
fi

source "$UTILS"

check_dep() {
	local cmd="$1"
	if ! command -v "$cmd" &>/dev/null; then
		error "${MSG[missing_dep]}" "$cmd"
		exit 1
	fi
}

PARSED=$(getopt -o hfcbm:p:t: -l help,fix,check,badlock,mnt-pnt:,partition:test: -- "$@") || {
	echo "${MSG[invalid_options]}" >&2
	exit 1
}

eval set -- "$PARSED"

FIX=0
CHK=0
BDLCK=0
TST=0
MNT=""
PART=""
DEVICE=""
TRAN=""
TESTt=""

while true; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-m | --mnt-pnt)
		MNT="$2"
		shift 2
		;;
	-c | --check)
		CHK=1
		shift
		;;
	-b | --badlock)
		BDLCK=1
		shift
		;;
	-t | --test)
		TST=1
		TESTt="$2"
		shift 2
		;;
	-p | --partition)
		PART="$2"
		shift 2
		;;
	-f | --fix)
		FIX=1
		shift
		;;
	--)
		shift
		break
		;;
	*)
		echo "Internal parsing error" >&2
		exit 2
		;;
	esac
done

if ((TST)); then
	case "$TESTt" in
	short | long) : ;;
	*)
		error "${MSG[test_type_err]}" "$TESTt"
		exit 1
		;;
	esac
fi

if [[ -z "$MNT" && -z "$PART" ]]; then
	echo "${MSG[missing_input]}" >&2
	exit 1
fi

resolve_pair() {
	local src="$1" mode="$2"
	local column flag

	case "$mode" in
	p)
		column=SOURCE
		flag="--target"
		;;
	m)
		column=TARGET
		flag="--source"
		;;
	*)
		error "Invalid mode '$mode' in resolve_pair"
		exit 1
		;;
	esac

	local out
	if out=$(findmnt -rn -o "$column" "$flag" "$src" 2>/dev/null); then
		printf '%s' "$out"
	else
		if [[ "$mode" == "p" ]]; then
			error "${MSG[unable_determine_device]}" "$src"
			exit 1
		fi
		printf ''
	fi
}

if [[ -n "$MNT" && -z "$PART" ]]; then
	info "${MSG[checking_partition]}" "$MNT"
	PART=$(resolve_pair "$MNT" p)
fi

if [[ -z "$MNT" && -n "$PART" ]]; then

	MNT=$(resolve_pair "$PART" m)

	if [[ -z "$MNT" ]]; then
		LABEL=$(lsblk -no LABEL "$PART")
		if [[ -z "$LABEL" ]]; then
			DEV=$(basename "$PART")
			HASH=$(echo -n "$PART" | md5sum | cut -c1-8)
			LABEL="/mnt/${DEV}_${HASH}"
		fi

		MNT="/mnt/$LABEL"

		info "${MSG[new_mnt]}" "$MNT"
		mkdir -p "$MNT" || {
			error "${MSG[new_mnt_err]}" "$MNT"
			exit 1
		}
		mount "$PART" "$MNT" || {
			error "${MSG[new_mnt_mnt_err]}" "$PART" "$MNT"
			exit 1
		}
	fi
fi

FSTYPE=$(lsblk -no FSTYPE "$PART" || echo "")
DEVICE="/dev/$(lsblk -no PKNAME "$PART")"
TRAN=$(lsblk -no TRAN "$DEVICE" || echo "")

case "$TRAN" in
sata) SMART_TYPE="ata" ;;
nvme) SMART_TYPE="nvme" ;;
usb) SMART_TYPE="sat" ;;
*) SMART_TYPE="auto" ;;
esac

check_usage() {
	if fuser -m "$DEVICE" &>/dev/null; then
		error "${MSG[disk_in_use]}" "$PART"
		exit 1
	fi
}

unmount() {
	info "${MSG[unmounting]}" "$FSTYPE" "$PART"
	if ! umount "$PART"; then
		error "${MSG[failed_unmount]}" "$PART"
		exit 1
	fi
}

if ((CHK)); then
	check_dep smartctl

	info "${MSG[health_check]}" "$DEVICE"

	if ! HLTH=$(smartctl -a -d "$SMART_TYPE" "$DEVICE" 2>&1); then
		warning "${MSG[health_check_warn]}" "$HLTH"
	else
		info "$HLTH"
	fi
fi

if ((BDLCK)); then
	check_dep "badblocks"

	check_usage
	unmount
	info "${MSG[badlock_info]}"
	badblocks -sv "$DEVICE" || error "${MSG[health_check_err]}"
fi

if ((TST)); then

	check_usage
	unmount

	if [[ "$TESTt" == "long" ]]; then
		warning "${MSG[long_test_inf]}"
		read -r -p "${MSG[long_test_appr]}" confirm
		if [[ ! "$confirm" =~ $yesPattern ]]; then
			warning "${MSG[long_test_abrt]}"
			exit 0
		fi
	fi

	info "${MSG[test_init]}" "$DEVICE"

	test_output=$(smartctl -t "$TESTt" -d "$SMART_TYPE" "$DEVICE")
	echo "$test_output"

	test_end=$(echo "$test_output" | grep "Test will complete after" | awk -F'after ' '{print $2}' | sed 's/ +.*$//')

	wait_sec=$(($(date -d "$test_end" +%s) - $(date +%s)))

	wait_until "$wait_sec" "${MSG[wait_info]}" "${MSG[wait_err]}"

	info "Fetching test result:"
	smartctl -a -d "$SMART_TYPE" "$DEVICE"
fi

if ((FIX)); then

	check_usage
	unmount

	case "$FSTYPE" in
	ext2 | ext3 | ext4)
		check_dep "e2fsck"

		info "${MSG[dry_check]}"
		e2fsck -n "$PART"

		approve "${MSG[fix_apprv]}"

		info "${MSG[running_fsck]}" "$PART"
		e2fsck -c -c -y "$PART"
		;;
	xfs)
		check_dep "xfs_repair"

		info "${MSG[dry_check]}"
		xfs_repair -n "$PART"

		approve "${MSG[fix_apprv]}"

		info "${MSG[running_xfs]}" "$PART"
		xfs_repair "$PART"
		;;
	ntfs)
		check_dep "ntfsfix"

		info "${MSG[running_ntfsfix]}" "$PART"
		ntfsfix "$PART"
		;;
	*)
		warning "${MSG[no_repair_support]}" "$FSTYPE"
		;;
	esac
fi

if [[ -z "$(resolve_pair "$MNT" p)" ]]; then

	if [[ ! -d "$MNT" ]]; then
		info "${MSG[creating_mountdir]}" "$MNT"
		if ! mkdir -p "$MNT"; then
			error "${MSG[failed_mkdir]}" "$MNT"
			exit 1
		fi
	fi
	case "$FSTYPE" in
	ntfs)
		info "${MSG[remount_ntfs]}"
		mount -t ntfs-3g -o uid=1000,gid=1000 "$PART" "$MNT"
		;;
	*)
		info "${MSG[remount_rw]}"
		mount -o rw "$PART" "$MNT"
		;;
	esac
fi
info "${MSG[complete]}"
