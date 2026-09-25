#!/bin/bash
set -euo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; export PATH; hash -r
export LC_ALL=C LANG=C
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then GREEN='' GOLD='' DEEP_RED='' CYAN='' YELLOW='' WHITE='' NC=''
else
    GREEN=$'\033[1;32m' GOLD=$'\033[1;38;5;214m' DEEP_RED=$'\033[1;38;5;160m'
    CYAN=$'\e[1;36m' YELLOW=$'\033[1;33m' WHITE=$'\033[1;37m' NC=$'\033[0m'
fi
HELP_MESSAGE=$(cat << EOF

=========================================

Usage: sudo ./${0##*/}

Description:
  This script simplifies the creation of 
  BTRFS RAID1 volumes

Options:
  -h  open this help message (./${0##*/} -h)

=========================================

EOF
)

ACTION="${1:-}"
case "$ACTION" in
    "")                       ACTION="" ;;
    -h|--help|-help|help)
        echo "$HELP_MESSAGE"
        exit 0 ;;
    *)
        echo "Invalid action: $ACTION" >&2
        echo "Try '${0##*/} -h' for help." >&2
        echo ""
        exit 1 ;;
esac


##########################################################################################################
# Helper Functions (Shared Helpers, Format-Side, Mount-Side)
##########################################################################################################
MAPPERS=(); RAID_NAMES=(); RAID_MOUNTS=(); VERIFY_MOUNTPOINT=""; CREATED_MOUNTS=(); MENU_TITLE="Main Menu"
LOG_SUBDIR="DISKUTILS"; LOG_BASENAME="DISKUTILS_log.txt"; LOG_USER=""; LOG_PATH=""; LOG_START="$(date +%s)"; CURRENT_ACTION=""; FAILURE_LOGGED=false; LOGGED_RC=99
ROLLBACK_ACTIVE=false; ROLLBACK_MOUNT=""; ROLLBACK_LIVE=""; ROLLBACK_BROKEN=""; ROLLBACK_TEMP=""; ROLLBACK_LIVE_ID=""; ROLLBACK_DEFAULT_ID=""; ROLLBACK_NEW_ID=""

error_exit(){
    echo "${DEEP_RED}[-] Error:${NC} $*" >&2
    if [ -n "$CURRENT_ACTION" ] && [ "$FAILURE_LOGGED" = false ]; then
        FAILURE_LOGGED=true
        log_transaction "$CURRENT_ACTION" "FAILURE" "Reason: $(printf '%s' "$*" | sed 's/\x1b\[[0-9;]*m//g')"
    fi
    exit $(( BASHPID == $$ ? 1 : LOGGED_RC )); }
if [ -t 1 ]; then clear 2>/dev/null || true; fi
[ "$EUID" != 0 ] && error_exit "Please run this script with sudo or as root."

run_step(){ "$@" || error_exit "Command failed: $*"; }

confirm() {
    local reply
    read -rp "$1 (y/N): " reply || reply=""
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) echo "Operation canceled."; echo ""; return 1 ;;
    esac; }
    
require_tools(){ local missing=() t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done; ((${#missing[@]}==0)) || error_exit "Missing required tool(s): ${missing[*]}"; }
require_tools awk btrfs blkid blockdev cat cryptsetup dd find findmnt fuser grep lsblk mkfs.btrfs mktemp mount mountpoint mv parted partprobe realpath rmdir runuser sed sleep swapoff swapon sync tac tail umount udevadm wipefs

disk_in_use(){
    local d="$1" n type
    while read -r n type; do
        [[ -n "$n" ]] || continue
        [[ "$type" == disk || "$type" == part ]] || return 0
        if findmnt -rn -S "$n" >/dev/null 2>&1; then return 0; fi
        if fuser -s "$n" 2>/dev/null; then return 0; fi
        if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$n"; then return 0; fi
        if [[ "$(blkid -o value -s TYPE "$n" 2>/dev/null || true)" == btrfs ]] && grep -Fxq "$(blkid -o value -s UUID "$n" 2>/dev/null || true)" <<< "$(findmnt -rn -o UUID 2>/dev/null)"; then return 0; fi
    done < <(lsblk -nrpo NAME,TYPE "$d" 2>/dev/null)
    return 1
}

show_target_identity() {
    local target="$1"
    lsblk -dno NAME,SIZE,MODEL,SERIAL,RO,RM,TRAN -- "$target" 2>/dev/null || true; }

rollback_clear_state(){
    ROLLBACK_ACTIVE=false
    ROLLBACK_MOUNT=""; ROLLBACK_LIVE=""; ROLLBACK_BROKEN=""; ROLLBACK_TEMP=""
    ROLLBACK_LIVE_ID=""; ROLLBACK_DEFAULT_ID=""; ROLLBACK_NEW_ID=""
}

# Restores the original rollback state after any failure once rollback has begun.
rollback_restore_original(){
    local live="$ROLLBACK_LIVE" broken="$ROLLBACK_BROKEN" temp="$ROLLBACK_TEMP"
    local current_id default_now
    [[ "$ROLLBACK_ACTIVE" = true && -n "$ROLLBACK_MOUNT" && -n "$live" && -n "$broken" ]] || return 1

    if [[ -e "$broken" && -e "$live" ]]; then
        current_id="$(btrfs subvolume show "$live" 2>/dev/null | awk -F': ' '/^Subvolume ID:/{print $2; exit}' || true)"
        [[ -n "$current_id" && "$current_id" == "$ROLLBACK_NEW_ID" ]] || return 1
        if [[ "$ROLLBACK_DEFAULT_ID" == "$ROLLBACK_LIVE_ID" ]]; then
            btrfs subvolume set-default "$ROLLBACK_LIVE_ID" "$ROLLBACK_MOUNT" >/dev/null 2>&1 || return 1
            default_now="$(btrfs subvolume get-default "$ROLLBACK_MOUNT" 2>/dev/null | awk '/^ID /{print $2; exit}' || true)"
            [[ "$default_now" == "$ROLLBACK_LIVE_ID" ]] || return 1
        fi
        btrfs subvolume delete "$live" >/dev/null 2>&1 || return 1
    elif [[ ! -e "$broken" && -e "$live" ]]; then
        current_id="$(btrfs subvolume show "$live" 2>/dev/null | awk -F': ' '/^Subvolume ID:/{print $2; exit}' || true)"
        [[ -n "$current_id" && "$current_id" == "$ROLLBACK_LIVE_ID" ]] || return 1
    fi

    if [[ -e "$broken" && ! -e "$live" ]]; then
        mv -T "$broken" "$live" >/dev/null 2>&1 || return 1
    elif [[ -e "$broken" ]]; then
        return 1
    elif [[ ! -e "$live" ]]; then
        return 1
    fi

    if [[ -n "$temp" && -e "$temp" ]]; then
        btrfs subvolume delete "$temp" >/dev/null 2>&1 || true
    fi

    if [[ "$ROLLBACK_DEFAULT_ID" == "$ROLLBACK_LIVE_ID" ]]; then
        btrfs subvolume set-default "$ROLLBACK_LIVE_ID" "$ROLLBACK_MOUNT" >/dev/null 2>&1 || return 1
        default_now="$(btrfs subvolume get-default "$ROLLBACK_MOUNT" 2>/dev/null | awk '/^ID /{print $2; exit}' || true)"
        [[ "$default_now" == "$ROLLBACK_LIVE_ID" ]] || return 1
    fi

    rollback_clear_state
    return 0
}

cleanup(){
    local rc=$? m
    tput cnorm 2>/dev/null || true
    [[ -n "${VERIFY_MOUNTPOINT:-}" ]] && mountpoint -q "$VERIFY_MOUNTPOINT" && umount "$VERIFY_MOUNTPOINT" >/dev/null 2>&1 || true
    [[ -n "${VERIFY_MOUNTPOINT:-}" ]] && rmdir "$VERIFY_MOUNTPOINT" 2>/dev/null || true
    if [ "$ROLLBACK_ACTIVE" = true ]; then
        rollback_restore_original || echo "${GOLD:-}[!] Notice:${NC:-} could not automatically restore the original rollback state; inspect $ROLLBACK_LIVE and $ROLLBACK_BROKEN." >&2
    fi
    for m in "${CREATED_MOUNTS[@]}"; do rmdir "$m" 2>/dev/null || true; done
    for m in "${MAPPERS[@]}"; do
        [[ -e "/dev/mapper/$m" ]] && cryptsetup close "$m" >/dev/null 2>&1 || true
    done
    if [ "$rc" -ne 0 ] && [ "$rc" -ne "$LOGGED_RC" ] && [ -n "$CURRENT_ACTION" ] && [ "$FAILURE_LOGGED" = false ]; then
        FAILURE_LOGGED=true
        log_transaction "$CURRENT_ACTION" "FAILURE" "Exit status: $rc"
    fi
}
trap 'cleanup' EXIT
trap 'exit 130' INT TERM

raid_member_info(){
    local dev="$1" out
    out="$(btrfs inspect-internal dump-super -f "$dev" 2>/dev/null || true)"
    [[ -n "$out" ]] || { echo "${DEEP_RED}[-] Warning:${NC} Could not read the BTRFS superblock from $dev." >&2; return 1; }
    echo "$out" | grep -E '^(fsid|label|generation|num_devices|dev_item\.devid|dev_item\.uuid|dev_item\.generation)' || true
}

select_raid_disk(){
    local prompt="$1" d name root_src
    read -rp "$prompt " name || name=""
    d="/dev/${name#/dev/}"
    name="$(lsblk -dnro NAME "$d" 2>/dev/null || true)"
    d="/dev/$name"
    [[ -b "$d" && $(lsblk -dno TYPE "$d" 2>/dev/null) == disk ]] || error_exit "Not a valid whole disk: $d"
    root_src="$(findmnt -no SOURCE --nofsroot / 2>/dev/null || true)"
    [[ -n "$root_src" ]] || error_exit "Could not determine the root device; refusing to continue."
    [[ "$d" != "$root_src" ]] || error_exit "The running OS disk cannot be used."
    lsblk -nso PKNAME "$root_src" 2>/dev/null | grep -qx "${d#/dev/}" && error_exit "The running OS disk cannot be used."
    ! disk_in_use "$d" || error_exit "$d is in use (mounted, swap, an open encryption mapping, or a member of a mounted filesystem)."
    echo "$d"
}

find_single_partition(){
    local d="$1" p count
    read -r count p < <(lsblk -nrpo NAME,TYPE "$d" 2>/dev/null | awk '$2=="part"{n++; p=$1} END{print n+0,p}')
    [[ "$count" -eq 1 && -b "$p" ]] || error_exit "Expected exactly one partition on $d."
    echo "$p"
}

open_luks_member(){
    local part="$1" mapper="$2" pass="$3"
    [[ "$(blkid -o value -s TYPE "$part" 2>/dev/null || true)" == crypto_LUKS ]] || error_exit "$part is not a LUKS device."
    printf '%s' "$pass" | cryptsetup open --key-file=- "$part" "$mapper" || error_exit "Could not unlock $part."
    MAPPERS+=("$mapper")
    [[ -b "/dev/mapper/$mapper" ]] || error_exit "Mapper $mapper was not created."
}

luks_backing_device(){
    local d
    while read -r d; do
        [[ -b "$d" ]] || continue
        [[ "$(blkid -o value -s TYPE "$d" 2>/dev/null || true)" == crypto_LUKS ]] || continue
        printf '%s\n' "$d"; return 0
    done < <(lsblk -nsrpo NAME "$1" 2>/dev/null)
    return 1
}

list_mounted_raids(){
    local mountpoint name
    RAID_NAMES=()
    RAID_MOUNTS=()
    while read -r mountpoint; do
        [[ "$(btrfs filesystem show "$mountpoint" 2>/dev/null | grep -c 'Total devices 2 ')" -eq 1 ]] || continue
        btrfs filesystem usage "$mountpoint" 2>/dev/null | grep -q '^Data,.*RAID1' || continue
        name="${mountpoint##*/}"
    	RAID_NAMES+=("$name")
    	RAID_MOUNTS+=("$mountpoint")
    done < <(findmnt -rn -t btrfs -o TARGET)
}

display_disks() {
    echo "${WHITE}=================== ${GOLD}Available Disks ${WHITE}===================${NC}"
    lsblk -d -o NAME,SIZE,MODEL,RO,RM,TRAN | awk 'NR==1 || $1 !~ /^loop/'
    echo "${WHITE}=======================================================${NC}"
    echo ""
}

display_banner() {
    local title="${1:-BTRFS RAID1 Tool}" warn="${2:-Proceed with caution.}"
    echo "${WHITE}=======================================================${NC}"
    printf '%s%*s%s\n' "$GOLD" "$(( (56 + ${#title}) / 2 ))" "$title" "$NC"
    echo ""
    echo "${GREEN}Usage: '${0##*/} -h' for help.${NC}"
    echo "${DEEP_RED}WARNING: ${warn}${NC}"
    echo "${WHITE}=======================================================${NC}"
    echo ""
}


##########################################################################################################
# Transaction log
##########################################################################################################
resolve_log_location() {
    [ -n "$LOG_PATH" ] && return 0
    local user home desk=""

    user="${SUDO_USER:-root}"
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        user="root"
        home="$(getent passwd root 2>/dev/null | cut -d: -f6 || true)"
        [ -n "$home" ] || home="/root"
    fi

    if command -v xdg-user-dir >/dev/null 2>&1; then
        desk="$(runuser -u "$user" -- env HOME="$home" xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    # xdg-user-dir echoes $HOME when the entry is unset, which is not an answer
    if [ -z "$desk" ] || [ "$desk" = "$home" ]; then
        desk=""
        if [ -r "$home/.config/user-dirs.dirs" ]; then
            desk="$(awk -F'"' '/^[[:space:]]*XDG_DESKTOP_DIR=/ { d = $2 } END { print d }' \
                    "$home/.config/user-dirs.dirs" 2>/dev/null || true)"
            desk="${desk/#\$HOME/$home}"
        fi
    fi
    [ -n "$desk" ] || desk="$home/Desktop"
    [ -d "$desk" ] || desk="$home"

    LOG_USER="$user"
    LOG_PATH="$desk/$LOG_SUBDIR/$LOG_BASENAME"
    return 0; }

# log_transaction <action> <result> ["Key: value" ...]: Every entry carries the session context automatically
log_transaction() {
    local action="${1:-(unspecified)}" result="${2:-(unspecified)}"
    [ "$#" -gt 2 ] && shift 2 || set --
    local entry dir rc=0 secs line key val

    resolve_log_location
    dir="${LOG_PATH%/*}"
    secs=$(( $(date +%s) - LOG_START ))

    # $0 names the running script, so this function reports whichever tool called it.
    entry="===== ${0##*/} | $(date '+%Y-%m-%d %H:%M:%S %z') | ${result} ====="$'\n'

    set -- "Action: $action" \
           "Invoked by: ${SUDO_USER:-root} (uid ${SUDO_UID:-0}) on $(uname -n)" \
           "Kernel: $(uname -r)" \
           "Duration: $((secs / 60))m $((secs % 60))s" \
           "$@"
    for line in "$@"; do
        [ -n "$line" ] || continue
        key="${line%%:*}"
        val="${line#*:}"
        if [ "$key" = "$line" ] || [ -z "${val# }" ]; then
            entry+="  $line"$'\n'
        else
            entry+="$(printf '  %-13s %s' "${key}:" "${val# }")"$'\n'
        fi
    done
    entry+=$'\n'

    # Written as the owning user, not as root: the path sits in a user-writable
    diskutils_mkdir "$dir" 2>/dev/null || rc=1
    if [ "$rc" -eq 0 ]; then
        printf '%s' "$entry" | runuser -u "$LOG_USER" -- tee -a "$LOG_PATH" >/dev/null 2>&1 || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "${GOLD:-}[!] Notice:${NC:-} could not write the log to $LOG_PATH." >&2
    fi
    return 0; }

# Minimal stand-ins for diskutils_dir's dependencies: the root is the log's DISKUTILS folder, created as the log's user.
resolve_diskutils_root(){ resolve_log_location; DISKUTILS_ROOT="${LOG_PATH%/*}"; }
diskutils_mkdir(){ runuser -u "$LOG_USER" -- sh -c 'umask 077; mkdir -p "$1"' _ "$1"; }
diskutils_dir() {
    local dir
    resolve_diskutils_root
    dir="$DISKUTILS_ROOT${1:+/$1}"
    diskutils_mkdir "$dir" || return 1
    printf '%s\n' "$dir"; }

##########################################################################################################
# Reusable menu
##########################################################################################################
menu_select(){
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "$HELP_MESSAGE" >&2
        error_exit "No terminal available for the menu; run this tool from an interactive terminal."
    fi
    local -a labels=("$@")
    local count=${#labels[@]}
    local selected=0 key key2 i jump pad bar="======================================================="
    MENU_CHOICE=""
    tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null || true' RETURN

    while true; do
        clear 2>/dev/null || true
        display_banner
        pad=$(( (53 - ${#MENU_TITLE}) / 2 ))
        echo "${WHITE}${bar:0:pad} ${GOLD}${MENU_TITLE} ${WHITE}${bar:0:$((53 - ${#MENU_TITLE} - pad))}${NC}"
        # Entries are numbered modulo 10, so a 10th entry displays (and selects) as 0. Do not exceed 10 labels.
        for i in "${!labels[@]}"; do
            if [ "$i" -eq "$selected" ]; then
                printf '%s%d) %-43s[x]%s\n' "$GOLD" "$(( (i + 1) % 10 ))" "${labels[$i]}" "$NC"
            else
                printf '%d) %-43s[ ]\n' "$(( (i + 1) % 10 ))" "${labels[$i]}"
            fi
        done
        echo "${WHITE}=======================================================${NC}"
        echo ""
        echo "${GREEN}Up/Down to move, $([ "$count" -eq 10 ] && echo "1-9,0" || echo "1-$count") to jump, Enter to select, q to quit.${NC}"

        # EOF (piped or closed stdin) must not spin this loop forever
        if ! IFS= read -rsn1 key; then
            echo ""
            return 0
        fi

        case "$key" in
            $'\x1b')
                if ! IFS= read -rsn2 -t 0.1 key2; then key2=""; fi
                case "$key2" in
                    '[A') selected=$(( (selected - 1 + count) % count )) ;;
                    '[B') selected=$(( (selected + 1) % count )) ;;
                    '')   ;;
                esac ;;
            [0-9])
                jump=$(( key == 0 ? 10 : key )); (( jump <= count )) || continue; selected=$(( jump - 1 ))
                MENU_CHOICE="$selected"
                return 0 ;;
            q|Q) exit 0 ;;
            '')  MENU_CHOICE="$selected"; return 0 ;;
        esac
    done; }

show_menu(){
    local _
    while :; do
        MENU_TITLE="Main Menu"
        menu_select "Create BTRFS RAID 1" \
            "Mount BTRFS RAID 1" \
            "Unmount BTRFS RAID 1" \
            "RAID Health / Device Status" \
            "Scrub / Verify Integrity" \
            "Manage Subvolumes & Snapshots" \
            "Recovery" \
            "Read-Only Diagnostics" \
            "Exit"
        case "$MENU_CHOICE" in
            0) create_raid ;;
            1) mount_raid ;;
            2) unmount_raid ;;
            3) raid_health ;;
            4) scrub_raid ;;
            5) subvolume_menu ;;
            6) recovery_menu ;;
            7) diagnostics_raid ;;
            8) exit 0 ;;
        esac
        CURRENT_ACTION=""
        echo
        read -rp "Press Enter to return to the menu..." _ || { echo; exit 0; }
    done
}


##########################################################################################################
# Action 1: Mount RAID1
##########################################################################################################
mount_raid(){
    local d1 d2 p1 p2 pass mountpoint uuid1 uuid2 usage MODE_CHOICE MOUNT_OPTS
    CURRENT_ACTION="mount"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "Mount Existing RAID 1"
    display_disks
    [[ ! -e /dev/mapper/btrfs_raid1_disk1 && ! -e /dev/mapper/btrfs_raid1_disk2 ]] || error_exit "btrfs_raid1_disk1/2 already exist (another RAID mounted by this tool, or a stale mapping); unmount or close them first."
    d1="$(select_raid_disk "First RAID disk (e.g. sdb or /dev/sdb):")"
    echo "${YELLOW}[+] Target: ${NC}$(show_target_identity "$d1")"
    echo ""
    d2="$(select_raid_disk "Second RAID disk (e.g. sdc or /dev/sdc):")"
    echo "${YELLOW}[+] Target: ${NC}$(show_target_identity "$d2")"
    echo ""
    [[ "$d1" != "$d2" ]] || error_exit "Two different disks are required."
    p1="$(find_single_partition "$d1")"; p2="$(find_single_partition "$d2")"
    
    read -rp "Mount point name (created under /mnt): " mountpoint || mountpoint=""
    [[ "$mountpoint" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || error_exit "Mount point name must be 1-64 characters: letters, numbers, dot, dash or underscore."
    mountpoint="/mnt/$mountpoint"
    if [[ ! -d "$mountpoint" ]]; then 
    	mkdir -p "$mountpoint" || error_exit "Could not create mount point: $mountpoint"
	CREATED_MOUNTS+=("$mountpoint")
    fi
    mountpoint -q "$mountpoint" && error_exit "mount point is already in use."
    echo ""
    
    echo ""
    echo "${WHITE}================== ${GOLD}Select Mount Mode ${WHITE}==================${NC}"
    echo "1) Read-Write (rw) - Standard access"
    echo "2) Read-Only (ro)  - Protects data from modification"
    echo "${WHITE}=======================================================${NC}"
    echo ""
    read -rp "Enter choice [1-2] (Default: 1): " MODE_CHOICE || MODE_CHOICE=""
    case "$MODE_CHOICE" in
        1|"") MOUNT_OPTS="rw" ;;
        2)     MOUNT_OPTS="ro" ;;
        *)     error_exit "Invalid mount mode; enter 1 or 2." ;;
    esac
    echo ""
    IFS= read -rsp "${GOLD}[!] ${NC}LUKS password to mount disks: " pass; echo
    if [ "$MOUNT_OPTS" = "ro" ]; then
        printf '%s' "$pass" | cryptsetup open --readonly --key-file=- "$p1" btrfs_raid1_disk1 || error_exit "Failed"
        MAPPERS+=("btrfs_raid1_disk1")
        printf '%s' "$pass" | cryptsetup open --readonly --key-file=- "$p2" btrfs_raid1_disk2 || error_exit "Failed"
        MAPPERS+=("btrfs_raid1_disk2")
    else
        open_luks_member "$p1" btrfs_raid1_disk1 "$pass"
        open_luks_member "$p2" btrfs_raid1_disk2 "$pass"
    fi
    unset pass
    uuid1="$(blkid -o value -s UUID /dev/mapper/btrfs_raid1_disk1 2>/dev/null || true)"
    uuid2="$(blkid -o value -s UUID /dev/mapper/btrfs_raid1_disk2 2>/dev/null || true)"
    [[ -n "$uuid1" && "$uuid1" == "$uuid2" ]] || error_exit "The two decrypted devices are not the same BTRFS filesystem."
    [[ "$(btrfs filesystem show /dev/mapper/btrfs_raid1_disk1 2>/dev/null | grep -c 'devid ')" -eq 2 ]] || error_exit "BTRFS does not report exactly two RAID members."
    mount -t btrfs -o "$MOUNT_OPTS" /dev/mapper/btrfs_raid1_disk1 "$mountpoint" || error_exit "BTRFS mount failed."
    usage="$(btrfs filesystem usage "$mountpoint" 2>/dev/null || true)"
    printf '%s\n' "$usage" | grep -q 'Data,.*RAID1' || { umount "$mountpoint"; error_exit "BTRFS data profile is not RAID1."; }
    printf '%s\n' "$usage" | grep -q 'Metadata,.*RAID1' || { umount "$mountpoint"; error_exit "BTRFS metadata profile is not RAID1."; }
    MAPPERS=()
    log_transaction "mount" "SUCCESS" "Mount point: $mountpoint" "Mount option: $MOUNT_OPTS" "FS UUID: $uuid1" "Members: $p1, $p2"
    echo ""
    echo "${GREEN}[+] ${NC}BTRFS RAID 1 mounted normally at $mountpoint"
}


##########################################################################################################
# Action 2: Unmount RAID 1
##########################################################################################################
unmount_raid(){
    local i m mountpoint matched="" open="" members=()
    CURRENT_ACTION="unmount"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "Unmount Existing RAID 1"
    list_mounted_raids
    for i in "${!RAID_NAMES[@]}"; do
    	printf '%s\t%s\n' "${RAID_NAMES[$i]}" "${RAID_MOUNTS[$i]}"
    done
    read -rp "Mount name to unmount: " mountpoint || mountpoint=""
    for i in "${!RAID_NAMES[@]}"; do
        [[ "$mountpoint" == "${RAID_MOUNTS[$i]}" || "$mountpoint" == "${RAID_MOUNTS[$i]##*/}" ]] || continue
        mountpoint="${RAID_MOUNTS[$i]}"
        matched=1
        break
    done
    [[ -n "$matched" ]] || error_exit "RAID mount point was not found."
    mapfile -t members < <(btrfs_member_devices "$mountpoint")
    run_step umount "$mountpoint"
    for m in "${members[@]}"; do
        [[ "$(lsblk -dno TYPE "$m" 2>/dev/null)" == crypt ]] || continue
        cryptsetup close "${m##*/}" 2>/dev/null || open+=" ${m##*/}"
    done
    for m in "${CREATED_MOUNTS[@]}"; do
        if [[ "$m" == "$mountpoint" ]]; then rmdir "$mountpoint" 2>/dev/null || true; break; fi
    done
    VERIFY_MOUNTPOINT=""
    log_transaction "unmount" "SUCCESS" "Mount point: $mountpoint" "Members: ${members[*]}" "Left open:${open:- none}"
    echo ""
    [[ -z "$open" ]] && echo "${GREEN}[+] ${NC}BTRFS RAID 1 unmounted and encryption mappings closed." || echo "${GOLD}[!] ${NC}BTRFS RAID 1 unmounted, but these mappings are still open (in use elsewhere?):$open"
}


##########################################################################################################
# Action 3-4: Raid Health & Scrub
##########################################################################################################
btrfs_member_devices(){
    btrfs filesystem show "$1" 2>/dev/null | sed -n 's/.*path \([/][^ ]*\).*/\1/p'
}

raid_health(){
    local i mountpoint fsid generation dev dir file disk
    CURRENT_ACTION="health"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "BTRFS RAID 1 Health Inspection"
    list_mounted_raids
    for i in "${!RAID_NAMES[@]}"; do
    	printf '%s\t%s\n' "${RAID_NAMES[$i]}" "${RAID_MOUNTS[$i]}"
    done
    echo ""
    read -rp "Mount name to inspect: " mountpoint || mountpoint=""
    for i in "${!RAID_NAMES[@]}"; do
        [[ "$mountpoint" == "${RAID_MOUNTS[$i]}" || "$mountpoint" == "${RAID_MOUNTS[$i]##*/}" ]] || continue
        mountpoint="${RAID_MOUNTS[$i]}"
        break
    done
    [[ -n "$mountpoint" ]] || error_exit "Mount point is required."
    findmnt -rn -M "$mountpoint" -t btrfs >/dev/null 2>&1 || error_exit "No BTRFS filesystem is mounted there."
    fsid="$(findmnt -no UUID -M "$mountpoint" 2>/dev/null || true)"
    generation="$(cat "/sys/fs/btrfs/$fsid/generation" 2>/dev/null || true)"
    resolve_log_location; dir="$(diskutils_dir REPORTS)" || error_exit "Could not create the REPORTS folder."
    file="$dir/raid-health_${mountpoint##*/}_$(date +%F_%H%M%S).txt"
    echo ""
    echo ""
    echo "${WHITE}===================== ${GOLD}RAID Health ${WHITE}=====================${NC}"
    { # Everything between the header and footer bars is also saved, without colors, to DISKUTILS/REPORTS.
    btrfs filesystem show "$mountpoint" 2>/dev/null || error_exit "Could not inspect BTRFS filesystem."
    [[ -n "$generation" ]] && echo "Current filesystem generation (revision): $generation"
    echo
    echo "Member superblock revisions:"
    while read -r dev; do
        [[ -b "$dev" ]] || continue
        echo ""; echo "--- $dev ---"
        disk="$(lsblk -snrpo NAME,TYPE "$dev" 2>/dev/null | awk '$2=="disk"{print $1; exit}' || true)"
        printf "Drive:%*s%s\n" 18 "" "${disk:-unknown}"
        printf "Model:%*s%s\n" 18 "" "$(lsblk -dno MODEL "$disk" 2>/dev/null || true)"
        printf "Serial:%*s%s\n" 17 "" "$(lsblk -dno SERIAL "$disk" 2>/dev/null || true)"
        raid_member_info "$dev" || true
    done < <(btrfs_member_devices "$mountpoint")
    echo
    echo "Device statistics:"
    btrfs device stats "$mountpoint" 2>/dev/null || error_exit "Could not read BTRFS device statistics."
    echo
    echo "Filesystem usage:"
    btrfs filesystem usage "$mountpoint" 2>/dev/null || error_exit "Could not read BTRFS filesystem usage."
    } 2>&1 | tee /dev/tty | sed 's/\x1b\[[0-9;]*m//g' | runuser -u "$LOG_USER" -- tee "$file" >/dev/null || { ((PIPESTATUS[0] == LOGGED_RC)) && FAILURE_LOGGED=true; error_exit "Could not complete the report: $file"; }
    echo "${WHITE}=======================================================${NC}"
    echo ""; echo "${GREEN}[+] ${NC}Report saved: $file"
}

scrub_raid(){
    local i mountpoint scrub_rc scrub_status fsid dir file scrub_result
    CURRENT_ACTION="scrub"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "BTRFS RAID 1 Scrub"
    list_mounted_raids
    for i in "${!RAID_NAMES[@]}"; do
    	printf '%s\t%s\n' "${RAID_NAMES[$i]}" "${RAID_MOUNTS[$i]}"
    done
    echo ""
    read -rp "Mounted BTRFS RAID 1 mount point: " mountpoint || mountpoint=""
    for i in "${!RAID_NAMES[@]}"; do
        [[ "$mountpoint" == "${RAID_MOUNTS[$i]}" || "$mountpoint" == "${RAID_MOUNTS[$i]##*/}" ]] || continue
        mountpoint="${RAID_MOUNTS[$i]}"
        break
    done
    [[ -n "$mountpoint" ]] || error_exit "Mount point is required."
    findmnt -rn -M "$mountpoint" -t btrfs >/dev/null 2>&1 || error_exit "No BTRFS filesystem is mounted there."
    fsid="$(findmnt -no UUID -M "$mountpoint" 2>/dev/null || true)"
    resolve_log_location; dir="$(diskutils_dir REPORTS)" || error_exit "Could not create the REPORTS folder."
    file="$dir/scrub_${mountpoint##*/}_$(date +%F_%H%M%S).txt"
    echo ""
    echo "${GOLD}[-] ${NC}Starting BTRFS scrub."; echo""
    scrub_rc=0
    btrfs scrub start -B $([[ ",$(findmnt -no VFS-OPTIONS -M "$mountpoint" 2>/dev/null)," == *,ro,* ]] && echo -r) "$mountpoint" || scrub_rc=$?
    (( scrub_rc == 0 || scrub_rc == 3 )) || error_exit "BTRFS scrub failed."
    echo
    echo "Scrub result:"
    scrub_status="$(btrfs scrub status -d "$mountpoint" 2>/dev/null)" || error_exit "Could not read scrub status."
    printf '%s\n' "$scrub_status"
    if printf '%s\n' "$scrub_status" | grep -Eiq 'Uncorrectable[[:space:]]*:[[:space:]]*[1-9]|Unverified[[:space:]]*:[[:space:]]*[1-9]|csum[[:space:]]*=[[:space:]]*[1-9]|super[[:space:]]*=[[:space:]]*[1-9]|verify[[:space:]]*=[[:space:]]*[1-9]|read[[:space:]]*=[[:space:]]*[1-9]'; then
        scrub_results="ERRORS"
        echo ""; echo "${DEEP_RED}[-] ERROR:${NC} Scrub reported errors requiring attention." >&2
        log_transaction "scrub" "ERRORS" "Mount point: $mountpoint" "Result: errors reported; review scrub status"
    else
        scrub_result="SUCCESS"
        echo ""; echo "${GREEN}[+]${NC} Scrub completed without reported errors."
        log_transaction "scrub" "SUCCESS" "Mount point: $mountpoint" "Result: no errors reported"
    fi

    echo ""
    title_bar "BTRFS RAID 1 Scrub Report"
    {
        echo "Mount point: $mountpoint"
        echo "FS UUID: $fsid"
        echo "Scrub result: $scrub_result"
        echo "Scrub return code: $scrub_rc"
        echo ""
        printf '%s\n' "$scrub_status"
    } 2>&1 | tee /dev/tty | sed 's/\x1b\[[0-9;]*m//g' | runuser -u "$LOG_USER" -- tee "$file" >/dev/null || { ((PIPESTATUS[0] == LOGGED_RC)) && FAILURE_LOGGED=true; error_exit "Could not complete the report: $file"; }
    echo "${WHITE}=======================================================${NC}"
    echo ""; echo "${GREEN}[+] ${NC}Report saved: $file"
}


##########################################################################################################
# Action 5: Recovery Menu
##########################################################################################################
recovery_menu(){
    local _
    while :; do
        MENU_TITLE="Recovery Menu"
        menu_select "Replace Failed Drive" \
            "Write to Single Drive" \
            "Restore RAID 1" \
            "Back"
        case "$MENU_CHOICE" in
            0) reconcile_raid ;;
            1) degraded_mount ;;
            2) restore_raid ;;
            3) return 0 ;;
        esac
        CURRENT_ACTION=""
        echo "" 
        read -rp "Press Enter to return to Recovery..." _ || { echo; exit 0; }
    done
}

degraded_mount(){
    local d p pass mountpoint uuid usage
    CURRENT_ACTION="degraded-mount"; LOG_START="$(date +%s)"
    echo "${DEEP_RED}WARNING: This is an explicit recovery operation.${NC}"
    echo "A degraded mount has one or more RAID members missing."
    echo "Do not use this as the normal mount path."
    echo
    d="$(select_raid_disk "Select the surviving RAID disk:")"
    p="$(find_single_partition "$d")"
    IFS= read -rsp "LUKS password: " pass; echo
    open_luks_member "$p" btrfs_raid1_recovery "$pass"
    unset pass
    uuid="$(blkid -o value -s UUID /dev/mapper/btrfs_raid1_recovery 2>/dev/null || true)"
    [[ -n "$uuid" ]] || error_exit "Could not identify the BTRFS filesystem UUID."
    echo
    echo "Detected BTRFS superblock/device revision:"
    raid_member_info /dev/mapper/btrfs_raid1_recovery || true
    read -rp "Mount point (must exist): " mountpoint || mountpoint=""
    [[ -d "$mountpoint" ]] || error_exit "Mount point does not exist."
    ! mountpoint -q "$mountpoint" || error_exit "Mount point is already in use."
    confirm "Mount this filesystem DEGRADED at $mountpoint?" || { cryptsetup close btrfs_raid1_recovery && MAPPERS=(); return 0; }
    run_step mount -t btrfs -o degraded /dev/mapper/btrfs_raid1_recovery "$mountpoint"
    usage="$(btrfs filesystem usage "$mountpoint" 2>/dev/null || true)"
    [[ "$(btrfs filesystem show "$mountpoint" 2>/dev/null | grep -c 'Total devices 2 ')" -eq 1 ]] || { umount "$mountpoint"; error_exit "BTRFS does not report exactly two RAID members."; }
    printf '%s\n' "$usage" | grep -q 'Data,.*RAID1' || { umount "$mountpoint"; error_exit "BTRFS data profile is not RAID1."; }
    printf '%s\n' "$usage" | grep -q 'Metadata,.*RAID1' || { umount "$mountpoint"; error_exit "BTRFS metadata profile is not RAID1."; }
    MAPPERS=()
    log_transaction "degraded-mount" "SUCCESS" "Mount point: $mountpoint" "Surviving disk: $d ($p)" "FS UUID: $uuid" "Mode: degraded (recovery)"
    echo "${GOLD}[!] ${NC}Recovery mount active in degraded mode."
    echo "Use RAID Health, then Replace Failed Drive or Restore RAID1 before treating the RAID as restored."
}

restore_raid(){
    local i mountpoint usage devices missing fsid
    CURRENT_ACTION="restore"; LOG_START="$(date +%s)"
    echo ""; echo "";
    list_mounted_raids
    for i in "${!RAID_NAMES[@]}"; do
    	printf '%s\t%s\n' "${RAID_NAMES[$i]}" "${RAID_MOUNTS[$i]}"
    done
    read -rp "Mounted BTRFS RAID 1 mount point: " mountpoint || mountpoint=""
    for i in "${!RAID_NAMES[@]}"; do
        [[ "$mountpoint" == "${RAID_MOUNTS[$i]}" || "$mountpoint" == "${RAID_MOUNTS[$i]##*/}" ]] || continue
        mountpoint="${RAID_MOUNTS[$i]}"
        break
    done
    findmnt -rn -M "$mountpoint" -t btrfs >/dev/null 2>&1 || error_exit "No BTRFS filesystem is mounted there."
    fsid="$(findmnt -no UUID -M "$mountpoint" 2>/dev/null || true)"
    devices="$(btrfs filesystem show "$mountpoint" 2>/dev/null | grep -c 'devid ' || true)"
    [[ "$devices" -eq 2 ]] || error_exit "Exactly two BTRFS RAID members must be present before RAID1 restoration."
    missing="$(find "/sys/fs/btrfs/$fsid/devinfo/" -type f -name missing -exec cat {} + 2>/dev/null | grep -cx '1' || true)"
    [[ "$missing" -eq 0 ]] || error_exit "A BTRFS RAID member is still missing; replace the failed device first."
    usage="$(btrfs filesystem usage "$mountpoint" 2>/dev/null || true)"
    echo
    echo "Current profiles:"
    printf '%s\n' "$usage" | grep -E '^(Data|Metadata|System|[[:space:]]*Multiple profiles)' || true
    if printf '%s\n' "$usage" | grep -Eqi '^(Data|Metadata|System),(single|dup):'; then
        echo
        echo "${GOLD}[-] ${NC}Converting non-RAID1 chunks to RAID1..."
        confirm "Restore the BTRFS RAID1 profiles now? This may perform extensive I/O." || return 0
        run_step btrfs balance start -v -dconvert=raid1,soft -mconvert=raid1,soft "$mountpoint"
    else
        echo "${GREEN}[+] ${NC}Data and metadata profiles are already RAID1."
    fi
    echo
    usage="$(btrfs filesystem usage "$mountpoint" 2>/dev/null || true)"
    printf '%s\n' "$usage" | grep -E '^(Data|Metadata|System|[[:space:]]*Multiple profiles)' || true
    printf '%s\n' "$usage" | grep -q '^Data,.*RAID1' || error_exit "Data profile is not RAID1 after restoration."
    printf '%s\n' "$usage" | grep -q '^Metadata,.*RAID1' || error_exit "Metadata profile is not RAID1 after restoration."
    ! printf '%s\n' "$usage" | grep -Eqi '^(Data|Metadata|System),(single|dup):' || error_exit "Non-RAID1 chunks remain after restoration."
    echo
    echo "${GOLD}[-] ${NC}Scrubbing restored RAID1 filesystem..."
    scrub_rc=0
    btrfs scrub start -B "$mountpoint" || scrub_rc=$?
    (( scrub_rc == 0 || scrub_rc == 3 )) || error_exit "BTRFS scrub failed."
    scrub_status="$(btrfs scrub status -d "$mountpoint" 2>/dev/null)" || error_exit "Could not read scrub status."
    printf '%s\n' "$scrub_status"
    if (( scrub_rc == 3 )) || printf '%s\n' "$scrub_status" | grep -Eiq 'Uncorrectable[[:space:]]*:[[:space:]]*[1-9]|Unverified[[:space:]]*:[[:space:]]*[1-9]|Corrected[[:space:]]*:[[:space:]]*[1-9]|csum[[:space:]]*=[[:space:]]*[1-9]|super[[:space:]]*=[[:space:]]*[1-9]|verify[[:space:]]*=[[:space:]]*[1-9]|read[[:space:]]*=[[:space:]]*[1-9]'; then
        log_transaction "restore" "ERRORS" "Mount point: $mountpoint" "FS UUID: $fsid" "Profiles: data=raid1, metadata=raid1 (verified)" "Scrub: errors reported; review scrub status"
        echo ""
        echo "${DEEP_RED}[-] WARNING:${NC} RAID1 restoration completed, but scrub reported errors requiring attention." >&2
        return 0
    fi
    log_transaction "restore" "SUCCESS" "Mount point: $mountpoint" "FS UUID: $fsid" "Profiles: data=raid1, metadata=raid1 (verified)" "Scrub: completed without reported errors"
    echo ""
    echo "${GREEN}[+]${NC} RAID1 restoration completed and scrub finished without reported errors.${NC}"
}

reconcile_raid(){
    local mountpoint srcdevid target targetpart target_identity pass targetmapper survivor survivorpart tbytes sbytes member dev type
    CURRENT_ACTION="replace"; LOG_START="$(date +%s)"
    read -rp "Mounted degraded BTRFS RAID 1 mount point: " mountpoint || mountpoint=""
    findmnt -rn -M "$mountpoint" -t btrfs >/dev/null 2>&1 || error_exit "No BTRFS filesystem is mounted there."
    echo "Current RAID membership:"
    btrfs filesystem show "$mountpoint" || error_exit "Could not inspect RAID membership."
    echo
    echo "On-disk superblock revisions of attached members:"
    while read -r dev; do
        [[ -b "$dev" ]] || continue
        echo "--- $dev ---"
        raid_member_info "$dev" || true
    done < <(btrfs_member_devices "$mountpoint")
    echo
    read -rp "BTRFS device ID to replace (missing member): " srcdevid || srcdevid=""
    [[ "$srcdevid" =~ ^[0-9]+$ ]] || error_exit "A numeric BTRFS device ID is required."
    [[ "$(cat "/sys/fs/btrfs/$(findmnt -no UUID -M "$mountpoint" 2>/dev/null)/devinfo/$srcdevid/missing" 2>/dev/null)" == 1 ]] || error_exit "BTRFS device ID $srcdevid is not a missing member of $mountpoint."
    target="$(select_raid_disk "Select the NEW replacement disk:")"
    target_identity="$(lsblk -dnro SIZE,MODEL,SERIAL,RO,RM,TRAN "$target" 2>/dev/null || true)"
    echo "${YELLOW}[+] Target: ${NC}$(show_target_identity "$target")"
    while read -r member; do
        while read -r dev type; do [[ "$target" != "$dev" ]] || error_exit "Replacement disk is already a RAID member."; done < <(lsblk -snrpo NAME,TYPE "$member" 2>/dev/null)
    done < <(btrfs_member_devices "$mountpoint")
    ! disk_in_use "$target" || error_exit "Replacement disk is in use (mounted, swap, an open encryption mapping, or a member of a mounted filesystem)."
    [[ "$(lsblk -dnro RO "$target")" == 0 ]] || error_exit "Replacement disk is read-only."
    survivor=""; read -r survivor < <(btrfs_member_devices "$mountpoint") || true
    [[ -b "$survivor" ]] || error_exit "Could not identify a surviving RAID member to validate against."
    survivorpart="$(luks_backing_device "$survivor" || true)"
    [[ -n "$survivorpart" ]] || error_exit "Could not locate the LUKS container backing $survivor."
    tbytes="$(blockdev --getsize64 "$target")"; sbytes="$(blockdev --getsize64 "$survivor")"
    (( tbytes >= sbytes + 17 * 1048576 + 16896 )) || error_exit "Replacement disk is too small: $tbytes bytes cannot hold a $sbytes byte member plus its partition and LUKS overhead."
    targetmapper="btrfs_raid1_replacement"; [[ ! -e "/dev/mapper/$targetmapper" ]] || error_exit "Mapper $targetmapper already exists; remount the RAID or close that mapping before replacing a drive."
    IFS= read -rsp "Existing LUKS password: " pass; echo
    [[ -n "$pass" ]] || error_exit "Password cannot be empty."
    printf '%s' "$pass" | cryptsetup open --test-passphrase --key-file=- "$survivorpart" || error_exit "That passphrase does not unlock the existing array member; refusing to format the replacement with a different key."
    confirm "Start BTRFS device replacement now? This will overwrite the replacement disk." || return 0
    [[ -n "$target_identity" && -b "$target" && "$(lsblk -dno TYPE "$target" 2>/dev/null)" == "disk" ]] || error_exit "Replacement disk is no longer available; nothing was erased."
    [[ "$(lsblk -dnro SIZE,MODEL,SERIAL,RO,RM,TRAN "$target" 2>/dev/null || true)" == "$target_identity" ]] || error_exit "Replacement disk identity changed; nothing was erased."
    targetpart="$target"
    run_step wipefs -a -f "$targetpart"
    run_step parted -s "$targetpart" mklabel gpt
    run_step parted -s "$targetpart" mkpart primary 1MiB 100%
    partprobe "$targetpart" 2>/dev/null || blockdev --rereadpt "$targetpart" 2>/dev/null || error_exit "Could not reread replacement disk partition table."
    udevadm settle
    targetpart="$(find_single_partition "$targetpart")"
    printf '%s' "$pass" | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --pbkdf-memory 4194304 --pbkdf-parallel 4 --iter-time 6000 --cipher aes-xts-plain64 --key-size 512 --key-file=- "$targetpart" || error_exit "Could not create LUKS2 replacement container."
    open_luks_member "$targetpart" "$targetmapper" "$pass"
    unset pass
    echo
    echo "[-] Rebuilding BTRFS device $srcdevid onto $targetmapper..."
    run_step btrfs replace start -B "$srcdevid" "/dev/mapper/$targetmapper" "$mountpoint"
    MAPPERS=()
    btrfs replace status -1 "$mountpoint" 2>/dev/null || true
    log_transaction "replace" "SUCCESS" "Mount point: $mountpoint" "Replaced devid: $srcdevid" "New disk: $target ($targetpart)" "Mapper: $targetmapper" "Encryption: LUKS2 aes-xts-plain64 (argon2id)"
    echo ""
    echo "${GREEN}[+]${NC} Replacement complete."
    btrfs filesystem show "$mountpoint"
    echo
    echo "Run Scrub / Verify Integrity now to validate the rebuilt mirror."
}


##########################################################################################################
# Action 6: RAID Diagnostics
##########################################################################################################
diagnostics_raid(){
    local d p
    CURRENT_ACTION="diagnostics"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "BTRFS Diagnostics (RO)"
    display_disks
    d="$(select_raid_disk "Disk to inspect (Unmounted RAID 1 member):")"
    p="$(find_single_partition "$d")"
    echo ""
    echo ""
    echo "${WHITE}===================== ${GOLD}DISK Health ${WHITE}=====================${NC}"
    echo "--- Partition ---"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,PARTUUID,RO,MODEL,SERIAL "$d" | awk 'NR == 1 || $1 !~ /^loop/ {print}'
    echo
    echo "--- LUKS header ---"
    cryptsetup luksDump "$p" 2>/dev/null | grep -Ei '^[[:space:]]*(Version|Keyslots|UUID|Cipher|Sector|offset|Data offset|Payload offset|Metadata area)' || true
    IFS= read -rsp "${GOLD}[!] ${NC}LUKS password to inspect BTRFS metadata: " pass; echo
    #open_luks_member "$p" btrfs_diag "$pass"
    printf "%s" "$pass" | cryptsetup open --readonly --key-file=- "$p" btrfs_diag || error_exit "Could not unlock $p."
    MAPPERS+=("btrfs_diag")
    unset pass    
    echo ""
    echo "--- BTRFS superblock ---"
    raid_member_info /dev/mapper/btrfs_diag || true
    cryptsetup close btrfs_diag 2>/dev/null || true
    MAPPERS=()
    echo
    echo "--- Recent kernel BTRFS messages ---"
    journalctl -k -b --no-pager 2>/dev/null | grep -i btrfs | tail -n 25 || true
    echo "${WHITE}=======================================================${NC}"
}


##########################################################################################################
# Action 0: Make RAID1
##########################################################################################################
create_raid(){
local mountpoint="" pass="" pass2="" DISKS=() IDENTITIES=() PARTITIONS=()
local n i name target root_src serial zero DO_ZERO LABEL dev usage child type
local TARGET_SIZE_BYTES part mapper attempt FS_UUID
MAPPERS=()
CURRENT_ACTION="create"; LOG_START="$(date +%s)"

clear 2>/dev/null || true
display_banner "Create a New BTRFS RAID 1"
display_disks
for n in 1 2; do
    while :; do
        read -rp "Select disk $n (e.g. sdb or /dev/sdb): " name || name=""
        name="${name#/dev/}"; target="/dev/$name"
        name="$(lsblk -dnro NAME "$target" 2>/dev/null || true)"; target="/dev/$name"
        [[ -n "$name" && -b "$target" && $(lsblk -dno TYPE "$target" 2>/dev/null) == disk ]] || { echo "Invalid whole disk."; continue; }
        [[ "$target" != "${DISKS[0]:-}" ]] || { echo "Select two different disks."; continue; }
        root_src="$(findmnt -no SOURCE --nofsroot / 2>/dev/null || true)"
        [[ -n "$root_src" ]] || error_exit "Could not determine the root device; refusing to continue."
        [[ "$target" != "$root_src" ]] || { echo "The running OS disk cannot be selected."; continue; }
        ! lsblk -nso PKNAME "$root_src" 2>/dev/null | grep -qx "$name" || { echo "The running OS disk cannot be selected."; continue; }
        serial="$(lsblk -dno SERIAL "$target" 2>/dev/null || true)"
        [[ -n "$serial" ]] || { echo "Could not determine a unique serial; refusing this disk."; continue; }
        [[ -z "${DISKS[0]:-}" || "$serial" != "$(lsblk -dno SERIAL "${DISKS[0]}" 2>/dev/null || true)" ]] || { echo "Select two different physical disks."; continue; }
        [[ "$(lsblk -dnro RO "$target")" == 0 ]] || { echo "Disk is read-only; refusing it."; continue; }
        ! disk_in_use "$target" || { echo "Disk is in use (mounted, swap, an open encryption mapping, or a member of a mounted filesystem); free it first."; continue; }
        DISKS+=("$target")
        IDENTITIES+=("$(lsblk -dnro SIZE,MODEL,SERIAL,RO,RM,TRAN "$target")")
        echo "${YELLOW}[+] Target: ${NC}$(show_target_identity "$target")"
        echo ""
        break
    done
done

read -rp "BTRFS filesystem label: " LABEL || LABEL=""
[[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$ ]] || error_exit "Label must start with a letter or number and contain only letters, numbers, - or _."
read -rp "Perform a full zero-fill before formatting both disks? (y/N): " zero || zero=""
DO_ZERO=false; [[ "$zero" =~ ^[yY]$ ]] && DO_ZERO=true
if [[ "$(lsblk -bdno SIZE "${DISKS[0]}")" != "$(lsblk -bdno SIZE "${DISKS[1]}")" ]]; then
    echo "${GOLD}[!] Notice:${NC} Disk sizes differ; BTRFS RAID 1 usable capacity will be limited by the smaller disk."
fi
echo ""

echo ""
echo "${WHITE}================ ${GOLD}Review Configuration ${WHITE}=================${NC}"
for i in 0 1; do 
    echo "Disk $((i+1))     :  ${CYAN}${DISKS[$i]} — $(printf '%b' "${IDENTITIES[$i]}")${NC}"
done
echo "Filesystem :  ${CYAN}BTRFS RAID 1${NC}"
echo "Encryption :  ${CYAN}LUKS2 AES-256-XTS${NC}"
echo "Drive Label:  ${CYAN}$LABEL${NC}"
echo "Zero-Fill  :  ${CYAN}$DO_ZERO${NC}"
echo "${WHITE}=======================================================${NC}"
echo ""
    confirm "${DEEP_RED}[!] WARNING:${NC} Are you sure? This action is irreversible." || return 0

IFS= read -rsp "Enter one encryption password for both disks: " pass; echo
IFS= read -rsp "Repeat encryption password: " pass2; echo
[[ -n "$pass" && "$pass" == "$pass2" ]] || error_exit "Passwords are empty or do not match."
unset pass2
for i in 0 1; do ! disk_in_use "${DISKS[$i]}" && [[ "$(lsblk -dnro SIZE,MODEL,SERIAL,RO,RM,TRAN "${DISKS[$i]}")" == "${IDENTITIES[$i]}" ]] || error_exit "${DISKS[$i]} is in use or has changed since it was selected; nothing was erased."; done
[[ ! -e /dev/mapper/btrfs_raid1_disk1 && ! -e /dev/mapper/btrfs_raid1_disk2 ]] || error_exit "btrfs_raid1_disk1/2 already exist (another RAID mounted by this tool, or a stale mapping); nothing was erased."

for i in 0 1; do
    target="${DISKS[$i]}"; name="${target#/dev/}"
    echo ""; echo "[-] Unmounting and closing existing mappings on $target..."
    while read -r child type; do
        [[ -n "$child" ]] || continue
        dev="/dev/$child"
        [[ "$type" == crypt ]] && dev="/dev/mapper/$child"
        swapoff "$dev" 2>/dev/null || true
        umount "$dev" 2>/dev/null || true
        [[ "$type" == crypt ]] && cryptsetup close "$child" 2>/dev/null || true
done < <(lsblk -rno NAME,TYPE "$target" 2>/dev/null | tac)
    ! disk_in_use "$target" || error_exit "$target is in use (mounted, swap, an open encryption mapping, or a member of a mounted filesystem); refusing to erase it."
    [[ "$(lsblk -dnro SIZE,MODEL,SERIAL,RO,RM,TRAN "$target")" == "${IDENTITIES[$i]}" ]] || error_exit "Identity of $target changed; aborting."
    [[ "$(lsblk -dnro RO "$target")" == 0 ]] || error_exit "$target became read-only; aborting."
    run_step wipefs -a -f "$target"
    if $DO_ZERO; then
        echo "[-] Executing FULL zero-fill wipe on $target..."
        echo "[-] This may take a while depending on drive size and interface speed..."
        TARGET_SIZE_BYTES="$(blockdev --getsize64 "$target")" || error_exit "Could not determine size of $target."
        [ "${TARGET_SIZE_BYTES:-0}" -gt 0 ] || error_exit "$target reports zero size."
        run_step dd if=/dev/zero of="$target" bs=4M count="$TARGET_SIZE_BYTES" iflag=count_bytes conv=fdatasync status=progress
    	echo ""
        echo "[-] Full zero-fill complete."
        run_step blockdev --flushbufs "$target"
        udevadm settle
    fi
        
    run_step parted -s "$target" mklabel gpt
    run_step parted -s "$target" mkpart primary 1MiB 100%
    partprobe "$target" 2>/dev/null || blockdev --rereadpt "$target" 2>/dev/null || error_exit "Could not reread partition table on $target."
    udevadm settle
    part=""
    for attempt in {1..10}; do part="$(lsblk -nrpo NAME,TYPE "$target" | awk '$2=="part"{print $1; exit}')"; [[ -b "$part" ]] && break; sleep 1; done
    [[ -b "$part" ]] || error_exit "Partition was not created on $target."
    run_step wipefs -a -f "$part"
    mapper="btrfs_raid1_disk$((i+1))"
    echo "[-] Creating LUKS2 on $part..."
    printf '%s' "$pass" | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --pbkdf-memory 4194304 --pbkdf-parallel 4 --iter-time 6000 --cipher aes-xts-plain64 --key-size 512 --key-file=- "$part" || error_exit "Command failed: cryptsetup luksFormat"
    echo "[-] Opening $mapper..."
    printf "%s" "$pass" | cryptsetup open --key-file=- "$part" "$mapper" || error_exit "Command failed: cryptsetup open"
    [[ -b "/dev/mapper/$mapper" ]] || error_exit "Mapper $mapper was not created."
    PARTITIONS+=("$part"); MAPPERS+=("$mapper")
done
unset pass
sync
echo ""; echo "[-] Creating BTRFS RAID 1 filesystem..."
run_step mkfs.btrfs -f -d raid1 -m raid1 -L "$LABEL" /dev/mapper/btrfs_raid1_disk1 /dev/mapper/btrfs_raid1_disk2
sync

echo "${GOLD}[-] ${NC}Verifying filesystem..."
blkid -o export /dev/mapper/btrfs_raid1_disk1 | grep -Fxq TYPE=btrfs || error_exit "BTRFS verification failed."
FS_UUID="$(blkid -o value -s UUID /dev/mapper/btrfs_raid1_disk1 2>/dev/null || true)"
mountpoint="$(mktemp -d /mnt/btrfs-verify.XXXXXX)"
VERIFY_MOUNTPOINT="$mountpoint"
run_step mount -t btrfs /dev/mapper/btrfs_raid1_disk1 "$mountpoint"
run_step btrfs filesystem show "$mountpoint"
usage="$(btrfs filesystem usage "$mountpoint" 2>/dev/null || true)"
printf '%s\n' "$usage" | grep -q 'Data,.*RAID1' || error_exit "BTRFS data profile is not RAID1."
printf '%s\n' "$usage" | grep -q 'Metadata,.*RAID1' || error_exit "BTRFS metadata profile is not RAID1."
run_step umount "$mountpoint"
rmdir "$mountpoint"
udevadm settle
cryptsetup close --deferred btrfs_raid1_disk2 || echo "${GOLD}[!] Notice:${NC} could not close btrfs_raid1_disk2."; MAPPERS=("btrfs_raid1_disk1")
cryptsetup close --deferred btrfs_raid1_disk1 || echo "${GOLD}[!] Notice:${NC} could not close btrfs_raid1_disk1."; MAPPERS=()
log_transaction "create" "SUCCESS" \
    "Disk 1: ${DISKS[0]} ($(printf '%b' "${IDENTITIES[0]}"))" \
    "Disk 2: ${DISKS[1]} ($(printf '%b' "${IDENTITIES[1]}"))" \
    "Partitions: ${PARTITIONS[*]}" \
    "Encryption: LUKS2 aes-xts-plain64 (argon2id)" \
    "Filesystem: BTRFS RAID 1 (data=raid1, metadata=raid1)" \
    "Label: $LABEL" \
    "FS UUID: ${FS_UUID:-n/a}" \
    "Zero-fill: $DO_ZERO"
echo "${GREEN}[+] Success!${NC} Encrypted BTRFS RAID 1 created across:"
printf '    %s\n' "${DISKS[@]}"
echo "    Label: $LABEL"
echo "    Encryption: LUKS2 AES-256-XTS"
echo "    BTRFS profiles: data=raid1, metadata=raid1"
}



##########################################################################################################
# Action 5-6: Subvolume & Snapshot Helpers
##########################################################################################################
# A snapshot is a subvolume, so list/delete/property are one worker each, switched by <kind>: subvol|snap.

confirm_return(){
    local reply
    read -rp "$1 (y/N): " reply || reply=""
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) echo "Operation canceled."; return 1 ;;
    esac; }

validate_subvol_name(){ [[ "$1" =~ ^[A-Za-z0-9@][A-Za-z0-9._@-]{0,63}$ ]] || error_exit "Name must be 1-64 characters, starting with a letter, number or @, using only letters, numbers, dot, dash, underscore or @."; }

is_readonly_subvol(){ [[ "$(btrfs property get "$1" ro 2>/dev/null || true)" == "ro=true" ]]; }

# Prints the RAID table to stderr so the chosen mount point is the only thing on stdout.
select_raid_mount(){
    local prompt="$1" want="${2:-}" i mp=""
    list_mounted_raids
    ((${#RAID_MOUNTS[@]})) || error_exit "No mounted BTRFS RAID 1 was found; mount one first."
    for i in "${!RAID_NAMES[@]}"; do printf '%s\t%s\n' "${RAID_NAMES[$i]}" "${RAID_MOUNTS[$i]}" >&2; done
    read -rp "$prompt " mp || mp=""
    for i in "${!RAID_NAMES[@]}"; do
        [[ "$mp" == "${RAID_MOUNTS[$i]}" || "$mp" == "${RAID_MOUNTS[$i]##*/}" ]] || continue
        mp="${RAID_MOUNTS[$i]}"; break
    done
    findmnt -rn -M "$mp" -t btrfs >/dev/null 2>&1 || error_exit "No BTRFS filesystem is mounted there."
    # Subvolume list paths are relative to the filesystem root, so <mount>/<path> only resolves at FSROOT /
    [[ "$(findmnt -no FSROOT -M "$mp" 2>/dev/null)" == "/" ]] || error_exit "$mp is not mounted at the BTRFS filesystem root; subvolume paths cannot be resolved safely."
    if [ "$want" = rw ]; then [[ ",$(findmnt -no VFS-OPTIONS -M "$mp" 2>/dev/null)," != *,ro,* ]] || error_exit "$mp is mounted read-only; remount it read-write first."; fi
    printf '%s\n' "$mp"
}

title_bar(){ local t="$1" p=$(( ${#1} < 53 ? (53 - ${#1}) / 2 : 0 )) bar="======================================================="; echo "${WHITE}${bar:0:p} ${GOLD}$t ${WHITE}${bar:0:$(( ${#t} < 53 ? 53 - ${#t} - p : 0 ))}${NC}"; }

show_subvol_table(){
    local mp="$1" kind="$2" noun="Subvolumes" flag="" ro_ids snap_ids
    if [ "$kind" = snap ]; then noun="Snapshots"; flag="-s"; fi
    ro_ids=" $(btrfs subvolume list -r "$mp" | awk '{ printf "%s ", $2 }')" || error_exit "Could not list read-only subvolumes on $mp."
    snap_ids=" $(btrfs subvolume list -s "$mp" | awk '{ printf "%s ", $2 }')" || error_exit "Could not list snapshots on $mp."
    echo ""
    title_bar "$noun on $mp"
    btrfs subvolume list $flag "$mp" | awk -v ro="$ro_ids" -v snap="$snap_ids" -v f='%-7s %-9s %-8s %-3s %s\n' 'NR == 1 { printf f, "ID", "Gen", "Snapshot", "RO", "Name" } { printf f, $2, $4, (index(snap, " " $2 " ") ? "*" : ""), (index(ro, " " $2 " ") ? "*" : ""), substr($0, index($0, " path ") + 6) } END { if (!NR) print "(None)" }' || error_exit "Could not list subvolumes on $mp."
    echo "${WHITE}=======================================================${NC}"
}

# Resolves user input to an absolute path proven to sit inside $mp and to be a real subvolume.
select_subvolume(){
    local mp="$1" kind="$2" p="" real=""
    show_subvol_table "$mp" "$kind" >&2
    echo "" >&2
    read -rp "Path or name (relative to $mp): " p || p=""
    [[ -n "$p" ]] || error_exit "A subvolume path is required."
    [[ "$p" == /* ]] || p="$mp/$p"
    real="$(realpath -m "$p" 2>/dev/null || true)"
    [[ -n "$real" && "$real" == "$mp/"* ]] || error_exit "$p does not resolve to a location inside $mp; refusing to continue."
    [[ -d "$real" ]] || error_exit "$real does not exist."
    btrfs subvolume show "$real" >/dev/null 2>&1 || error_exit "$real is not a BTRFS subvolume."
    printf '%s\n' "$real"
}

# Checks processes whose cwd, root, or open fd is inside the subvolume.
subvolume_in_use(){
    local path="$1"
    find /proc -maxdepth 3 -type l \
        \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/root' -o -path '/proc/[0-9]*/fd/*' \) \
        \( -lname "$path" -o -lname "$path/*" -o -lname "$path/* (deleted)" \) \
        2>/dev/null | grep -q .
}


##########################################################################################################
# Action 5: Subvolume Menu
##########################################################################################################
subvolume_menu(){
    local _
    while :; do
        MENU_TITLE="Subvolume Menu"
        menu_select "List Subvolumes" \
            "Create Subvolume" \
            "Create Snapshot" \
            "Delete Subvolume or Snapshot" \
            "Set Read-Only / Read-Write" \
            "Roll Back to Snapshot" \
            "Subvolume Diagnostic Report" \
            "Back"
        case "$MENU_CHOICE" in
            0) btrfs_list_subvols subvol ;;
            1) subvol_create ;;
            2) snap_create ;;
            3) btrfs_delete_subvol subvol ;;
            4) btrfs_set_ro_prop subvol ;;
            5) snap_rollback ;;
            6) subvol_diagnostics ;;
            7) return 0 ;;
        esac
        CURRENT_ACTION=""
        echo ""
        read -rp "Press Enter to return to Subvolumes..." _ || { echo; exit 0; }
    done
}

# Read-only inspection: logs on failure through error_exit only, matching raid_health/diagnostics_raid.
btrfs_list_subvols(){
    local kind="$1" mp noun="Subvolume"
    if [ "$kind" = snap ]; then noun="Snapshot"; fi
    CURRENT_ACTION="$kind-list"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "BTRFS $noun Inventory" "Read-only inspection."
    mp="$(select_raid_mount "Mount name to inspect:")"
    show_subvol_table "$mp" "$kind"
}

# Read-only report, same logging rule as above. Output is tee'd to DISKUTILS/REPORTS as the invoking user;
# resolve_log_location runs here because diskutils_dir's subshell cannot set LOG_USER for this shell.
subvol_diagnostics(){
    local mp dir file
    CURRENT_ACTION="subvol-diagnostics"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "BTRFS Subvolume Diagnostics" "Read-only inspection."
    mp="$(select_raid_mount "Mount name to inspect:")"
    resolve_log_location; dir="$(diskutils_dir REPORTS)" || error_exit "Could not create the REPORTS folder."
    file="$dir/subvol-diagnostics_${mp##*/}_$(date +%F_%H%M%S).txt"
    echo ""; echo ""; title_bar "Subvolume Diagnostic Report"
    { show_subvol_table "$mp" subvol
      echo ""; echo "Quota groups:"; btrfs qgroup show -re "$mp" || true
      btrfs subvolume list "$mp" | while read -r _ id _; do echo ""; btrfs subvolume show -r "$id" "$mp" || true; done
    } 2>&1 | tee /dev/tty | sed 's/\x1b\[[0-9;]*m//g' | runuser -u "$LOG_USER" -- tee "$file" >/dev/null || { ((PIPESTATUS[0] == LOGGED_RC)) && FAILURE_LOGGED=true; error_exit "Could not complete the report: $file"; }
    echo "${WHITE}=======================================================${NC}"
    echo ""; echo "${GREEN}[+] ${NC}Report saved: $file"
}

subvol_create(){
    local mp name target
    CURRENT_ACTION="subvol-create"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "Create a BTRFS Subvolume" "Proceed with caution."
    mp="$(select_raid_mount "Mount name to operate on:" rw)"
    show_subvol_table "$mp" subvol
    echo ""
    read -rp "New subvolume name (e.g. @data): " name || name=""
    validate_subvol_name "$name"
    target="$mp/$name"
    [[ ! -e "$target" ]] || error_exit "$target already exists."
    run_step btrfs subvolume create "$target" >/dev/null
    log_transaction "subvol-create" "SUCCESS" "Mount point: $mp" "Subvolume: $target"
    echo ""
    echo "${GREEN}[+] ${NC}Subvolume created: $target"
}

btrfs_delete_subvol(){
    local kind="$1" mp target noun="Subvolume"
    if [ "$kind" = snap ]; then noun="Snapshot"; fi
    CURRENT_ACTION="$kind-delete"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "Delete a BTRFS $noun" "Deletion is permanent and cannot be undone."
    mp="$(select_raid_mount "Mount name to operate on:" rw)"
    target="$(select_subvolume "$mp" "$kind")"
    ! mountpoint -q "$target" && [[ $'\n'"$(findmnt -lno TARGET 2>/dev/null)" != *$'\n'"$target/"* ]] || error_exit "$target or something below it is a mount point; unmount it first."
    echo ""
    confirm_return "${DEEP_RED}[!] WARNING:${NC} Permanently delete $target?" || return 0
    run_step btrfs subvolume delete "$target" >/dev/null
    log_transaction "$kind-delete" "SUCCESS" "Mount point: $mp" "$noun: $target"
    echo ""
    echo "${GREEN}[+] ${NC}$noun deleted: $target"
}

btrfs_set_ro_prop(){
    local kind="$1" mp target cur want noun="Subvolume"
    if [ "$kind" = snap ]; then noun="Snapshot"; fi
    CURRENT_ACTION="$kind-prop"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "Set BTRFS $noun Read-Only Property" "Proceed with caution."
    mp="$(select_raid_mount "Mount name to operate on:" rw)"
    target="$(select_subvolume "$mp" "$kind")"
    if is_readonly_subvol "$target"; then cur=true; want=false; else cur=false; want=true; fi
    echo ""
    printf "%-10s:   ${CYAN}%s${NC}\n" "$noun" "$target"
    echo "Current   :   ${CYAN}ro=$cur${NC}"
    echo "New       :   ${CYAN}ro=$want${NC}"
    echo ""
    confirm_return "Set the read-only property to $want?" || return 0
    run_step btrfs property set "$target" ro "$want"
    log_transaction "$kind-prop" "SUCCESS" "Mount point: $mp" "$noun: $target" "Property: ro=$cur -> ro=$want"
    echo ""
    echo "${GREEN}[+] ${NC}$noun is now ro=$want"
}

snap_create(){
    local mp src name target mode opt="-r" ro="Read-only" def
    CURRENT_ACTION="snap-create"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "Create a BTRFS Snapshot" "Proceed with caution."
    mp="$(select_raid_mount "Mount name to operate on:" rw)"
    src="$(select_subvolume "$mp" subvol)"
    echo ""
    def="${src##*/}"; def="${def:0:41}_snap_$(date +%F_%H%M%S)"
    read -rp "Snapshot name (Enter for $def): " name || name=""
    [[ -n "$name" ]] || name="$def"
    validate_subvol_name "$name"
    target="$mp/$name"
    [[ ! -e "$target" ]] || error_exit "$target already exists."
    read -rp "Create as read-only? (Y/n): " mode || mode=""
    case "$mode" in n|N|no|NO) opt=""; ro="Read-write" ;; esac
    run_step btrfs subvolume snapshot $opt "$src" "$target"
    log_transaction "snap-create" "SUCCESS" "Mount point: $mp" "Source: $src" "Snapshot: $target" "Mode: $ro"
    echo ""
    echo "${GREEN}[+] ${NC}$ro snapshot created: $target"
}

snap_rollback(){
    local mp snap live broken temp nested live_id default_id new_live_id mounted opts
    CURRENT_ACTION="snap-rollback"; LOG_START="$(date +%s)"
    clear 2>/dev/null || true
    display_banner "Roll Back to a BTRFS Snapshot" "The live subvolume is renamed, not deleted."
    mp="$(select_raid_mount "Mount name to operate on:" rw)"
    echo ""
    echo "${GOLD}[!] ${NC}Select the read-only snapshot to roll back to."
    snap="$(select_subvolume "$mp" snap)"
    is_readonly_subvol "$snap" || error_exit "$snap is not read-only; roll back only from a read-only snapshot."
    echo ""
    echo "${GOLD}[!] ${NC}Select the live subvolume to replace."
    live="$(select_subvolume "$mp" subvol)"
    [[ "$live" != "$snap" && "$snap" != "$live/"* ]] || error_exit "The snapshot cannot be the live subvolume or stored inside it."
    ! mountpoint -q "$live" && [[ $'\n'"$(findmnt -lno TARGET 2>/dev/null)" != *$'\n'"$live/"* ]] || error_exit "$live or something below it is a mount point; unmount it first."
    nested="$(btrfs subvolume list -o "$live" 2>/dev/null)" || error_exit "Could not inspect nested subvolumes under $live."
    [[ -z "$nested" ]] || error_exit "$live contains nested subvolumes; roll back those subvolumes separately first."
    subvolume_in_use "$live" && error_exit "$live is in use by a process; stop access to it before rolling back."
    live_id="$(btrfs subvolume show "$live" 2>/dev/null | awk -F': ' '/^Subvolume ID:/{print $2; exit}')"
    [[ -n "$live_id" ]] || error_exit "Could not determine the live subvolume ID."
    default_id="$(btrfs subvolume get-default "$mp" 2>/dev/null | awk '/^ID /{print $2; exit}')"
    [[ -n "$default_id" ]] || error_exit "Could not determine the BTRFS default subvolume."
    while read -r mounted opts; do
        [[ "$mounted" == "$mp" ]] && continue
        [[ ",$opts," == *",subvolid=$live_id,"* ]] && error_exit "$live is mounted elsewhere by subvolume ID $live_id at $mounted; unmount it first."
    done < <(findmnt -rn -t btrfs -o TARGET,OPTIONS)
    broken="${live}_broken_$(date +%F_%H%M%S)"
    temp="${live}_rollback_$(date +%F_%H%M%S)"
    [[ ! -e "$broken" && ! -e "$temp" ]] || error_exit "Rollback destination already exists; choose another time before retrying."
    echo ""
    title_bar "Review Rollback"
    echo "Live subvolume:  ${CYAN}$live${NC}"
    echo "Renamed to    :  ${CYAN}$broken${NC}"
    echo "Restored from :  ${CYAN}$snap${NC}"
    echo "${WHITE}=======================================================${NC}"
    echo ""
    confirm_return "${DEEP_RED}[!] WARNING:${NC} Replace $live with a read-write snapshot of $snap?" || return 0
    subvolume_in_use "$live" && error_exit "$live became active again; stop access to it before rolling back."
    btrfs subvolume snapshot "$snap" "$temp" || error_exit "Could not create the rollback snapshot."
    new_live_id="$(btrfs subvolume show "$temp" 2>/dev/null | awk -F': ' '/^Subvolume ID:/{print $2; exit}' || true)"
    if [[ -z "$new_live_id" ]]; then
        btrfs subvolume delete "$temp" >/dev/null 2>&1 || true
        error_exit "Could not determine the rollback snapshot ID."
    fi
    subvolume_in_use "$live" && { btrfs subvolume delete "$temp" >/dev/null 2>&1 || true; error_exit "$live became active again; stop access to it before rolling back."; }
    ROLLBACK_ACTIVE=true
    ROLLBACK_MOUNT="$mp"
    ROLLBACK_LIVE="$live"
    ROLLBACK_BROKEN="$broken"
    ROLLBACK_TEMP="$temp"
    ROLLBACK_LIVE_ID="$live_id"
    ROLLBACK_DEFAULT_ID="$default_id"
    ROLLBACK_NEW_ID="$new_live_id"
    if ! mv -T "$live" "$broken"; then
        rollback_restore_original || true
        error_exit "Could not rename $live to $broken; the live subvolume was not replaced."
    fi
    if ! mv -T "$temp" "$live"; then
        if rollback_restore_original; then
            error_exit "Could not install the rollback snapshot at $live; the original was restored."
        fi
        error_exit "Could not install the rollback snapshot at $live; automatic restoration of the original failed."
    fi
    ROLLBACK_TEMP=""
    new_live_id="$(btrfs subvolume show "$live" 2>/dev/null | awk -F': ' '/^Subvolume ID:/{print $2; exit}' || true)"
    if [[ -z "$new_live_id" || "$new_live_id" != "$ROLLBACK_NEW_ID" ]]; then
        if rollback_restore_original; then
            error_exit "Could not verify the new live subvolume ID; the original was restored."
        fi
        error_exit "Could not verify the new live subvolume ID; automatic restoration of the original failed."
    fi
    if [[ "$default_id" == "$live_id" ]]; then
        if ! btrfs subvolume set-default "$new_live_id" "$mp" >/dev/null 2>&1 ||
           [[ "$(btrfs subvolume get-default "$mp" 2>/dev/null | awk '/^ID /{print $2; exit}')" != "$new_live_id" ]]; then
            if rollback_restore_original; then
                error_exit "Could not set the rolled-back subvolume as the default; the original was restored."
            fi
            error_exit "Could not set the rolled-back subvolume as the default; automatic restoration of the original failed."
        fi
    fi
    rollback_clear_state
    log_transaction "snap-rollback" "SUCCESS" "Mount point: $mp" "Snapshot: $snap" "New live: $live (ID $new_live_id)" "Previous: $broken (ID $live_id)"
    echo ""
    echo "${GREEN}[+] ${NC}Rolled back $live from $snap"
    echo "    Previous subvolume preserved at $broken"
}

show_menu
