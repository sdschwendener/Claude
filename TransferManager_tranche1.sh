#!/bin/bash
set -euo pipefail


if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then GREEN='' GOLD='' DEEP_RED='' CYAN='' YELLOW='' WHITE='' NC=''
else
    GREEN=$'\033[1;32m' GOLD=$'\033[1;38;5;214m' DEEP_RED=$'\033[1;38;5;160m'
    CYAN=$'\e[1;36m' YELLOW=$'\033[1;33m' WHITE=$'\033[1;37m' NC=$'\033[0m'
fi
if [ -t 1 ]; then CR=$'\r\033[2K' EOL='' COLS=$(tput cols 2>/dev/null || echo 80); else CR='' EOL=$'\n' COLS=200; fi


HELP_MESSAGE=$(cat << EOF

=========================================

Usage: sudo ./${0##*/} 

Description:
  This script migrates directories and files while simultaneously
  generating hash records and metadata.
  
  A typical workflow: Hash -> Copy -> Verify -> Metadata

=========================================
EOF
)

ACTIONB="${1:-}"
case "$ACTIONB" in
    -h|--help|-help)
        echo "$HELP_MESSAGE"
        exit 0 ;;
esac

if [ "$#" -gt 1 ]; then
    echo "Ignoring extra argument(s): ${*:2}" >&2
fi

# Ensure script is run with sudo privileges
if [[ $EUID -ne 0 ]]; then
   echo "${DEEP_RED}[ERROR] This script must be run as sudo/root to obtain comprehensive filesystem metadata.${NC}" 
   exit 1
fi
exec 9>/run/.transfermanager.lock && flock -n 9 || { echo "${DEEP_RED}[ERROR] Another instance is already running, or /run is not writable.${NC}"; exit 1; }
if [ -t 1 ]; then clear 2>/dev/null || true; fi
EXCLUDE_FILES=( -name '._localhash.sha256*' -o -name '._hash_errors.log' -o -name '._manifest-metadata.jsonl' -o -name '._manifest-header.meta' -o -name '._manifest-hashrecord.sha256*')

display_banner() {
    local title="${1:-File Transfer Manager}" warn="${2:-Proceed with caution.}"
    echo ""
    echo "${WHITE}=======================================================${NC}"
    printf '%s%*s%s\n' "$GOLD" "$(( (54 + ${#title}) / 2 ))" "$title" "$NC"
    echo ""
    echo "${GREEN}Usage: '${0##*/} -h' for help.${NC}"
    echo "${DEEP_RED}WARNING: ${warn}${NC}"
    echo "${WHITE}=======================================================${NC}"
    echo ""; }

# Interactive input: $1 = variable name, $2 = prompt, $3 = set if the final component may not exist yet, or "dir" to require an existing directory (stored resolved)
prompt_path() {
    local val="${!1-}"
    while :; do
        read -r -e -i "$val" -p "$2" val
        case $val in "~"|"~/"*) HM=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6); [ -z "$HM" ] || val="$HM${val#\~}" ;; -*) val=./$val ;; esac
        [ "${3-}" = dir ] && { [ -d "$val" ] && val=$(realpath -e -- "$val") && break; echo "${DEEP_RED}[-] Error:${NC} '$val' is not an existing directory."; continue; }
        [ -n "$val" ] && { [ -e "$val" ] || [ -L "$val" ] || { [ -n "${3-}" ] && [ -d "$(dirname "$val")" ]; }; } && break
        echo "${DEEP_RED}[-] Error:${NC} '$val' does not exist${3:+ (only the final folder may be new)}."
    done
    printf -v "$1" '%s' "$val"
}

# Prints $1 with $2's entry removed. Callers compose the replacement and rename it into place.
ledger_drop() {
    [ -f "$1" ] || return 0
    local t=$2; t=${t//\\/\\\\}; t=${t//$'\n'/\\n}
    LD_T="$t" awk 'BEGIN{t=ENVIRON["LD_T"]} { line=$0; sub(/^\\/,"",line); sub(/^(SYMLINK:)?[a-fA-F0-9]{64}[[:space:]]*\*?/,"",line); if (line != t) print }' "$1"
}

# Returns 0 if the FS is writable, 1 if read only or not writable
fs_is_rw() {
    local P="$1"
    while [ ! -e "$P" ] && [ ! -L "$P" ] && [ "$P" != "/" ]; do P=$(dirname -- "$P"); done
    [ -w "$P" ] || return 1
    return 0
}

process_hash_directory() {
    local SUBDIR="$1" FAILLOG="$2"
    (
	trap 'echo "FAILED $SUBDIR (unexpected error)" >> "$FAILLOG"; exit 0' ERR
	cd "$SUBDIR" 2>> "$FAILLOG" || { echo "UNREADABLE $SUBDIR (cannot enter)" >> "$FAILLOG"; exit 0; }
	CHECKSUM_FILE="._localhash.sha256"
	NEW_FILES_IN_DIR=0 LEDGER_CHANGED=0
	declare -a LEDGER_LINES=()
	declare -A LEDGER=() UPDATED=()
	if [ -f "$CHECKSUM_FILE" ]; then
	    while IFS= read -r LINE || [ -n "$LINE" ]; do
	        LEDGER_LINES+=("$LINE")
	        KEY=${LINE#\\}
	        if [[ "$KEY" =~ ^SYMLINK:[a-fA-F0-9]{64}[[:space:]]*(.*)$ ]]; then
		    KEY=${BASH_REMATCH[1]}
	        elif [[ "$KEY" =~ ^[a-fA-F0-9]{64}[[:space:]]*(.*)$ ]]; then
		    KEY=${BASH_REMATCH[1]}
	        else
		    KEY=''
	        fi
	        [ -n "$KEY" ] && LEDGER["$KEY"]=1
	    done < "$CHECKSUM_FILE"
	fi
	while IFS= read -r -d '' FILE; do
	    F_NAME=${FILE#./}; E_NAME=${F_NAME//\\/\\\\}; E_NAME=${E_NAME//$'\n'/\\n}
	    ALREADY_LOGGED=0
	    if [ -f "$CHECKSUM_FILE" ] && [ ! -L "$FILE" ] && [ ! "$FILE" -nt "$CHECKSUM_FILE" ] && [[ -n "${LEDGER[$E_NAME]+x}" ]]; then
	        ALREADY_LOGGED=1
	    fi
	    if [ "$ALREADY_LOGGED" -eq 1 ]; then
	        continue
	    fi
	    printf '%s%s  ->%s Hashing: %.*s%s' "$CR" "$GREEN" "$NC" "$((COLS-15))" "${SUBDIR##*/}/$F_NAME" "$EOL"
	    if [ -L "$F_NAME" ]; then
	        NEW_LINE="SYMLINK:$(readlink -n -- "$F_NAME" | sha256sum | cut -d' ' -f1)  $E_NAME"
	    else
	        NEW_LINE=$(sha256sum -- "$F_NAME" 2>> "$FAILLOG") || { echo "UNREADABLE $SUBDIR/$F_NAME" >> "$FAILLOG"; continue; }
	    fi
	    UPDATED["$E_NAME"]="$NEW_LINE"
	    LEDGER_CHANGED=1
	    NEW_FILES_IN_DIR=$((NEW_FILES_IN_DIR+1))
	done < <(find . -maxdepth 1 \( -type f -o -type l \) ! \( "${EXCLUDE_FILES[@]}" \) -print0 2>> "$FAILLOG" || echo "TRAVERSAL-FAILED $SUBDIR" >> "$FAILLOG")

	if [ "$LEDGER_CHANGED" -gt 0 ]; then
	    {
	        for LINE in "${LEDGER_LINES[@]}"; do
		    KEY=${LINE#\\}
		    if [[ "$KEY" =~ ^SYMLINK:[a-fA-F0-9]{64}[[:space:]]*(.*)$ ]]; then
		        KEY=${BASH_REMATCH[1]}
		    elif [[ "$KEY" =~ ^[a-fA-F0-9]{64}[[:space:]]*(.*)$ ]]; then
		        KEY=${BASH_REMATCH[1]}
		    else
		        KEY=''
		    fi
		    [ -n "$KEY" ] && [ -n "${UPDATED[$KEY]+x}" ] || printf '%s\n' "$LINE"
	        done
	        for KEY in "${!UPDATED[@]}"; do
		    printf '%s\n' "${UPDATED[$KEY]}"
	        done
	    } | LC_ALL=C sort -k 2 > "$CHECKSUM_FILE.tmp" && mv -- "$CHECKSUM_FILE.tmp" "$CHECKSUM_FILE"
	fi
    )
}

# Recursively hash through subdirectories, safely handling spaces and special characters
hash_tree() {
    local SUBDIR DROP FAILLOG NDIRS=0; FAILLOG=$(mktemp -p /run transfermanager-hash-errors.XXXXXX) || { echo "${DEEP_RED}[-] Error:${NC} Cannot create the hash error log under /run."; return 1; }
    echo ""
    [ -z "${2:-}" ] && { echo ""; echo "${YELLOW}[!]${NC} Generating and updating per-folder SHA-256 hash files..."; }
    while IFS= read -r -d '' SUBDIR; do 
	process_hash_directory "$SUBDIR" "$FAILLOG"; NDIRS=$((NDIRS+1))
    #done < <(find "$1" -path "$1/._MANIFESTS" -prune -o -type d -print0 2>> "$FAILLOG" || echo "TRAVERSAL-FAILED $1" >> "$FAILLOG")
    done < <(if [ -n "${2:-}" ]; then printf '%s\0' "$2"; else find "$1" -path "$1/._MANIFESTS" -prune -o -type d -print0 2>> "$FAILLOG" || echo "TRAVERSAL-FAILED $1" >> "$FAILLOG"; fi)
    [ "$NDIRS" -gt 0 ] || echo "TRAVERSAL-FAILED $1 (no directories visited)" >> "$FAILLOG"
    [ -s "$FAILLOG" ] && { DROP=$(desktop_dir) && mkdir -p -- "$DROP/DISKUTILS" 2>/dev/null && cp --remove-destination --no-preserve=mode -- "$FAILLOG" "$DROP/DISKUTILS/._hash_errors.log" 2>/dev/null && rm -f -- "$FAILLOG" && FAILLOG="$DROP/DISKUTILS/._hash_errors.log"; echo "${CR}${DEEP_RED}[!] Incomplete!${NC} $(grep -c '^UNREADABLE' "$FAILLOG" || :) unreadable, $(grep -c '^FAILED' "$FAILLOG" || :) failed, $(grep -c '^TRAVERSAL-FAILED' "$FAILLOG" || :) traversal errors. See $FAILLOG."; return 1; } || { [ -z "${2:-}" ] && echo ""; echo "${CR}${GREEN}[+] Success!${NC} All directory hashes updated and sorted."; rm -f "$FAILLOG"; }
}

action_copy() {
    echo ""
    prompt_path SOURCE "Step 1: Enter the source path (file or directory): "
    prompt_path DEST   "Step 2: Enter the destination path (file or directory): " new
    echo ""
    read -r -p "Confirm '${CYAN}$SOURCE${NC}' -> '${CYAN}$DEST${NC}'? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        echo "${DEEP_RED}[-] Error:${NC} Aborted by user."
        exit 1
    fi
    if ! fs_is_rw "$DEST"; then
        echo "${YELLOW}[!]${NC} Destination '$DEST' is not writable or is read-only; Copy Files and Hash is unavailable." 
        return 1
    fi

    if [ -L "$SOURCE" ] && [ -d "$SOURCE" ]; then read -r -p "'$SOURCE' is a symlink to a directory. Copy the (l)ink itself or the (d)irectory it points to? [l/D]: " STYPE; case $STYPE in [Ll]) ;; [Dd]|"") SOURCE=$(realpath -e -- "$SOURCE") ;; *) echo "${DEEP_RED}[-] Error:${NC} Answer l or d."; exit 1 ;; esac; fi
    # FILE COPY LOGIC #########################################################################################
    if [ -L "$SOURCE" ] || [ -f "$SOURCE" ]; then
        echo "${YELLOW}[!]${NC} File or symlink detected. Using cp -a..."
        
        # Determine target directory and file paths safely
        DTYPE=d; [ -d "$DEST" ] || { [ -e "$DEST" ] && DTYPE=f || { read -r -p "'$DEST' does not exist. Create as (f)ile or (d)irectory? [f/D]: " DTYPE; case $DTYPE in [Ff]) DTYPE=f ;; [Dd]|"") DTYPE=d ;; *) echo "${DEEP_RED}[-] Error:${NC} Answer f or d."; exit 1 ;; esac; }; }
        if [ "$DTYPE" = d ]; then
            TARGET_DIR="$DEST"
            TARGET_FILE="$DEST/$(basename "$SOURCE")"
        else
            TARGET_DIR=$(dirname "$DEST")
            TARGET_FILE="$DEST"
        fi
        if [ -e "$TARGET_FILE" ] || [ -L "$TARGET_FILE" ]; then
            [ -f "$TARGET_FILE" ] && [ ! -L "$TARGET_FILE" ] || { echo "${DEEP_RED}[-] Error:${NC} '$TARGET_FILE' exists and is not a regular file; refusing to replace it."; exit 1; }
            read -r -p "'$TARGET_FILE' already exists. Overwrite? [y/N]: " CONFIRM && [[ "$CONFIRM" =~ ^[Yy] ]] || { echo "${DEEP_RED}[-] Error:${NC} Aborted by user."; exit 1; }
        fi
        mkdir -p -- "$TARGET_DIR" || { echo "${DEEP_RED}[-] Error:${NC} Failed to create destination directory."; exit 1; }
        cp -a -T --remove-destination -- "$SOURCE" "$TARGET_FILE" || { echo "${DEEP_RED}[-] Error:${NC} File copy failed."; exit 1; }
        [ -L "$SOURCE" ] || cmp -s -- "$SOURCE" "$TARGET_FILE" || { echo "${DEEP_RED}[-] Error:${NC} Copy verification failed."; exit 1; }
        F_NAME=$(basename "$TARGET_FILE")
        
        # Isolate directory navigation in a subshell for safety, append new hash and sort deterministically
        (
            cd "$TARGET_DIR" || exit 1
            CHECKSUM_FILE="._localhash.sha256"
            echo "${GREEN}  ->${NC} Hashing file: $F_NAME"
            NEW_HASH_LINE=$([ -L "$F_NAME" ] && printf 'SYMLINK:%s  %s' "$(readlink -n -- "$F_NAME" | sha256sum | cut -d' ' -f1)" "$F_NAME" || sha256sum -- "$F_NAME")
            { ledger_drop "$CHECKSUM_FILE" "$F_NAME"; printf '%s\n' "$NEW_HASH_LINE"; } > "$CHECKSUM_FILE.tmp" && mv -- "$CHECKSUM_FILE.tmp" "$CHECKSUM_FILE"
            LC_ALL=C sort -k 2 "$CHECKSUM_FILE" > "$CHECKSUM_FILE.tmp" && mv -- "$CHECKSUM_FILE.tmp" "$CHECKSUM_FILE"
            echo ""
            echo "${GREEN}[+] Success!${NC} File copied and checksum updated."
        )

    # DIRECTORY COPY LOGIC ####################################################################################
    elif [ -d "$SOURCE" ]; then
        echo ""; echo "";
        echo "${YELLOW}[!]${NC} Directory detected. Using ordered, directory-wise rsync -ah."
        case "$(realpath -m -- "$DEST")/" in "$(realpath -- "$SOURCE")"/*) echo "${DEEP_RED}[-] Error:${NC} Destination is the source or lies inside it."; exit 1 ;; esac
        COPY_TMP=$(mktemp -d) || { echo "${DEEP_RED}[-] Error:${NC} Failed to create temporary copy workspace."; exit 1; }
        COPY_LIST="$COPY_TMP/tree.list"; COPY_FILES="$COPY_TMP/files"; printf '.\0' > "$COPY_TMP/root.files"
        if ! python3 -c 'import os,sys; R=sys.argv[1].encode(); O=open(sys.argv[2],"wb"); exec("def f(r):\n ds=[]; fs=[]\n for x in os.scandir(r): (ds if x.is_dir(follow_symlinks=False) else fs).append(x.name)\n for x in sorted(fs): O.write(os.path.join(r,x)+bytes([0]))\n for x in sorted(ds): O.write(os.path.join(r,x)+bytes([0])); f(os.path.join(r,x))\nf(R)")' "${SOURCE%/}" "$COPY_LIST"; then
            echo "${DEEP_RED}[-] Error:${NC} Source traversal failed."; rm -rf -- "$COPY_TMP"; exit 1
        fi
        CUR_REL= CUR_SRC="${SOURCE%/}" CUR_DST="$DEST"; : > "$COPY_FILES"
        while IFS= read -r -d '' ENTRY; do
            REL=${ENTRY#"${SOURCE%/}"/}
            if [ -d "$ENTRY" ] && [ ! -L "$ENTRY" ]; then
                if [ -n "$CUR_REL" ] && [ -s "$COPY_FILES" ]; then
                    rsync -ah --partial --info=progress2 --from0 --files-from="$COPY_FILES" "${CUR_SRC%/*}/" "${CUR_DST%/*}/" 2>>"$COPY_TMP/errors" | stdbuf -o0 tr '\r' '\n' | while IFS= read -r LINE; do LINE=${LINE#"${CUR_SRC##*/}/"}; printf '%s%-16.16s %s' "$CR" "${CUR_SRC##*/}" "$LINE"; done || { rm -rf -- "$COPY_TMP"; exit 1; }
                    hash_tree "$DEST" "$CUR_DST" || { rm -rf -- "$COPY_TMP"; exit 1; }
                fi
                CUR_REL="$REL"; CUR_SRC="$ENTRY"; CUR_DST="$DEST/$REL"; printf '%s/\0' "${CUR_SRC##*/}" > "$COPY_FILES"
            else
                PARENT=${REL%/*}; NAME=${REL##*/}
                if [ "$PARENT" = "$REL" ]; then
                    printf '%s\0' "$NAME" >> "$COPY_TMP/root.files"
                elif [ "$PARENT" = "$CUR_REL" ]; then
                    printf '%s/%s\0' "${CUR_SRC##*/}" "$NAME" >> "$COPY_FILES"
                else
                    echo "${DEEP_RED}[-] Error:${NC} Unexpected traversal order at '$REL'."; rm -rf -- "$COPY_TMP"; exit 1
                fi
            fi
        done < "$COPY_LIST"
        if [ -n "$CUR_REL" ] && [ -s "$COPY_FILES" ]; then
            rsync -ah --partial --info=progress2 --from0 --files-from="$COPY_FILES" "${CUR_SRC%/*}/" "${CUR_DST%/*}/" 2>>"$COPY_TMP/errors" | stdbuf -o0 tr '\r' '\n' | while IFS= read -r LINE; do LINE=${LINE#"${CUR_SRC##*/}/"}; printf '%s%s' "$CR" "$LINE"; done || { rm -rf -- "$COPY_TMP"; exit 1; }
            hash_tree "$DEST" "$CUR_DST" || { rm -rf -- "$COPY_TMP"; exit 1; }
        fi
        if [ -s "$COPY_TMP/root.files" ]; then
            rsync -ah --partial --info=progress2 --from0 --files-from="$COPY_TMP/root.files" "${SOURCE%/}/" "$DEST/" 2>>"$COPY_TMP/errors" | stdbuf -o0 tr '\r' '\n' | while IFS= read -r LINE; do printf '%s%s' "$CR" "$LINE"; done || { rm -rf -- "$COPY_TMP"; exit 1; }
            hash_tree "$DEST" "$DEST" || { rm -rf -- "$COPY_TMP"; exit 1; }
        fi
        echo ""
        echo "${CR}${GREEN}[+] Success!${NC} Directory copy and per-directory hashes complete."
        rm -rf -- "$COPY_TMP"
    else echo ""; echo "${DEEP_RED}[-] Error:${NC} '$SOURCE' is neither a regular file nor a directory."; exit 1
    fi
}
 
action_hash() { 
    prompt_path HASHDIR "Enter the directory to hash: " dir
    if ! fs_is_rw "$HASHDIR"; then
        echo "${YELLOW}[!]${NC} Destination '$HASHDIR' is not writable or is read-only; Generate Missing Hashes is unavailable."; echo ""
        return 0
    fi
    hash_tree "$HASHDIR"
}

# Verify a tree against its ledgers: content mismatches, missing files, unlisted additions, and directories with no coverage
action_verify() {
    prompt_path VDIR "Enter the directory to verify: " dir; VDIR=${VDIR%/}
    local LOG="$PWD/._verify_$(date +%Y%m%d-%H%M%S).csv" STATE="$PWD/._verify_state" OK=0 BAD=0 NEW=0 NONE=0 D OUT ADD; local -A DONE=()
    sync; echo ""; printf 'path,status,expected,actual,mtime\n' > "$LOG"; rm -f "$STATE.err" "$STATE.dirs"
    [ -f "$STATE" ] && IFS= read -r -d '' HDR < "$STATE" || HDR=
    [ "$HDR" = "#$VDIR" ] && [ -z "$(find "$VDIR" -name '._localhash.sha256' -newer "$STATE" -print -quit)" ] && read -r -p "An interrupted verification of '$VDIR' was found. Resume it? [y/N]: " CONFIRM && [[ "$CONFIRM" =~ ^[Yy] ]] && { while IFS= read -r -d '' k; do DONE["$k"]=1; done < "$STATE"; echo "${YELLOW}[!]${NC} Resuming: $(( ${#DONE[@]} - 1 )) directories already done."; } || printf '#%s\0' "$VDIR" > "$STATE"
    echo "${YELLOW}[!]${NC} Verifying against per-folder SHA-256 ledgers..."
    find "$VDIR" -path "$VDIR/._MANIFESTS" -prune -o -type d -print0 | LC_ALL=C sort -z > "$STATE.dirs" && [ -s "$STATE.dirs" ] || { BAD=$((BAD+1)); printf '%s,TRAVERSAL ERROR,,,\n' "\"$VDIR\"" >> "$LOG"; }
    while IFS= read -r -d '' D; do
        [ -z "${DONE["$D"]-}" ] || continue
        ST=0 OUT=''; printf '%s%s  ->%s Verifying: %.*s%s' "$CR" "$GREEN" "$NC" "$((COLS-18))" "$D" "$EOL"
        if [ ! -f "$D/._localhash.sha256" ]; then
            FL=$(find "$D" -maxdepth 1 \( -type f -o -type l \) ! -name '._verify*' ! \( "${EXCLUDE_FILES[@]}" \) -print -quit) || ST=$?
            [ -z "$FL" ] || OUT="\"$D\",NO LEDGER,,,"
        else
            OUT=$(cd "$D" && { cat ._localhash.sha256; TZ=UTC find . -maxdepth 1 -type f ! -name '._verify*' ! \( "${EXCLUDE_FILES[@]}" \) -printf 'M %TY-%Tm-%TdT%TH:%TM:%TSZ %P\n' -exec sha256sum -- {} +
              find . -maxdepth 1 -type l ! -name '._verify*' -printf '%p\n' | while IFS= read -r L; do printf 'SYMLINK:%s  %s\n' "$(readlink -n -- "$L" | sha256sum | cut -d' ' -f1)" "$L"; done; } 2>"$STATE.err" | awk -v D="$D" 'function q(s){gsub(/"/,"\"\"",s);return "\"" s "\""} /^M / {i=index(substr($0,3)," ")+2; t=substr($0,3,i-3); sub(/\.[0-9]*/,"",t); T[substr($0,i+1)]=t; next} /^SYMLINK:[0-9a-fA-F]{64}  / {h=substr($0,1,72); n=substr($0,75); if (n ~ /^\.\//) {sub(/^\.\//,"",n); A[n]=h} else E[n]=h; next} {sub(/^\\/,""); h=substr($0,1,64); n=substr($0,67)} h !~ /^[0-9a-fA-F]{64}$/ || substr($0,65,2) !~ /^ [ *]$/ {bad++; next} n ~ /^\.\// {sub(/^\.\//,"",n); A[n]=h; next} {if (n in E) dup++; E[n]=h} END{if(bad||dup) printf "%s,CORRUPT LEDGER,%d malformed,%d duplicate,\n", q(D), bad+0, dup+0; for(n in E) if(!(n in A)) printf "%s,%s,%s,,\n", q(D "/" n), ((n in T)?"UNREADABLE":"MISSING"), E[n]; for(n in A) if(!(n in E)) printf "%s,UNLISTED,,%s,%s\n", q(D "/" n), A[n], T[n]; else if(A[n]!=E[n]) printf "%s,MISMATCH,%s,%s,%s\n", q(D "/" n), E[n], A[n], T[n]}' | LC_ALL=C sort) || ST=$?
            [ ! -s "$STATE.err" ] || { cat -- "$STATE.err" >&2; OUT="${OUT:+$OUT$'\n'}\"$D\",UNREADABLE,,,"; }
        fi
        [ "$ST" = 0 ] || OUT="\"$D\",ERROR,,,"
        [ -z "$OUT" ] && { OK=$((OK+1)); printf '%s\0' "$D" >> "$STATE"; } || { printf '%s\n' "$OUT" >> "$LOG"; case "$OUT" in *,MISMATCH,*|*,MISSING,*|*,ERROR,*|*,CORRUPT\ LEDGER,*|*,UNREADABLE,*) BAD=$((BAD+1)) ;; esac; case "$OUT" in *,UNLISTED,*) NEW=$((NEW+1)) ;; esac; case "$OUT" in *,NO\ LEDGER,*) NONE=$((NONE+1)) ;; esac; }
    done < "$STATE.dirs"
    ! [ -f "$LOG" ] || python3 -c 'import csv,io,os,sys,base64;p=sys.argv[1];R=list(csv.reader(io.StringIO(open(p,"rb").read().decode("utf-8","surrogateescape"))));bad=lambda s:any("\udc80"<=c<="\udcff" for c in s)
if any(bad(r[0]) for r in R if r): o=io.StringIO();w=csv.writer(o,lineterminator="\n");[w.writerow((["base64:"+base64.b64encode(r[0].encode("utf-8","surrogateescape")).decode()]+r[1:]) if bad(r[0]) else r) for r in R];open(p+".t","w",encoding="utf-8").write(o.getvalue());os.replace(p+".t",p)' "$LOG" 2>/dev/null || echo "${YELLOW}[!]${NC} python3 unavailable; non-UTF-8 paths left as raw bytes."
    rm -f "$STATE" "$STATE.dirs" "$STATE.err"; [ $((BAD+NEW+NONE)) -gt 0 ] || rm -f "$LOG"
    echo "${CR}${GREEN}[+] Verified:${NC} $OK folders clean, $BAD with failures, $NEW with unlisted files, $NONE without a ledger.$([ -f "$LOG" ] && echo "  CSV: $LOG")"
    [ $((BAD+NEW+NONE)) -eq 0 ]
}

# Destroy every ledger under a root and rebuild the baseline from current disk content
action_rehash() {
    prompt_path RHDIR "Enter the directory to Total Re-Hash (Overwrite Hashes): " dir
    if ! fs_is_rw "$RHDIR"; then
        echo "${YELLOW}[!]${NC} Destination '$RHDIR' is not writable or is read-only; Total Re-Hash (Overwrite Hashes) is unavailable."; echo ""
        return 0
    fi
    echo ""; echo "${DEEP_RED}WARNING:${NC} deletes $(find "$RHDIR" -path "$RHDIR/._MANIFESTS" -prune -o -name '._localhash.sha256' | wc -l) ledger(s) and records whatever is on disk now; any corruption present today becomes the new baseline."
    read -r -p "Proceed? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy] ]] || { echo "${DEEP_RED}[-] Error:${NC} Aborted by user."; exit 1; }
    [ -z "$(find "$RHDIR" -path "$RHDIR/._MANIFESTS" -prune -o -name '._localhash.sha256.bak' -print -quit)" ] || { echo "${DEEP_RED}[-] Error:${NC} Backups from an interrupted rebuild are present (._localhash.sha256.bak). Resolve them first."; exit 1; }
    find "$RHDIR" -path "$RHDIR/._MANIFESTS" -prune -o -name '._localhash.sha256' -execdir mv {} ._localhash.sha256.bak \; || { echo "${DEEP_RED}[-] Error:${NC} Could not set aside every ledger; the baseline would be mixed. Aborted."; exit 1; }
    hash_tree "$RHDIR" && find "$RHDIR" -name '._localhash.sha256.bak' ! -path "$RHDIR/._MANIFESTS/*" -delete || { echo "${DEEP_RED}[-] Error:${NC} Rebuild incomplete; previous ledgers kept as ._localhash.sha256.bak."; exit 1; }
}

# Desktop of the invoking user: the sudo caller when there is one, otherwise root.
desktop_dir() {
    local u="${SUDO_USER:-root}" h d x
    h=$(getent passwd "$u" | cut -d: -f6) || h=
    [ -n "$h" ] && [ -d "$h" ] || { u=root; h=$(getent passwd root | cut -d: -f6) || h=; [ -n "$h" ] || h=/root; }
    [ -d "$h" ] || return 1
    d=$(runuser -u "$u" -- env HOME="$h" xdg-user-dir DESKTOP 2>/dev/null || sed -n 's/^XDG_DESKTOP_DIR="\(.*\)"$/\1/p' "$h/.config/user-dirs.dirs" 2>/dev/null | tail -1) || d=; d=${d/\$HOME/$h}
    [ -n "$d" ] && [ "$d" != "$h" ] && [ -d "$d" ] || for x in "$h/Desktop" "$h/Documents" "$h"; do d=$x; [ -d "$d" ] && break; done; printf '%s\n' "$d"
}

# JSONL archival manifest: header record, then deterministically sorted, numbered records for files and symlinks
action_metadata() {
    prompt_path METADIR "Enter the drive location to export metadata manifest: " dir; METADIR=${METADIR%/}
    MANIROOT=$(stat -c %m -- "$METADIR") && [ -n "$MANIROOT" ] || { echo "${DEEP_RED}[-] Error:${NC} Cannot determine the drive root of '$METADIR'."; exit 1; }
    OUT=$(mktemp -d); DROP=$(desktop_dir) || DROP=; MANIFEST_DIR=${DROP:+$DROP/DISKUTILS/MANIFEST};

    # Collect once; checksum ledgers are joined directory-locally in the downstream awk stage.      
    : > "$OUT/mime.raw"; TZ=UTC find "$METADIR" -mindepth 1 -path "$MANIROOT/._MANIFESTS" -prune -o \( -type f ! \( "${EXCLUDE_FILES[@]}" \) \( -exec sh -c 'out=$1; shift; sep="$(printf "\037M\037")"; file -r -N -F "$sep" --mime-type "$@" | tr "\n" "\036" >> "$out"' sh "$OUT/mime.raw" {} + , -printf '%y\037%h\037%f\037%s\037%TY-%Tm-%TdT%TH:%TM:%TSZ\037%m\037%U\037%G\037%u\037%g\037%i\037%n\037%P\037%l\036' \) \) -o \( \( -type l -o -type d \) ! \( "${EXCLUDE_FILES[@]}" \) -printf '%y\037%h\037%f\037%s\037%TY-%Tm-%TdT%TH:%TM:%TSZ\037%m\037%U\037%G\037%u\037%g\037%i\037%n\037%P\037%l\036' \) 2>"$OUT/find.err" | awk -v R="$METADIR" -v RS='\036' -v ORS='\036' -F '\037' '{ n++; printf "\r\033[2KScanning filesystem... %d objects | Current: %s/%s", n, R, $13 > "/dev/stderr"; fflush("/dev/stderr"); print } END { printf "\r\033[2KScanning filesystem... %d objects\n", n > "/dev/stderr" }' > "$OUT/metadata.raw" || printf 'SRCFAIL\036' >> "$OUT/metadata.raw"
    awk -v RS='\036' -v FS='\037' -v FE="$(grep -c '' "$OUT/find.err" || :)" 'function esc(s,  c) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); if (s ~ /[[:cntrl:]]/) for (c=1;c<32;c++) gsub(sprintf("%c",c), sprintf("\\u%04x",c), s); return s }
        $0=="SRCFAIL" { src++; next }
        NF==3 { v=$3; sub(/^[ \t]+/,"",v); M[$1]=v; next }
        NF==14 { t=$5; q=$3; gsub(/\\/,"\\\\",q); gsub(/\n/,"\\n",q); gsub(/\r/,"\\r",q); D=$2; g=$2 "/" $3; p=esc($13); l=($1=="l"); d=($1=="d")
                if(!d && !l && D != C) { delete H; C=D; f=D "/._localhash.sha256"; if ((getline blob < f)>0) { n=split(blob,lines,"\n"); for(i=1;i<=n;i++) { e=lines[i]; sub(/^\\/,"",e); if (substr(e,1,8)=="SYMLINK:" && substr(e,9,64) ~ /^[0-9a-fA-F]{64}$/) { h=substr(e,9,64); r=substr(e,73); sub(/^[ \t]*/,"",r); H[r]=h } else if (substr(e,1,64) ~ /^[0-9a-fA-F]{64}$/) { h=substr(e,1,64); r=substr(e,65); sub(/^[[:space:]]*[*]?/,"",r); H[r]=h } } } close(f) }
                if(d) x=""; else if(l) x=",\"target\":\"" esc($14) "\""; else x=",\"mime\":" ((g in M)?"\"" esc(M[g]) "\"":"null") ",\"sha256\":" ((q in H)?"\"" H[q] "\"":"null")
                printf "%s\037{\"type\":\"%s\",\"path\":\"./%s\",%s%s\"mtime\":\"%s\",\"mode\":\"%04d\",\"uid\":%d,\"gid\":%d,\"owner\":\"%s\",\"group\":\"%s\",\"inode\":%d,\"links\":%d%s}\n", p, (d?"directory":(l?"symlink":"file")), p, "", (d?"":sprintf("\"size\":%d,",$4)), t, $6, $7, $8, esc($9), esc($10), $11, $12, x ; next }
        NF { rej++ } END { if (FE+0>src) src=FE+0; if (rej||src) printf "\001\037REJ\037%d\037%d\n", rej+0, src+0 }' < <(cat "$OUT/mime.raw" "$OUT/metadata.raw") > "$OUT/metadata.jsonl.raw"
    # extended metadata collector
    echo ""
    read -r -p "Collect extended filesystem metadata? [y/N]: " EXTENDED_META
    echo ""
    if [[ "$EXTENDED_META" =~ ^[Yy]$ ]]; then
	python3 -c 'exec('"'"'import sys,os,json,base64,unicodedata as u,fcntl,ctypes,struct,errno\nR=sys.argv[1]; O=sys.stdout.buffer\nAT_FDCWD=-100; AT_SYMLINK_NOFOLLOW=0x100; STATX_BASIC_STATS=0x7ff; STATX_BTIME=0x800; STATX_MNT_ID=0x1000; STATX_DIOALIGN=0x2000; STATX_SUBVOL=0x8000; STATX_WRITE_ATOMIC=0x10000; STATX_ATTR_ENCRYPTED=0x800000\nFS_IOC_GETFLAGS=0x80086601; FS_IOC_FSGETXATTR=0x801c581f; FS_IOC_FIEMAP=0xc020660b; FS_IOC_GET_ENCRYPTION_POLICY_EX=0xc0096616\nclass TS(ctypes.Structure): _fields_=[("tv_sec",ctypes.c_longlong),("tv_nsec",ctypes.c_uint),("reserved",ctypes.c_int)]\nclass SX(ctypes.Structure): _fields_=[("mask",ctypes.c_uint),("blksize",ctypes.c_uint),("attributes",ctypes.c_ulonglong),("nlink",ctypes.c_uint),("uid",ctypes.c_uint),("gid",ctypes.c_uint),("mode",ctypes.c_ushort),("spare0",ctypes.c_ushort),("ino",ctypes.c_ulonglong),("size",ctypes.c_ulonglong),("blocks",ctypes.c_ulonglong),("attributes_mask",ctypes.c_ulonglong),("atime",TS),("btime",TS),("ctime",TS),("mtime",TS),("rdev_major",ctypes.c_uint),("rdev_minor",ctypes.c_uint),("dev_major",ctypes.c_uint),("dev_minor",ctypes.c_uint),("mnt_id",ctypes.c_ulonglong),("dio_mem_align",ctypes.c_uint),("dio_offset_align",ctypes.c_uint),("subvol",ctypes.c_ulonglong),("atomic_write_unit_min",ctypes.c_uint),("atomic_write_unit_max",ctypes.c_uint),("atomic_write_segments_max",ctypes.c_uint),("spare3",ctypes.c_ulonglong*9)]\nlibc=ctypes.CDLL(None,use_errno=True); libc.statx.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_uint,ctypes.POINTER(SX)]; libc.statx.restype=ctypes.c_int\ndef ts(t): return {"tv_sec":t.tv_sec,"tv_nsec":t.tv_nsec}\ndef fsgetxattr(fd):\n b=bytearray(28); fcntl.ioctl(fd,FS_IOC_FSGETXATTR,b,True); x=struct.unpack("=IIIII",b[:20]); return {"xflags":x[0],"extsize":x[1],"nextents":x[2],"projid":x[3],"cowextsize":x[4]}\ndef fiemap(fd):\n count=4096; esz=56; hsz=32; b=bytearray(hsz+count*esz); struct.pack_into("=QQIIII",b,0,0,0xffffffffffffffff,0,count,0,0); fcntl.ioctl(fd,FS_IOC_FIEMAP,b,True); mapped=struct.unpack_from("=I",b,16)[0]; ext=[]\n for i in range(min(mapped,count)):\n  o=hsz+i*esz; logical,physical,length,r1,r2,flags,r3,r4,r5=struct.unpack_from("=QQQQQIIII",b,o); ext.append({"logical":logical,"physical":physical,"length":length,"flags":flags})\n truncated=bool(mapped>=count and not (ext and (ext[-1]["flags"]&1))); return {"start":0,"length":0xffffffffffffffff,"flags":0,"mapped_extents":mapped,"extent_count":count,"truncated":truncated,"extents":ext}\ndef encryption_policy(fd):\n b=bytearray(40); struct.pack_into("=Q",b,0,32); fcntl.ioctl(fd,FS_IOC_GET_ENCRYPTION_POLICY_EX,b,True); n=struct.unpack_from("=Q",b,0)[0]; version=b[8]; out={"policy_size":n,"version":version}\n if version==2 and n>=28: out.update({"contents_encryption_mode":b[9],"filenames_encryption_mode":b[10],"flags":b[11],"log2_data_unit_size":b[12],"master_key_identifier":"base64:"+base64.b64encode(bytes(b[16:32])).decode("ascii")})\n elif version==0 and n>=16: out.update({"contents_encryption_mode":b[9],"filenames_encryption_mode":b[10],"flags":b[11],"master_key_descriptor":"base64:"+base64.b64encode(bytes(b[16:24])).decode("ascii")})\n else: out["raw_policy"]="base64:"+base64.b64encode(bytes(b[8:8+min(n,32)])).decode("ascii")\n return out\ndef collect(p,t):\n errors=[]; statx=xattrs=posix_acl=capabilities=chattr=fsxattr=fiemap_data=encryption=None; capture={"statx":"capture_failed","xattrs":"capture_failed","posix_acl":"capture_failed","chattr":"capture_failed","fsxattr":"capture_failed","fiemap":"capture_failed","encryption":"unsupported"}; s=SX()\n if libc.statx(AT_FDCWD,p,AT_SYMLINK_NOFOLLOW,STATX_BASIC_STATS|STATX_BTIME|STATX_MNT_ID|STATX_DIOALIGN|STATX_SUBVOL|STATX_WRITE_ATOMIC,ctypes.byref(s))==0:\n  statx={"stx_mask":s.mask,"stx_blksize":s.blksize,"stx_attributes":s.attributes,"stx_nlink":s.nlink,"stx_uid":s.uid,"stx_gid":s.gid,"stx_mode":s.mode,"stx_ino":s.ino,"stx_size":s.size,"stx_blocks":s.blocks,"stx_attributes_mask":s.attributes_mask,"stx_atime":ts(s.atime),"stx_btime":ts(s.btime),"stx_ctime":ts(s.ctime),"stx_mtime":ts(s.mtime),"stx_rdev_major":s.rdev_major,"stx_rdev_minor":s.rdev_minor,"stx_dev_major":s.dev_major,"stx_dev_minor":s.dev_minor,"stx_mnt_id":s.mnt_id,"stx_dio_mem_align":s.dio_mem_align,"stx_dio_offset_align":s.dio_offset_align,"stx_subvol":s.subvol,"stx_atomic_write_unit_min":s.atomic_write_unit_min,"stx_atomic_write_unit_max":s.atomic_write_unit_max,"stx_atomic_write_segments_max":s.atomic_write_segments_max}\n else: errors.append("statx")\n try:\n  xattrs={}; xattr_failed=False\n  try: xattr_names=os.listxattr(p,follow_symlinks=False)\n  except AttributeError: xattrs=None; xattr_names=None; capture["xattrs"]="unavailable"; errors.append("xattrs")\n  if xattrs is not None:\n   for n in xattr_names:\n    try: xattrs[n]="base64:"+base64.b64encode(os.getxattr(p,n,follow_symlinks=False)).decode("ascii")\n    except OSError: errors.append("xattr:"+n); xattr_failed=True\n   capture["xattrs"]="capture_failed" if xattr_failed else ("captured" if xattrs else "absent")\n except OSError as e: errors.append("xattrs"); xattrs=None; capture["xattrs"]="unsupported" if e.errno in (errno.ENOTSUP,errno.EOPNOTSUPP) else "unavailable" if e.errno==errno.ENOSYS else "capture_failed"\n if xattrs is not None:\n  posix_acl={}; acl_failed=any(e.startswith("xattr:system.posix_acl_") for e in errors)\n  if "system.posix_acl_access" in xattrs: posix_acl["access"]={"xattr":"system.posix_acl_access"}\n  if "system.posix_acl_default" in xattrs: posix_acl["default"]={"xattr":"system.posix_acl_default"}\n  capture["posix_acl"]="capture_failed" if acl_failed else ("captured" if posix_acl else "absent"); posix_acl=posix_acl or None\n  if "security.capability" in xattrs: capabilities={"xattr":"security.capability"}; capture["capabilities"]="captured"\n  elif any(e=="xattr:security.capability" for e in errors): capture["capabilities"]="capture_failed"\n  else: capture["capabilities"]="absent"\n else: capture["posix_acl"]=capture["xattrs"]; capture["capabilities"]=capture["xattrs"]\n fd=-1\n if t!="symlink":\n  try:\n   fd=os.open(p,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC)\n   try: fsxattr=fsgetxattr(fd); capture["fsxattr"]="captured"\n   except OSError as e: capture["fsxattr"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("fsxattr")\n   try: b=bytearray(4); fcntl.ioctl(fd,FS_IOC_GETFLAGS,b,True); f=struct.unpack("=I",b)[0]; chattr={"flags":f,"hex":"0x%08x"%f}; capture["chattr"]="captured"\n   except OSError as e: capture["chattr"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("chattr")\n   if t=="file":\n    try: fiemap_data=fiemap(fd); capture["fiemap"]="captured"\n    except OSError as e: capture["fiemap"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("fiemap")\n   else: capture["fiemap"]="unsupported"\n   if statx is not None and statx["stx_attributes"]&STATX_ATTR_ENCRYPTED:\n    try: encryption=encryption_policy(fd); capture["encryption"]="captured"\n    except OSError as e: capture["encryption"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("encryption")\n   else: capture["encryption"]="absent"\n  except OSError: capture["fsxattr"]="capture_failed"; capture["chattr"]="capture_failed"; capture["fiemap"]="unsupported"; capture["encryption"]="capture_failed"; errors.append("open")\n  finally:\n   if fd>=0: os.close(fd)\n else: capture["chattr"]="unsupported"; capture["fsxattr"]="unsupported"; capture["fiemap"]="unsupported"; capture["encryption"]="unsupported"\n if statx is not None: capture["statx"]="captured"\n metadata={"capture":capture}; statx is not None and metadata.update({"statx":statx}); xattrs is not None and metadata.update({"xattrs":xattrs}); posix_acl is not None and metadata.update({"posix_acl":posix_acl}); capabilities is not None and metadata.update({"capabilities":capabilities}); chattr is not None and metadata.update({"chattr":chattr}); fsxattr is not None and metadata.update({"fsxattr":fsxattr}); fiemap_data is not None and metadata.update({"fiemap":fiemap_data}); encryption is not None and metadata.update({"encryption":encryption}); metadata["errors"]=errors or None; return metadata\nfor l in sys.stdin.buffer:\n if l.startswith(b"\\001\\037REJ\\037"): O.write(l); continue\n try:\n  k,j=l.rstrip(b"\\n").split(b"\\037",1); r=json.loads(u.normalize("NFC",j.decode("utf-8","surrogateescape"))); p=os.fsencode(os.path.join(R,r["path"][2:])); r["metadata"]=collect(p,r["type"]); O.write(k+b"\\037"+json.dumps(r,ensure_ascii=True,separators=(",",":"),sort_keys=False).encode()+b"\\n")\n except Exception: O.write(l)'"'"')' "$METADIR" < "$OUT/metadata.jsonl.raw"
    else
        python3 -c 'import sys,unicodedata as u; b=sys.stdin.buffer.read(); sys.stdout.buffer.write(u.normalize("NFC",b.decode("utf-8","surrogateescape")).encode("utf-8","surrogateescape"))' "$METADIR" < "$OUT/metadata.jsonl.raw"
    fi | LC_ALL=C sort -t$'\037' -k1,1 |

    awk -v R="$METADIR" -v D="$(TZ=UTC date +%Y-%m-%dT%H:%M:%SZ)" -v MV="$(file --version | head -1)" 'BEGIN{FS="\037"; gsub(/\\/,"\\\\",R); gsub(/"/,"\\\"",R); if(R ~ /[[:cntrl:]]/) for(c=1;c<32;c++) gsub(sprintf("%c",c), sprintf("\\u%04x",c), R)} $1=="\001"{REJ=$3; SRC=$4; next} {A[++n]=$2; B[n]=$3} END{printf "{\"type\":\"manifest\",\"version\":1,\"tool\":\"TransferManager\",\"root\":\"%s\",\"created\":\"%s\",\"hash\":\"sha256\",\"unicode\":\"NFC\",\"magic\":\"%s\",\"complete\":%s,\"rejected\":%d,\"collection_errors\":%d,\"records\":%d}\n", R, D, MV, (REJ+0||SRC+0?"false":"true"), REJ+0, SRC+0, n; for (i=1;i<=n;i++) printf "{\"num\":%d,%s\n", i, substr(A[i],2)}' > "$OUT/._manifest-metadata.jsonl"
    if fs_is_rw "$MANIROOT"; then
	read -r -p "Also save the metadata manifest to the source drive? [y/N]: " SAVE_DRIVE
	[[ "$SAVE_DRIVE" =~ ^[Yy]$ ]] && SAVE_DRIVE=1 || SAVE_DRIVE=0
	echo ""
    else
        SAVE_DRIVE=0
        echo "${YELLOW}[!]${NC} Destination '$MANIROOT' is not writable or is read-only; metadata manifest will not be written to the drive."
        echo ""
    fi    
    
    REL=${METADIR#"$MANIROOT"}; REL=${REL#/}; python3 -c 'import sys,json;sys.stdin.reconfigure(errors="surrogateescape");sys.stdout.reconfigure(errors="surrogateescape");R=sys.argv[1];q=lambda s:s.replace("\\","\\\\").replace("\n","\\n").replace("\r","\\r");[print(("\\" if q(p)!=p else "")+r["sha256"]+"  "+q(p)) for r in map(json.loads,sys.stdin) if r.get("type")=="file" and r.get("sha256") for p in ["./"+R+r["path"][2:]]]' "${REL:+$REL/}" < "$OUT/._manifest-metadata.jsonl" > "$OUT/._manifest-hashrecord.sha256"; CHECKSUM_HASH=$(sha256sum -- "$OUT/._manifest-hashrecord.sha256" | cut -d' ' -f1) 
    STAMP=$(TZ=UTC date +%Y%m%dT%H%M%SZ); N=$(( $(wc -l < "$OUT/._manifest-metadata.jsonl") - 1 )); printf '## Header Generated by TransferManager ## \ngenerated         : %s\nrun_stamp         : %s\nhost              : %s\nroot_directory    : %s\nmetadata_scope    : %s\nmetadata_records  : %s\nhashed_records    : %s\nsymlinks_skipped  : %s\nunhashed_records  : %s\nlast_operation    : metadata\ninvoked_by        : %s\nhistory_dir       : ._MANIFESTS\nmetadata_sha256   : %s\nhashrecord_sha256 : %s\nmetadata_header   : %s\nverify_all        : cd "%s" && sha256sum -c --quiet "%s/._manifest-hashrecord.sha256"\nverify_folder     : cd <dir> && sha256sum -c --quiet ._localhash.sha256\n' "$(date -Is)" "$STAMP" "$(hostname)" "$MANIROOT" "$METADIR" "$N" "$(wc -l < "$OUT/._manifest-hashrecord.sha256")" "$(grep -c '"type":"symlink"' "$OUT/._manifest-metadata.jsonl" || :)" "$(grep -c '"sha256":null' "$OUT/._manifest-metadata.jsonl" || :)" "${SUDO_USER:-$(id -un)}" "$(sha256sum < "$OUT/._manifest-metadata.jsonl" | cut -d' ' -f1)" "$CHECKSUM_HASH" "$(head -1 -- "$OUT/._manifest-metadata.jsonl")" "$MANIROOT" "$MANIFEST_DIR" > "$OUT/._manifest-header.meta"
    if [ "$SAVE_DRIVE" -eq 1 ]; then
        cp -f -- "$OUT/._manifest-metadata.jsonl" "$OUT/._manifest-hashrecord.sha256" "$OUT/._manifest-header.meta" "$MANIROOT/" || { echo "${YELLOW}[!]${NC} Live manifest copy under $MANIROOT failed."; SAVE_DRIVE=0; }
        mkdir -p -- "$MANIROOT/._MANIFESTS" && cp -f -- "$OUT/._manifest-metadata.jsonl" "$OUT/._manifest-hashrecord.sha256" "$OUT/._manifest-header.meta" "$MANIROOT/._MANIFESTS/" || echo "${YELLOW}[!]${NC} Historical copy under $MANIROOT/._MANIFESTS failed."
    fi
    echo ""
    [[ $(head -n 1 -- "$OUT/._manifest-metadata.jsonl") == *'"complete":true'* ]] && { COMPLETE=1; echo "${CR}${GREEN}[+] Success!${NC} Wrote $N records."; } || { COMPLETE=0; echo "${CR}${DEEP_RED}[!] Incomplete!${NC} Wrote $N records, but the manifest header says \"complete\":false."; head -n 20 -- "$OUT/find.err" >&2; }
    if [ -n "$DROP" ]; then mkdir -p -- "$MANIFEST_DIR" && cp -f -- "$OUT/._manifest-metadata.jsonl" "$OUT/._manifest-hashrecord.sha256" "$OUT/._manifest-header.meta" "$MANIFEST_DIR/" && { chown -R -- "${SUDO_UID:-0}:${SUDO_GID:-0}" "$DROP/DISKUTILS" 2>/dev/null || :; echo "${GREEN}[+]${NC} Desktop copy: $MANIFEST_DIR"; rm -rf -- "$OUT"; } || echo "${YELLOW}[!]${NC} No Desktop copy written (copy failed); files are in $OUT."; elif [ "$SAVE_DRIVE" -eq 1 ]; then echo ""; echo "${GREEN}[+]${NC} Manifest saved to $MANIROOT."; rm -rf -- "$OUT"; else echo "${YELLOW}[!]${NC} No persistent manifest destination available; files are in $OUT."; fi
    echo ""
    [ "$COMPLETE" -eq 1 ]
}

display_banner
printf '%s\n' "1) Copy Files and Hash" "2) Generate Missing Hashes" "3) Total Re-Hash (Overwrite Hashes)" "4) Export Metadata" "5) Verify Integrity" "6) Exit"
while :; do
    echo ""
    read -r -p "Select an option [1-6]: " REPLY
    case "$REPLY" in 
        1|2|3|4|5|6) MENU_CHOICE=$((REPLY-1)); break ;;
        *) echo "${DEEP_RED}[-] Error:${NC} Enter a number from 1 to 6." ;;
    esac
done
case "${MENU_CHOICE-5}" in
    0) action_copy ;;
    1) action_hash ;;
    2) action_rehash ;;
    3) action_metadata ;;
    4) action_verify ;;
    5) if [ -t 1 ]; then clear 2>/dev/null || true; fi; echo "Operation canceled."; echo ""; exit 0 ;;
esac

