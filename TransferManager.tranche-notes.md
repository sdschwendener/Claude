## ==========================================================================================================
## TRANSFERMANAGER.SH - REVIEW NOTATION, TRANCHES 1-7 (ORIGINAL, UNPATCHED SCRIPT)
## ==========================================================================================================
## This is the original, unpatched TransferManager.sh with the Tranche 1-7 review documentation added as
## comments, as notation for future patching. No fix from any tranche is applied: every line that does not
## begin with "##" is byte-for-byte the original script, in the original order, so it runs exactly as before.
##
##   Strip the notation (restores the original exactly):  sed '/^[[:space:]]*##/d' TransferManager.tranche-notes.sh > TransferManager.sh
##   List the inline notes for one item:                  grep -n '\[T1\.6\]' TransferManager.tranche-notes.sh
##
## Inline notes sit directly above the code they concern and are tagged [T<tranche>.<item>]. The full text of
## every item follows below.
##
## Evidence tags: Reproduced = run against the real script through its menu. Stub = rsync was not installed in
## the review sandbox, so a stand-in that fails was used. By reading = evident from the code alone.
## Review environment: bash 5.2.21, mawk 1.3.4-20240123, coreutils 9.4, findutils 4.9.0, Python 3.12.3,
## file 5.45, ext4, run as root. Repros that needed root that can't read everything (NFS root_squash, FUSE, a
## failing disk) dropped CAP_DAC_OVERRIDE/CAP_DAC_READ_SEARCH with setpriv.
##
## Most defects come from three root causes:
##   - Tree roots are never validated.
##   - Exit statuses get thrown away, so "did nothing" reads as "succeeded".
##   - Four separate parsers read the same ledger line, and they disagree.
## The tranches are ordered so the fixes that stop the tool from reporting false success come first. The shared
## ledger parser (Tranche 2) comes before the metadata and copy fixes that depend on it.
##
## ----------------------------------------------------------------------------------------------------------
## THE SECOND OPINION, CHECKED
## ----------------------------------------------------------------------------------------------------------
##   #1  Confirmed, understated. A regular file or dangling symlink as the root also "passes", even on a tree
##       with no ledgers at all. -> T1.1
##   #2  Confirmed, understated. Export Metadata does it too: "Success! Wrote 0 records". -> T1.1
##   #3  Confirmed. The ledger itself is fine; the script's "CORRUPT LEDGER" label is wrong. -> T2.4
##   #4  Confirmed exactly. Also sends the extended collector to the wrong path for NFD names. -> T3.1
##   #5  Confirmed, understated. Also locks up Total Re-Hash and makes directory copy delete destination
##       ledgers. -> T1.3
##   #6  Confirmed, understated. Related case: a symlink at the target is written through, as root, outside
##       DEST, and reported as Success. -> T1.6
##   #7  Confirmed. Fixing it exposes two more decoder bugs; FIEMAP is broken too. -> Tranche 4
##   #8  Partly contradicted. No nonzero exit with any variant tried (either byte, both in one name, crafted
##       fragments). The real outcome is worse: records silently dropped, "Success!", exit 0. -> T3.2
##   #9  Confirmed. Also shows up in 1.8's repro. -> T6.2
##
## ----------------------------------------------------------------------------------------------------------
## TRANCHE 1 - FALSE SUCCESS, DESTRUCTIVE WRITES, AND ONE BLOCKER
## ----------------------------------------------------------------------------------------------------------
## [T1.1] Roots that aren't real directories do nothing and report success. (Reproduced)
##   This affects Verify, Generate Missing Hashes, Total Re-Hash and Export Metadata.
##   - `prompt_path` accepts symlinks, regular files, and dangling links (`-L`).
##   - `find` doesn't descend into a symlink start point, and metadata's global `-mindepth 1` drops it as well.
##   - Verify on a symlink to an unhashed tree prints "0 clean, 0 failures, 0 unlisted, 0 without a ledger",
##     exit 0. The real path gives "2 without a ledger", exit 1.
##   - Re-Hash via a symlink says Success and leaves the ledger stale.
##   Fix: resolve the path once with `realpath -e`, require `[ -d ]`, and fail any run that visited zero
##   directories.
##
## [T1.2] Metadata export calls incomplete manifests complete, and calls `complete:false` "Success". (Reproduced)
##   - `find`'s errors go to `/dev/null`.
##   - The `|| printf 'SRCFAIL\036'` marker is printed to the terminal instead of into the stream; it appeared on
##     screen literally.
##   - An unreadable subtree was silently left out, and the header said `"complete":true,"collection_errors":0`.
##   - Separately, whenever the header does say `complete:false`, the terminal still prints "Success! Wrote N
##     records" and the script exits 0.
##   Fix:
##   - Use `{ find … 2>"$OUT/find.err" || printf 'SRCFAIL\036'; } | awk …`.
##   - Count `find.err` into `collection_errors`.
##   - Read the header back and exit nonzero when it's incomplete.
##
## [T1.3] The hash error log causes false failures and false successes. (Reproduced)
##   - A stale log fails every later run (#5).
##   - A failed Total Re-Hash leaves both new ledgers and `.bak` files, so every retry is refused ("Backups from an
##     interrupted rebuild…") until someone deletes the log by hand.
##   - In directory copy, that false failure triggers `rm -f "$CUR_DST/._localhash.sha256"`, which deletes the
##     source ledger rsync just copied.
##   - The opposite case: if the Desktop drop can't be created and `$PWD` isn't writable, every `2>> "$FAILLOG"`
##     redirect fails. That means `find` never runs and nothing gets hashed, yet it prints "Success!" with exit 0
##     and zero ledgers. Both conditions are realistic together: an NFS home with root_squash, plus running from
##     read-only source media.
##   Fix:
##   - Use a per-run log from `mktemp` in a root-owned location, and check that it's writable up front.
##   - Copy it to the Desktop only at the end.
##   - Never delete the destination ledger.
##
## [T1.4] Verify ignores read failures. (Reproduced)
##   The exit status of `find … -exec sha256sum` is lost because it isn't the last command in the `{ …; }` group.
##   - An unreadable file that isn't in the ledger simply disappears: "3 folders clean", exit 0.
##   - An unreadable file that is in the ledger is mislabeled MISSING.
##   Fix: capture each directory's status and stderr, and report an UNREADABLE row that counts as a failure.
##
## [T1.5] Verify silently resumes stale state. (Reproduced)
##   After an interrupted run (Ctrl-C), `./._verify_state` never expires.
##   - A file was corrupted and re-verified; the directory was skipped as "already done", and the run exited 0.
##   - A fresh run caught it and exited 1.
##   Fix: ask whether to resume, and discard the state if any ledger is newer than it.
##
## [T1.6] Single-file copy doesn't check what's already at the target. (Reproduced)
##   - Target is a directory (#6): `cp` nests the file inside it, then `cmp` fails and leaves the debris.
##   - Target is a symlink: `cp -a` writes through it as root, replacing an outside file's content ("precious"
##     became "payload"). It reports Success, exit 0, and records a `SYMLINK:` hash of the link text.
##   - Target is an existing device node: the node gets `DTYPE=f`, and `cp -a` writes into it and applies the
##     source's mode. With a mknod'd copy of `/dev/null`, the mode went from 0666 to 0600. A mistyped `/dev/sdX`
##     would be overwritten from byte 0.
##   - Target is a regular file: it's overwritten with no prompt.
##   Fix: allow only a nonexistent target, or a regular file after a prompt. Then use
##   `cp -a -T --remove-destination`.
##
## [T1.7] A symlink-to-directory SOURCE copies only the link. (Reproduced)
##   `~/Photos -> realdata` took the file branch. The destination got a dangling symlink and zero data, and the
##   script printed "Success!" with exit 0.
##   Fix: if the source is both `-L` and `-d`, ask whether to copy the link or the directory it points to,
##   defaulting to the directory.
##
## [T1.8] `fs_is_rw` treats `errors=remount-ro` as read-only. (Reproduced with a findmnt shim)
##   - `grep -qw ro` matches the "ro" in `errors=remount-ro`, which is the default on Debian/Ubuntu ext4 roots and
##     udisks2 automounts.
##   - As a result, copy, hashing, re-hash and saving the manifest to the drive are all refused on writable disks.
##   - Hashing also exits 0 while refusing.
##   Fix: match `(^|,)ro(,|$)` against `findmnt -no VFS-OPTIONS`, or rely on `[ -w ]` alone, which already fails on
##   read-only mounts.
##
## ----------------------------------------------------------------------------------------------------------
## TRANCHE 2 - ONE LEDGER FORMAT, ONE PARSER, ONE ESCAPER
## ----------------------------------------------------------------------------------------------------------
## The same line is parsed four ways: the bash regex, `ledger_drop`, the verify awk, and the metadata awk. Only
## verify's fixed-offset parser is correct. Define the format once: optional `\`, 64 hex characters, exactly
## `␠␠` or `␠*`, then the escaped name. Escape `\`, newline and CR identically everywhere, including on
## `SYMLINK:` lines. To stop depending on how your coreutils version escapes names, hash via stdin
## (`sha256sum < "$f"`) and write the name yourself.
##
## [T2.1] Names with leading spaces or CR get a duplicate ledger line on every run. (Reproduced)
##   - The greedy `[[:space:]]*` eats leading spaces.
##   - `E_NAME` doesn't escape CR, but coreutils 9.4 does.
##   - So each Generate Missing Hashes run re-hashes those files and appends another line: 3, then 5, then 7
##     lines. Verify then fails with "CORRUPT LEDGER, 4 duplicate".
##   - Names that collide once the spaces are stripped (" foo" vs "foo") can also make a new file look already
##     hashed.
##
## [T2.2] Names starting with `*`. (Reproduced)
##   `ledger_drop` and the metadata parser strip the `*`.
##   - Re-copying `*x` leaves a duplicate line, so Verify reports CORRUPT LEDGER.
##   - Export records `"sha256":null` for it.
##
## [T2.3] Symlink names are escaped when hashing but not when verifying. (Reproduced)
##   A systemd-style link named `dev-disk-by\x2duuid-….swap` is reported both MISSING and UNLISTED; newline names
##   break into garbage. `action_copy` writes symlink lines unescaped, which is a third variant.
##
## [T2.4] #3: the verifier's own mtime records aren't newline-safe. (Confirmed)
##   - The ledger for `c\nd` is correct. The unescaped `M <mtime> %P` lines the verifier generates are what split.
##   - Fix: build that stream NUL-delimited, and report the verifier's own parse errors as ERROR, not
##     CORRUPT LEDGER.
##   - The mtime column is also empty for any escaped name.
##
## [T2.5] Smaller format issues. (By reading)
##   - A ledger without a trailing newline merges into the first `M` line.
##   - Uppercase hex passes validation but compares unequal.
##   - The advertised `verify_folder` command (`sha256sum -c`) warns "improperly formatted" on any ledger that
##     contains `SYMLINK:` lines.
##
## ----------------------------------------------------------------------------------------------------------
## TRANCHE 3 - METADATA MANIFEST CORRECTNESS
## ----------------------------------------------------------------------------------------------------------
## [T3.1] NFC normalization (#4). (Reproduced)
##   Remove it; paths must stay byte-exact. If you want a normalized form, add it as a separate field. Two related
##   problems:
##   - The extended collector stats the normalized path. It finds nothing for NFD-named files, or the wrong file
##     when both forms exist.
##   - Sort order differs between extended and normal mode.
##
## [T3.2] Separator bytes and newlines in names (#8). (Reproduced)
##   Every case below prints Success with exit 0.
##   - `\036` in a name: the record is dropped. Also, an unrelated file in the same directory loses its sha256,
##     because the ledger is read with `getline` while `RS=\036`, so the stray byte cuts the ledger short.
##   - `\037` in a name: the record is dropped.
##   - Newline in a name (not mentioned in the second opinion): the record is kept but mime is null, because
##     `tr '\n' '\036'` on file(1)'s raw output splits it.
##   Fix: generate the raw records in Python using `os.scandir`/`lstat` and the shared Tranche 2 parser.
##
## [T3.3] Hashrecord paths are wrong for relative or symlinked METADIR. (Reproduced)
##   `REL` is computed by stripping `stat -c %m` off METADIR as a string.
##   - A relative METADIR gives `./fxs/plain.txt`, resolved from `/`.
##   - A path through `~/drive -> /dev/shm` gives `./home/claude/t/drive/data/f.txt`, resolved from `/dev/shm`.
##   - In both cases the header's own `verify_all` command fails.
##   Fix: `realpath -e` first (the same fix as 1.1).
##
## [T3.4] Stale hashes are copied into the manifest. (Reproduced)
##   After a file was edited, the manifest recorded the old hash with `complete:true`, and `verify_all` failed
##   right after export. Fix: when a file is newer than its ledger, emit null (or rehash).
##
## [T3.5] The history folder isn't history. (By reading)
##   - `._MANIFESTS/` and the drive-root copies use fixed filenames, so each export overwrites the previous
##     baseline. `STAMP` is computed but never used.
##   - Exporting subdirectory B also overwrites subdirectory A's drive-root manifest.
##
## [T3.6] JSON validity. (By reading)
##   - In non-extended mode, invalid-UTF-8 names are written raw, which is not valid JSON.
##   - `awk -v R=` interprets backslashes in the root path.
##
## ----------------------------------------------------------------------------------------------------------
## TRANCHE 4 - EXTENDED-METADATA COLLECTOR
## ----------------------------------------------------------------------------------------------------------
## [T4.1] FIEMAP never returns extents. (Reproduced)
##   - The call packs `count` into `fm_mapped_extents` and 0 into `fm_extent_count`.
##   - It then reads the result from offset 16 (`fm_flags`) instead of 20.
##   - Every file shows `mapped_extents: 0`, `extents: []`, and `"captured"`. A corrected call shows 1 extent for
##     a 3 MB test file.
##
## [T4.2] #7 plus the decoder behind it. (Confirmed: 0x800 in `linux/stat.h`)
##   Once the constant is fixed, two more bugs surface:
##   - The size checks are wrong: a v1 policy is 12 bytes and v2 is 24, but the code requires ≥16 and ≥28, so both
##     fall through to `raw_policy`.
##   - The v1 descriptor is at `b[12:20]`, not `b[16:24]`.
##   Locked regular files fail `open()` with ENOKEY, so record that case explicitly.
##
## [T4.3] Collector failures are silent. (By reading)
##   `except Exception: O.write(l)` drops a record's extended data without flagging it. Count these into
##   `collection_errors`.
##
## ----------------------------------------------------------------------------------------------------------
## TRANCHE 5 - COPY FIDELITY AND VERIFICATION STRENGTH
## ----------------------------------------------------------------------------------------------------------
## [T5.1] rsync errors are discarded. (Stub)
##   stderr goes to `$COPY_TMP/errors`, which is deleted on failure. The only output is "Directory detected…"
##   followed by exit 1 with no explanation. Fix: print the error file first, and add a cleanup trap.
##
## [T5.2] Directory copy is less faithful than `cp -a`. (By reading)
##   - `-ah` means human-readable, not hard links.
##   - It drops ACLs and xattrs, expands sparse files, and splits hard links.
##   - Because every directory is a separate rsync invocation, `-H` couldn't preserve cross-directory hard links
##     anyway.
##   Fix: transfer in one pass with `-aHAXS`, then hash.
##
## [T5.3] Directory mtimes aren't preserved. (By reading)
##   Ledgers are written after each batch, and child directories are created in later batches. Fix: after hashing,
##   run a final directory-only pass to restore directory times.
##
## [T5.4] Verification can be circular or served from RAM. (By reading)
##   - Destination ledgers are computed from the destination unless the source was hashed first.
##   - The single-file path ignores the source ledger entirely.
##   - `sync` doesn't evict the page cache, so Verify and `cmp` right after a copy mostly read RAM, not the disk.
##   Fix:
##   - Warn when the source wasn't hashed.
##   - Drop the cache before verifying: `dd if="$f" iflag=nocache count=0`, or use `drop_caches`.
##
## [T5.5] FOR DOCUMENTATION ONLY; IGNORE AND DO NOT IMPLEMENT T5-5 - Change detection must not overwrite hashes intentionally carried by a copy. (By reading)
##   - THIS FIX IS DEFERRED AND SHOULD NOT BE IMPLEMENTED ALONG SIDE OTHER T-5 RELIANT FIXES ACCORDINGLY
##   - Replacements whose older mtime was preserved (rsync -a, cp -p, tar) are never re-hashed, and exFAT's 2-second
##     timestamp granularity can cause files to be skipped.
##   - Using ctime plus size directly fixes those cases for an existing local ledger, but creates a new failure in the
##     copy workflow: after a file is copied, its destination ctime is newer than the source ledger's timestamp.
##     Generate Missing Hashes would therefore treat every copied file as changed and replace the source hash with a
##     hash calculated from the destination copy.
##   - That defeats the purpose of carrying the source hash to the destination: the destination would no longer retain
##     an independent, end-to-end-verifiable source hash.
##   - Therefore, ctime+size must only be used as change detection against a ledger baseline established for that
##     filesystem object. A ledger entry carried forward by Copy must not be re-hashed merely because the destination
##     file's ctime is newer than the carried ledger.
##   - After a successful copy, the destination ledger must be treated as the baseline for the copied files (or otherwise
##     explicitly marked as carried-forward source hashes). The copy operation must not cause Generate Missing Hashes to
##     replace those hashes on its next run.
##   - A subsequent local change to a destination file must still invalidate that baseline and cause the file to be
##     re-hashed.
##   - Deleted files should be pruned from ledgers.
##   Fix: replace mtime-only detection with a baseline-aware ctime+size mechanism. Preserve carried source hashes across
##   Copy, establish a new destination baseline for them after the copy, and re-hash only when the file subsequently
##   changes relative to that baseline. Add a prune option for deleted files.
##   NOTE: T5.5 is documentation only in this tranche-notes file and is explicitly deferred; do not implement it as
##   part of the T5-dependent fixes.
##
## ----------------------------------------------------------------------------------------------------------
## TRANCHE 6 - HARDENING, EXIT CODES, ROBUSTNESS
## ----------------------------------------------------------------------------------------------------------
## [T6.1] Root follows symlinks in the user's Desktop. (By reading; this is a security issue)
##   As root, the script appends to `~/Desktop/DISKUTILS/._hash_errors.log` and `cp -f`s manifest files into that
##   folder.
##   - Anything running as that user can plant symlinks there and redirect root's writes onto existing root-owned
##     files.
##   - The written content can be partly controlled through filenames.
##   Fix: perform these writes as `$SUDO_USER`, for example by streaming the data through
##   `runuser -u "$SUDO_USER" -- tee`.
##
## [T6.2] #9. Return 1 when refusing a read-only target.
##
## [T6.3] The Total Re-Hash guard can never fire. (By reading; confirmed `find -execdir false \;` exits 0)
##   The `\;` form throws away `mv`'s exit status. Fix: afterwards, check that no `._localhash.sha256` files remain.
##   Two smaller issues:
##   - The warning's ledger count includes the pruned `._MANIFESTS` directory, because there's no `-print`.
##   - `-path "$ROOT/._MANIFESTS"` fails for roots with a trailing slash or glob characters.
##
## [T6.4] Verify exclusions and CSV. (Exclusion mismatch reproduced; the rest by reading)
##   - Verify ignores `._verify*` files but hashing doesn't. A user file with that name, or a CSV that Verify left
##     inside the tree, is reported MISSING forever. Both sides need the same exclusion list, and CSV/state files
##     should be written outside the tree.
##   - The NO LEDGER, ERROR and TRAVERSAL rows don't escape quotes.
##   - `-v D=` interprets backslashes in directory names.
##   - The Python post-processor reports "python3 unavailable" whenever it hits any exception.
##
## [T6.5] Miscellaneous. (By reading)
##   - There's no cleanup trap, so temp directories leak.
##   - `HM=$(getent … | cut …)` aborts the script under `set -e` if SUDO_USER can't be resolved.
##   - Progress escape codes are written to non-TTY stderr.
##   - "Incomplete!" can report 0/0/0, because it only counts three prefixes.
##   - One unreadable source directory aborts the whole directory copy up front.
##
## ----------------------------------------------------------------------------------------------------------
## TRANCHE 7 - PORTABILITY, PERFORMANCE, POLISH
## ----------------------------------------------------------------------------------------------------------
## [T7.1] Portability. (By reading)
##   - Add a preflight check for python3, rsync ≥3.1, stdbuf, file and findmnt.
##   - The `{64}` and `[[:cntrl:]]` regexes need a recent mawk or gawk; on older mawk every ledger line would fail
##     to parse.
##   - The ioctl numbers assume a 64-bit system.
##   - statx through ctypes needs glibc ≥2.28.
##
## [T7.2] Performance. (By reading)
##   - `desktop_dir` (getent plus runuser) runs once per directory during copy.
##   - There's one rsync invocation per directory.
##   - Ledgers are re-read whenever `find` returns to a directory.
##
## [T7.3] Polish. (By reading)
##   - Raw filenames are printed to the terminal, so escape sequences in names can mess up the display.
##   - `verify_all` should quote paths with `%q`. With no Desktop available it becomes
##     `/._manifest-hashrecord.sha256`.
##   - Devices, FIFOs and sockets are copied but never hashed or included in the manifest.
##   - Directory copy prints "Success!" once per directory.
## ==========================================================================================================
## END OF NOTATION HEADER - the original script continues below
## ==========================================================================================================
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
## [T7.1] No dependency preflight: python3, rsync >= 3.1 (--info=progress2), stdbuf, file and findmnt are assumed.
## [T6.4] Hashing excludes only these names; Verify also excludes '._verify*' (mismatch -> MISSING forever).
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

# Interactive input: $1 = variable name, $2 = prompt, $3 = set if the final component may not exist yet
## [T1.1] Accepts symlinks, regular files and dangling links (-L) as tree roots; find then does nothing and the
##        action reports success. Fix: realpath -e once and require [ -d ] for the four tree actions.
## [T6.5] HM=$(getent ... | cut ...) below aborts the script under set -e if SUDO_USER can't be resolved.
prompt_path() {
    local val="${!1-}"
    while :; do
        read -r -e -i "$val" -p "$2" val
        case $val in "~"|"~/"*) HM=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6); [ -z "$HM" ] || val="$HM${val#\~}" ;; -*) val=./$val ;; esac
        [ -n "$val" ] && { [ -e "$val" ] || [ -L "$val" ] || { [ -n "${3-}" ] && [ -d "$(dirname "$val")" ]; }; } && break
        echo "${DEEP_RED}[-] Error:${NC} '$val' does not exist${3:+ (only the final folder may be new)}."
    done
    printf -v "$1" '%s' "$val"
}

# Prints $1 with $2's entry removed. Callers compose the replacement and rename it into place.
## [T2.1][T2.2] Ledger parser 2 of 4: greedy [[:space:]]* eats leading spaces and \*? strips a leading '*' from
##        names; the escaping below skips CR (coreutils 9.4 escapes it). Split exactly at <64 hex><space><space|*>.
## [T7.1] The {64} interval needs a recent mawk or gawk.
ledger_drop() {
    [ -f "$1" ] || return 0
    local t=$2; t=${t//\\/\\\\}; t=${t//$'\n'/\\n}
    LD_T="$t" awk 'BEGIN{t=ENVIRON["LD_T"]} { line=$0; sub(/^\\/,"",line); sub(/^(SYMLINK:)?[a-fA-F0-9]{64}[[:space:]]*\*?/,"",line); if (line != t) print }' "$1"
}

# Returns 0 if the FS is writable, 1 if read only or not writable
fs_is_rw() {
    local P="$1"
    while [ ! -e "$P" ] && [ ! -L "$P" ] && [ "$P" != "/" ]; do P=$(dirname -- "$P"); done
    ## [T1.8] grep -qw ro also matches the ro in errors=remount-ro (Debian/Ubuntu ext4 roots, udisks2 automounts):
    ##        writable disks are refused. Fix: exact (^|,)ro(,|$) against findmnt -no VFS-OPTIONS, or [ -w ] alone.
    findmnt -no OPTIONS -T "$P" | grep -qw ro && return 1
    [ -w "$P" ] || return 1
    return 0
}

## [T2.1] Ledger parser 1 of 4 (two parse blocks below). [T2.3] SYMLINK: lines are written here with escaped names.
## [T5.5] DEFERRED / DOCUMENTATION ONLY: current implementation remains mtime-only (-nt); do not implement T5.5 here.
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
	        ## [T2.1] Parse block 1 of 2: the two regexes below split on a greedy [[:space:]]*, which eats a name's leading spaces.
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
	    ## [T2.1] E_NAME escapes \ and newline but not CR (coreutils 9.4 does): the key never matches, one duplicate per run.
	    F_NAME=${FILE#./}; E_NAME=${F_NAME//\\/\\\\}; E_NAME=${E_NAME//$'\n'/\\n}
	    ALREADY_LOGGED=0
	    ## [T5.5] DEFERRED / DOCUMENTATION ONLY: current implementation remains mtime-only; do not implement T5.5 here.
	    if [ -f "$CHECKSUM_FILE" ] && [ ! -L "$FILE" ] && [ ! "$FILE" -nt "$CHECKSUM_FILE" ] && [[ -n "${LEDGER[$E_NAME]+x}" ]]; then
	        ALREADY_LOGGED=1
	    fi
	    if [ "$ALREADY_LOGGED" -eq 1 ]; then
	        continue
	    fi
	    printf '%s%s  ->%s Hashing: %.*s%s' "$CR" "$GREEN" "$NC" "$((COLS-15))" "${SUBDIR##*/}/$F_NAME" "$EOL"
	    if [ -L "$F_NAME" ]; then
	        ## [T2.3] Escaped name, no '\' marker; Verify compares raw find -printf names and action_copy writes raw names.
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
		    ## [T2.1] Parse block 2 of 2 (same greedy regexes).
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
## [T1.3] One persistent FAILLOG shared by every run: a stale line fails all later runs (and blocks Total Re-Hash);
##        if it's unwritable, every 2>> redirect fails, find never runs, nothing is hashed, and it still prints
##        Success. Fix: per-run mktemp log checked up front, copied to the Desktop only at the end.
## [T1.1] Zero directories processed counts as success.  [T6.1] Root appends inside the user-writable Desktop.
## [T7.2] desktop_dir (getent + runuser) runs on every call, i.e. once per directory during a copy.
## [T6.5] "Incomplete!" counts only three prefixes (can report 0/0/0).  [T7.3] Copy prints Success once per folder.
hash_tree() {
    local SUBDIR DROP FAILLOG; DROP=$(desktop_dir) || DROP=; [ -n "$DROP" ] && mkdir -p -- "$DROP/DISKUTILS" 2>/dev/null && [ -w "$DROP/DISKUTILS" ] || DROP=; FAILLOG="${DROP:+$DROP/DISKUTILS/}._hash_errors.log"; case $FAILLOG in /*) ;; *) FAILLOG="$PWD/$FAILLOG" ;; esac
    echo ""
    [ -z "${2:-}" ] && { echo ""; echo "${YELLOW}[!]${NC} Generating and updating per-folder SHA-256 hash files..."; }
    while IFS= read -r -d '' SUBDIR; do 
	process_hash_directory "$SUBDIR" "$FAILLOG"
    #done < <(find "$1" -path "$1/._MANIFESTS" -prune -o -type d -print0 2>> "$FAILLOG" || echo "TRAVERSAL-FAILED $1" >> "$FAILLOG")
    done < <(if [ -n "${2:-}" ]; then printf '%s\0' "$2"; else find "$1" -path "$1/._MANIFESTS" -prune -o -type d -print0 2>> "$FAILLOG" || echo "TRAVERSAL-FAILED $1" >> "$FAILLOG"; fi)
    [ -s "$FAILLOG" ] && { echo "${CR}${DEEP_RED}[!] Incomplete!${NC} $(grep -c '^UNREADABLE' "$FAILLOG" || :) unreadable, $(grep -c '^FAILED' "$FAILLOG" || :) failed, $(grep -c '^TRAVERSAL-FAILED' "$FAILLOG" || :) traversal errors. See $FAILLOG."; return 1; } || { [ -z "${2:-}" ] && echo ""; echo "${CR}${GREEN}[+] Success!${NC} All directory hashes updated and sorted."; rm -f "$FAILLOG"; }
}

## [T1.6][T1.7] single-file path; [T2.3] unescaped symlink ledger line; [T5.1]-[T5.4] directory path and verification;
## [T6.5] no cleanup trap, and one unreadable source directory aborts the whole copy; [T7.2] one rsync per folder.
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

    # FILE COPY LOGIC #########################################################################################
    ## [T1.7] A symlink to a directory takes this branch: only the link is copied (dangling at the destination),
    ##        reported as Success. Fix: if -L and -d, ask whether to copy the link or the directory (default).
    if [ -L "$SOURCE" ] || [ -f "$SOURCE" ]; then
        echo "${YELLOW}[!]${NC} File or symlink detected. Using cp -a..."
        
        # Determine target directory and file paths safely
        ## [T1.6] Nothing checks what already sits at the target: a directory gets the file nested inside it (#6); a symlink
        ##        is written through as root; a device node is written into and chmod'ed; a regular file is overwritten.
        DTYPE=d; [ -d "$DEST" ] || { [ -e "$DEST" ] && DTYPE=f || { read -r -p "'$DEST' does not exist. Create as (f)ile or (d)irectory? [f/D]: " DTYPE; case $DTYPE in [Ff]) DTYPE=f ;; [Dd]|"") DTYPE=d ;; *) echo "${DEEP_RED}[-] Error:${NC} Answer f or d."; exit 1 ;; esac; }; }
        if [ "$DTYPE" = d ]; then
            TARGET_DIR="$DEST"
            TARGET_FILE="$DEST/$(basename "$SOURCE")"
        else
            TARGET_DIR=$(dirname "$DEST")
            TARGET_FILE="$DEST"
        fi
        mkdir -p -- "$TARGET_DIR" || { echo "${DEEP_RED}[-] Error:${NC} Failed to create destination directory."; exit 1; }
        ## [T1.6] Fix: allow only a nonexistent target or a regular file after a prompt, then cp -a -T --remove-destination.
        cp -a -- "$SOURCE" "$TARGET_FILE" || { echo "${DEEP_RED}[-] Error:${NC} File copy failed."; exit 1; }
        ## [T5.4] cmp right after cp reads the page cache, not the disk; the source's own ledger entry is never consulted.
        [ -L "$SOURCE" ] || cmp -s -- "$SOURCE" "$TARGET_FILE" || { echo "${DEEP_RED}[-] Error:${NC} Copy verification failed."; exit 1; }
        F_NAME=$(basename "$TARGET_FILE")
        
        # Isolate directory navigation in a subshell for safety, append new hash and sort deterministically
        (
            cd "$TARGET_DIR" || exit 1
            CHECKSUM_FILE="._localhash.sha256"
            echo "${GREEN}  ->${NC} Hashing file: $F_NAME"
            ## [T2.3] Symlink line uses the raw, unescaped name (third escaping variant); regular files rely on sha256sum's escaping.
            NEW_HASH_LINE=$([ -L "$F_NAME" ] && printf 'SYMLINK:%s  %s' "$(readlink -n -- "$F_NAME" | sha256sum | cut -d' ' -f1)" "$F_NAME" || sha256sum -- "$F_NAME")
            { ledger_drop "$CHECKSUM_FILE" "$F_NAME"; printf '%s\n' "$NEW_HASH_LINE"; } > "$CHECKSUM_FILE.tmp" && mv -- "$CHECKSUM_FILE.tmp" "$CHECKSUM_FILE"
            LC_ALL=C sort -k 2 "$CHECKSUM_FILE" > "$CHECKSUM_FILE.tmp" && mv -- "$CHECKSUM_FILE.tmp" "$CHECKSUM_FILE"
            echo ""
            echo "${GREEN}[+] Success!${NC} File copied and checksum updated."
        )

    # DIRECTORY COPY LOGIC ####################################################################################
    ## [T5.2] One rsync -ah per directory: -h is human-readable, not hard links; ACLs, xattrs and sparseness are dropped,
    ##        and per-directory invocations can never keep cross-directory hard links. Fix: one pass with -aHAXS, then hash.
    ## [T5.3] Ledgers are written after each batch and child directories are created later: directory mtimes are lost.
    ## [T5.4] Destination ledgers come from the destination itself unless the source was hashed first: warn.
    elif [ -d "$SOURCE" ]; then
        echo ""; echo "";
        echo "${YELLOW}[!]${NC} Directory detected. Using ordered, directory-wise rsync -ah."
        case "$(realpath -m -- "$DEST")/" in "$(realpath -- "$SOURCE")"/*) echo "${DEEP_RED}[-] Error:${NC} Destination is the source or lies inside it."; exit 1 ;; esac
        ## [T5.1] rsync stderr goes to $COPY_TMP/errors, which is deleted on failure: exit 1 with no message.  [T6.5] No trap.
        COPY_TMP=$(mktemp -d) || { echo "${DEEP_RED}[-] Error:${NC} Failed to create temporary copy workspace."; exit 1; }
        COPY_LIST="$COPY_TMP/tree.list"; COPY_FILES="$COPY_TMP/files"; printf '.\0' > "$COPY_TMP/root.files"
        ## [T6.5] One unreadable directory raises inside this traversal and aborts the whole copy before anything is copied.
        if ! python3 -c 'import os,sys; R=sys.argv[1].encode(); O=open(sys.argv[2],"wb"); exec("def f(r):\n ds=[]; fs=[]\n for x in os.scandir(r): (ds if x.is_dir(follow_symlinks=False) else fs).append(x.name)\n for x in sorted(fs): O.write(os.path.join(r,x)+bytes([0]))\n for x in sorted(ds): O.write(os.path.join(r,x)+bytes([0])); f(os.path.join(r,x))\nf(R)")' "${SOURCE%/}" "$COPY_LIST"; then
            echo "${DEEP_RED}[-] Error:${NC} Source traversal failed."; rm -rf -- "$COPY_TMP"; exit 1
        fi
        CUR_REL= CUR_SRC="${SOURCE%/}" CUR_DST="$DEST"; : > "$COPY_FILES"
        while IFS= read -r -d '' ENTRY; do
            REL=${ENTRY#"${SOURCE%/}"/}
            if [ -d "$ENTRY" ] && [ ! -L "$ENTRY" ]; then
                if [ -n "$CUR_REL" ] && [ -s "$COPY_FILES" ]; then
                    rsync -ah --partial --info=progress2 --from0 --files-from="$COPY_FILES" "${CUR_SRC%/*}/" "${CUR_DST%/*}/" 2>>"$COPY_TMP/errors" | stdbuf -o0 tr '\r' '\n' | while IFS= read -r LINE; do LINE=${LINE#"${CUR_SRC##*/}/"}; printf '%s%-16.16s %s' "$CR" "${CUR_SRC##*/}" "$LINE"; done || { rm -rf -- "$COPY_TMP"; exit 1; }
                    ## [T1.3] On a (possibly false) hash failure this deletes the source ledger rsync just copied.
                    hash_tree "$DEST" "$CUR_DST" || { rm -f -- "$CUR_DST/._localhash.sha256"; rm -rf -- "$COPY_TMP"; exit 1; }
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
            ## [T1.3] Same: deletes the copied source ledger on a hash failure.
            hash_tree "$DEST" "$CUR_DST" || { rm -f -- "$CUR_DST/._localhash.sha256"; rm -rf -- "$COPY_TMP"; exit 1; }
        fi
        if [ -s "$COPY_TMP/root.files" ]; then
            rsync -ah --partial --info=progress2 --from0 --files-from="$COPY_TMP/root.files" "${SOURCE%/}/" "$DEST/" 2>>"$COPY_TMP/errors" | stdbuf -o0 tr '\r' '\n' | while IFS= read -r LINE; do printf '%s%s' "$CR" "$LINE"; done || { rm -rf -- "$COPY_TMP"; exit 1; }
            ## [T1.3] Same: deletes the copied source ledger on a hash failure.
            hash_tree "$DEST" "$DEST" || { rm -f -- "$DEST/._localhash.sha256"; rm -rf -- "$COPY_TMP"; exit 1; }
        fi
        echo ""
        echo "${CR}${GREEN}[+] Success!${NC} Directory copy and per-directory hashes complete."
        rm -rf -- "$COPY_TMP"
    else echo ""; echo "${DEEP_RED}[-] Error:${NC} '$SOURCE' is neither a regular file nor a directory."; exit 1
    fi
}
 
## [T1.1] The prompt accepts non-directory roots.  [T6.2] (#9) Returns 0 after refusing a read-only target.
action_hash() { 
    prompt_path HASHDIR "Enter the directory to hash: "
    if ! fs_is_rw "$HASHDIR"; then
        echo "${YELLOW}[!]${NC} Destination '$HASHDIR' is not writable or is read-only; Generate Missing Hashes is unavailable."; echo ""
        return 0
    fi
    hash_tree "$HASHDIR"
}

# Verify a tree against its ledgers: content mismatches, missing files, unlisted additions, and directories with no coverage
## [T1.1] root not validated; [T1.4] read errors vanish; [T1.5] stale resume state; [T2.3][T2.4][T2.5] actual-side
## stream; [T5.4] sync does not evict the page cache; [T6.4] exclusions, CSV quoting, -v D=, post-processor message.
action_verify() {
    prompt_path VDIR "Enter the directory to verify: "; VDIR=${VDIR%/}
    local LOG="$PWD/._verify_$(date +%Y%m%d-%H%M%S).csv" STATE="$PWD/._verify_state" OK=0 BAD=0 NEW=0 NONE=0 D OUT ADD; local -A DONE=()
    ## [T5.4] sync flushes but doesn't drop the page cache: just-copied files are verified from RAM, not the disk.
    sync; echo ""; printf 'path,status,expected,actual,mtime\n' > "$LOG"; rm -f "$STATE.err" "$STATE.dirs"
    ## [T1.5] ./._verify_state never expires: a later run of the same path skips folders marked done, even after
    ##        corruption (exit 0). Fix: ask whether to resume; discard the state if any ledger is newer than it.
    [ -f "$STATE" ] && IFS= read -r -d '' HDR < "$STATE" || HDR=
    [ "$HDR" = "#$VDIR" ] && { while IFS= read -r -d '' k; do DONE["$k"]=1; done < "$STATE"; echo "${YELLOW}[!]${NC} Resuming: $(( ${#DONE[@]} - 1 )) directories already done."; } || printf '#%s\0' "$VDIR" > "$STATE"
    echo "${YELLOW}[!]${NC} Verifying against per-folder SHA-256 ledgers..."
    find "$VDIR" -path "$VDIR/._MANIFESTS" -prune -o -type d -print0 | LC_ALL=C sort -z > "$STATE.dirs" || { BAD=$((BAD+1)); printf '%s,TRAVERSAL ERROR,,,\n' "\"$VDIR\"" >> "$LOG"; }
    while IFS= read -r -d '' D; do
        [ -z "${DONE["$D"]-}" ] || continue
        ST=0 OUT=''; printf '%s%s  ->%s Verifying: %.*s%s' "$CR" "$GREEN" "$NC" "$((COLS-18))" "$D" "$EOL"
        if [ ! -f "$D/._localhash.sha256" ]; then
            FL=$(find "$D" -maxdepth 1 \( -type f -o -type l \) ! -name '._verify*' ! \( "${EXCLUDE_FILES[@]}" \) -print -quit) || ST=$?
            [ -z "$FL" ] || OUT="\"$D\",NO LEDGER,,,"
        else
            ## [T1.4] The status of find ... -exec sha256sum is lost (not the last command of the { } group): an unreadable
            ##        unlisted file vanishes (clean, exit 0); an unreadable listed file is labeled MISSING.
            ## [T2.4] (#3) 'M <mtime> %P' records aren't newline-safe: a newline name splits and is counted as
            ##        "CORRUPT LEDGER, malformed" though the ledger is fine. Build this stream NUL-delimited.
            ## [T2.3] Symlinks: find -printf '%p\n' | read gives raw names vs escaped ledger names (MISSING + UNLISTED).
            ## [T2.5] cat: a ledger without a trailing newline merges into the first M line; A[n]!=E[n] is case-sensitive.
            ## [T6.4] -v D= interprets backslashes in directory names; '._verify*' is excluded here but not when hashing.
            OUT=$(cd "$D" && { cat ._localhash.sha256; TZ=UTC find . -maxdepth 1 -type f ! -name '._verify*' ! \( "${EXCLUDE_FILES[@]}" \) -printf 'M %TY-%Tm-%TdT%TH:%TM:%TSZ %P\n' -exec sha256sum -- {} +
              find . -maxdepth 1 -type l ! -name '._verify*' -printf '%p\n' | while IFS= read -r L; do printf 'SYMLINK:%s  %s\n' "$(readlink -n -- "$L" | sha256sum | cut -d' ' -f1)" "$L"; done; } | awk -v D="$D" 'function q(s){gsub(/"/,"\"\"",s);return "\"" s "\""} /^M / {i=index(substr($0,3)," ")+2; t=substr($0,3,i-3); sub(/\.[0-9]*/,"",t); T[substr($0,i+1)]=t; next} /^SYMLINK:[0-9a-fA-F]{64}  / {h=substr($0,1,72); n=substr($0,75); if (n ~ /^\.\//) {sub(/^\.\//,"",n); A[n]=h} else E[n]=h; next} {sub(/^\\/,""); h=substr($0,1,64); n=substr($0,67)} h !~ /^[0-9a-fA-F]{64}$/ || substr($0,65,2) !~ /^ [ *]$/ {bad++; next} n ~ /^\.\// {sub(/^\.\//,"",n); A[n]=h; next} {if (n in E) dup++; E[n]=h} END{if(bad||dup) printf "%s,CORRUPT LEDGER,%d malformed,%d duplicate,\n", q(D), bad+0, dup+0; for(n in E) if(!(n in A)) printf "%s,MISSING,%s,,\n", q(D "/" n), E[n]; for(n in A) if(!(n in E)) printf "%s,UNLISTED,,%s,%s\n", q(D "/" n), A[n], T[n]; else if(A[n]!=E[n]) printf "%s,MISMATCH,%s,%s,%s\n", q(D "/" n), E[n], A[n], T[n]}' | LC_ALL=C sort) || ST=$?
        fi
        [ "$ST" = 0 ] || OUT="\"$D\",ERROR,,,"
        [ -z "$OUT" ] && { OK=$((OK+1)); printf '%s\0' "$D" >> "$STATE"; } || { printf '%s\n' "$OUT" >> "$LOG"; case "$OUT" in *,MISMATCH,*|*,MISSING,*|*,ERROR,*|*,CORRUPT\ LEDGER,*) BAD=$((BAD+1)) ;; esac; case "$OUT" in *,UNLISTED,*) NEW=$((NEW+1)) ;; esac; case "$OUT" in *,NO\ LEDGER,*) NONE=$((NONE+1)) ;; esac; }
    done < "$STATE.dirs"
    ## [T6.4] Any exception is reported as "python3 unavailable"; the NO LEDGER/ERROR/TRAVERSAL rows don't escape quotes.
    ! [ -f "$LOG" ] || python3 -c 'import csv,io,os,sys,base64;p=sys.argv[1];R=list(csv.reader(io.StringIO(open(p,"rb").read().decode("utf-8","surrogateescape"))));bad=lambda s:any("\udc80"<=c<="\udcff" for c in s)
if any(bad(r[0]) for r in R if r): o=io.StringIO();w=csv.writer(o,lineterminator="\n");[w.writerow((["base64:"+base64.b64encode(r[0].encode("utf-8","surrogateescape")).decode()]+r[1:]) if bad(r[0]) else r) for r in R];open(p+".t","w",encoding="utf-8").write(o.getvalue());os.replace(p+".t",p)' "$LOG" 2>/dev/null || echo "${YELLOW}[!]${NC} python3 unavailable; non-UTF-8 paths left as raw bytes."
    rm -f "$STATE" "$STATE.dirs"; [ $((BAD+NEW+NONE)) -gt 0 ] || rm -f "$LOG"
    echo "${CR}${GREEN}[+] Verified:${NC} $OK folders clean, $BAD with failures, $NEW with unlisted files, $NONE without a ledger.$([ -f "$LOG" ] && echo "  CSV: $LOG")"
    [ $((BAD+NEW+NONE)) -eq 0 ]
}

# Destroy every ledger under a root and rebuild the baseline from current disk content
## [T1.1] root not validated.  [T1.3] A stale FAILLOG fails the rebuild after ledgers moved to .bak; every retry is
##        then refused until the log is deleted by hand.  [T6.2] (#9) Returns 0 after refusing a read-only target.
action_rehash() {
    prompt_path RHDIR "Enter the directory to Total Re-Hash (Overwrite Hashes): "
    if ! fs_is_rw "$RHDIR"; then
        echo "${YELLOW}[!]${NC} Destination '$RHDIR' is not writable or is read-only; Total Re-Hash (Overwrite Hashes) is unavailable."; echo ""
        return 0
    fi
    echo ""; echo "${DEEP_RED}WARNING:${NC} deletes $(find "$RHDIR" -path "$RHDIR/._MANIFESTS" -prune -o -name '._localhash.sha256' | wc -l) ledger(s) and records whatever is on disk now; any corruption present today becomes the new baseline."
    read -r -p "Proceed? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy] ]] || { echo "${DEEP_RED}[-] Error:${NC} Aborted by user."; exit 1; }
    [ -z "$(find "$RHDIR" -path "$RHDIR/._MANIFESTS" -prune -o -name '._localhash.sha256.bak' -print -quit)" ] || { echo "${DEEP_RED}[-] Error:${NC} Backups from an interrupted rebuild are present (._localhash.sha256.bak). Resolve them first."; exit 1; }
    ## [T6.3] find -execdir ... \; exits 0 even when mv fails, so this guard never fires; the ledger count above includes
    ##        the pruned ._MANIFESTS dir (no -print); -path "$RHDIR/._MANIFESTS" fails with a trailing slash or glob chars.
    find "$RHDIR" -path "$RHDIR/._MANIFESTS" -prune -o -name '._localhash.sha256' -execdir mv {} ._localhash.sha256.bak \; || { echo "${DEEP_RED}[-] Error:${NC} Could not set aside every ledger; the baseline would be mixed. Aborted."; exit 1; }
    hash_tree "$RHDIR" && find "$RHDIR" -name '._localhash.sha256.bak' ! -path "$RHDIR/._MANIFESTS/*" -delete || { echo "${DEEP_RED}[-] Error:${NC} Rebuild incomplete; previous ledgers kept as ._localhash.sha256.bak."; exit 1; }
}

# Desktop of the invoking user: the sudo caller when there is one, otherwise root.
## [T6.1] Root writes into this user-writable folder follow planted symlinks.  [T7.2] getent + runuser on every call.
desktop_dir() {
    local u="${SUDO_USER:-root}" h d x
    h=$(getent passwd "$u" | cut -d: -f6) || h=
    [ -n "$h" ] && [ -d "$h" ] || { u=root; h=$(getent passwd root | cut -d: -f6) || h=; [ -n "$h" ] || h=/root; }
    [ -d "$h" ] || return 1
    d=$(runuser -u "$u" -- env HOME="$h" xdg-user-dir DESKTOP 2>/dev/null || sed -n 's/^XDG_DESKTOP_DIR="\(.*\)"$/\1/p' "$h/.config/user-dirs.dirs" 2>/dev/null | tail -1) || d=; d=${d/\$HOME/$h}
    [ -n "$d" ] && [ "$d" != "$h" ] && [ -d "$d" ] || for x in "$h/Desktop" "$h/Documents" "$h"; do d=$x; [ -d "$d" ] && break; done; printf '%s\n' "$d"
}

# JSONL archival manifest: header record, then deterministically sorted, numbered records for files and symlinks
## [T1.1] root not validated; [T1.2] incomplete manifests reported complete/Success; [T3.1]-[T3.6] manifest
## correctness; [T4.1]-[T4.3] extended collector; [T6.1] root cp -f into the Desktop; [T6.5] progress escapes on
## non-TTY stderr, no cleanup trap; [T7.3] verify_all quoting.
action_metadata() {
    prompt_path METADIR "Enter the drive location to export metadata manifest: "; METADIR=${METADIR%/}
    MANIROOT=$(stat -c %m -- "$METADIR") && [ -n "$MANIROOT" ] || { echo "${DEEP_RED}[-] Error:${NC} Cannot determine the drive root of '$METADIR'."; exit 1; }
    OUT=$(mktemp -d); DROP=$(desktop_dir) || DROP=; MANIFEST_DIR=${DROP:+$DROP/DISKUTILS/MANIFEST};

    # Collect once; checksum ledgers are joined directory-locally in the downstream awk stage.      
    ## [T1.2] find stderr goes to /dev/null, and '|| printf SRCFAIL\036' prints to the terminal instead of into the
    ##        stream: unreadable subtrees vanish while the header says complete:true, collection_errors:0.
    ## [T3.2] (#8) Records are framed with \036/\037, bytes a filename can contain: such names are dropped; a newline
    ##        name loses its mime because file(1)'s raw output is split by tr '\n' '\036'.
    ## [T1.1] -mindepth 1 is global: a symlink root yields 0 records.  [T7.3] Raw names are printed to the terminal;
    ##        devices, FIFOs and sockets are never recorded.
    : > "$OUT/mime.raw"; TZ=UTC find "$METADIR" -path "$MANIROOT/._MANIFESTS" -prune -o \( -type f ! \( "${EXCLUDE_FILES[@]}" \) \( -exec sh -c 'out=$1; shift; sep="$(printf "\037M\037")"; file -r -N -F "$sep" --mime-type "$@" | tr "\n" "\036" >> "$out"' sh "$OUT/mime.raw" {} + , -printf '%y\037%h\037%f\037%s\037%TY-%Tm-%TdT%TH:%TM:%TSZ\037%m\037%U\037%G\037%u\037%g\037%i\037%n\037%P\037%l\036' \) \) -o \( \( -type l -o -type d \) ! \( "${EXCLUDE_FILES[@]}" \) -mindepth 1 -printf '%y\037%h\037%f\037%s\037%TY-%Tm-%TdT%TH:%TM:%TSZ\037%m\037%U\037%G\037%u\037%g\037%i\037%n\037%P\037%l\036' \) 2>/dev/null | awk -v R="$METADIR" -v RS='\036' -v ORS='\036' -F '\037' '{ n++; printf "\r\033[2KScanning filesystem... %d objects | Current: %s/%s", n, R, $13 > "/dev/stderr"; fflush("/dev/stderr"); print } END { printf "\r\033[2KScanning filesystem... %d objects\n", n > "/dev/stderr" }' > "$OUT/metadata.raw" || printf 'SRCFAIL\036'
    ## [T3.2] getline blob < ledger runs with RS=\036: a \036 inside a ledger truncates it (a neighbour loses its sha256).
    ## [T2.2] Ledger parser 4 of 4: sub(/^[[:space:]]*[*]?/) strips leading spaces and '*' -> sha256 null for such names.
    ## [T3.4] H[q] is used even when the file is newer than its ledger: a stale hash is exported and verify_all fails.
    ## [T7.2] The ledger is re-read whenever find's order leaves a directory and comes back.  [T7.1] {64}, [[:cntrl:]].
    awk -v RS='\036' -v FS='\037' 'function esc(s,  c) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); if (s ~ /[[:cntrl:]]/) for (c=1;c<32;c++) gsub(sprintf("%c",c), sprintf("\\u%04x",c), s); return s }
        $0=="SRCFAIL" { src++; next }
        NF==3 { v=$3; sub(/^[ \t]+/,"",v); M[$1]=v; next }
        NF==14 { t=$5; q=$3; gsub(/\\/,"\\\\",q); gsub(/\n/,"\\n",q); gsub(/\r/,"\\r",q); D=$2; g=$2 "/" $3; p=esc($13); l=($1=="l"); d=($1=="d")
                if(!d && !l && D != C) { delete H; C=D; f=D "/._localhash.sha256"; if ((getline blob < f)>0) { n=split(blob,lines,"\n"); for(i=1;i<=n;i++) { e=lines[i]; sub(/^\\/,"",e); if (substr(e,1,8)=="SYMLINK:" && substr(e,9,64) ~ /^[0-9a-fA-F]{64}$/) { h=substr(e,9,64); r=substr(e,73); sub(/^[ \t]*/,"",r); H[r]=h } else if (substr(e,1,64) ~ /^[0-9a-fA-F]{64}$/) { h=substr(e,1,64); r=substr(e,65); sub(/^[[:space:]]*[*]?/,"",r); H[r]=h } } } close(f) }
                if(d) x=""; else if(l) x=",\"target\":\"" esc($14) "\""; else x=",\"mime\":" ((g in M)?"\"" esc(M[g]) "\"":"null") ",\"sha256\":" ((q in H)?"\"" H[q] "\"":"null")
                printf "%s\037{\"type\":\"%s\",\"path\":\"./%s\",%s%s\"mtime\":\"%s\",\"mode\":\"%04d\",\"uid\":%d,\"gid\":%d,\"owner\":\"%s\",\"group\":\"%s\",\"inode\":%d,\"links\":%d%s}\n", p, (d?"directory":(l?"symlink":"file")), p, "", (d?"":sprintf("\"size\":%d,",$4)), t, $6, $7, $8, esc($9), esc($10), $11, $12, x ; next }
        NF { rej++ } END { if (rej||src) printf "\001\037REJ\037%d\037%d\n", rej+0, src+0 }' < <(cat "$OUT/mime.raw" "$OUT/metadata.raw") > "$OUT/metadata.jsonl.raw"
    # extended metadata collector
    echo ""
    read -r -p "Collect extended filesystem metadata? [y/N]: " EXTENDED_META
    echo ""
    ## [T4.1] fiemap(): pack_into puts count into fm_mapped_extents and 0 into fm_extent_count, and the result is read
    ##        at offset 16 (fm_flags) instead of 20: every file reports 0 extents while "captured".
    ## [T4.2] (#7) STATX_ATTR_ENCRYPTED is 0x800, not 0x800000; encryption_policy() needs n>=12 (v1) / n>=24 (v2) and
    ##        the v1 descriptor at b[12:20]; a locked file fails open() with ENOKEY: record that explicitly.
    ## [T4.3] except Exception: O.write(l) silently drops the record's extended data; count it into collection_errors.
    ## [T3.1] (#4) Both branches NFC-normalize paths.  [T7.1] ioctl numbers assume 64-bit; statx via ctypes needs glibc >= 2.28.
    if [[ "$EXTENDED_META" =~ ^[Yy]$ ]]; then
	python3 -c 'exec('"'"'import sys,os,json,base64,unicodedata as u,fcntl,ctypes,struct,errno\nR=sys.argv[1]; O=sys.stdout.buffer\nAT_FDCWD=-100; AT_SYMLINK_NOFOLLOW=0x100; STATX_BASIC_STATS=0x7ff; STATX_BTIME=0x800; STATX_MNT_ID=0x1000; STATX_DIOALIGN=0x2000; STATX_SUBVOL=0x8000; STATX_WRITE_ATOMIC=0x10000; STATX_ATTR_ENCRYPTED=0x800000\nFS_IOC_GETFLAGS=0x80086601; FS_IOC_FSGETXATTR=0x801c581f; FS_IOC_FIEMAP=0xc020660b; FS_IOC_GET_ENCRYPTION_POLICY_EX=0xc0096616\nclass TS(ctypes.Structure): _fields_=[("tv_sec",ctypes.c_longlong),("tv_nsec",ctypes.c_uint),("reserved",ctypes.c_int)]\nclass SX(ctypes.Structure): _fields_=[("mask",ctypes.c_uint),("blksize",ctypes.c_uint),("attributes",ctypes.c_ulonglong),("nlink",ctypes.c_uint),("uid",ctypes.c_uint),("gid",ctypes.c_uint),("mode",ctypes.c_ushort),("spare0",ctypes.c_ushort),("ino",ctypes.c_ulonglong),("size",ctypes.c_ulonglong),("blocks",ctypes.c_ulonglong),("attributes_mask",ctypes.c_ulonglong),("atime",TS),("btime",TS),("ctime",TS),("mtime",TS),("rdev_major",ctypes.c_uint),("rdev_minor",ctypes.c_uint),("dev_major",ctypes.c_uint),("dev_minor",ctypes.c_uint),("mnt_id",ctypes.c_ulonglong),("dio_mem_align",ctypes.c_uint),("dio_offset_align",ctypes.c_uint),("subvol",ctypes.c_ulonglong),("atomic_write_unit_min",ctypes.c_uint),("atomic_write_unit_max",ctypes.c_uint),("atomic_write_segments_max",ctypes.c_uint),("spare3",ctypes.c_ulonglong*9)]\nlibc=ctypes.CDLL(None,use_errno=True); libc.statx.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_uint,ctypes.POINTER(SX)]; libc.statx.restype=ctypes.c_int\ndef ts(t): return {"tv_sec":t.tv_sec,"tv_nsec":t.tv_nsec}\ndef fsgetxattr(fd):\n b=bytearray(28); fcntl.ioctl(fd,FS_IOC_FSGETXATTR,b,True); x=struct.unpack("=IIIII",b[:20]); return {"xflags":x[0],"extsize":x[1],"nextents":x[2],"projid":x[3],"cowextsize":x[4]}\ndef fiemap(fd):\n count=4096; esz=56; hsz=32; b=bytearray(hsz+count*esz); struct.pack_into("=QQIIII",b,0,0,0xffffffffffffffff,0,count,0,0); fcntl.ioctl(fd,FS_IOC_FIEMAP,b,True); mapped=struct.unpack_from("=I",b,16)[0]; ext=[]\n for i in range(min(mapped,count)):\n  o=hsz+i*esz; logical,physical,length,r1,r2,flags,r3,r4,r5=struct.unpack_from("=QQQQQIIII",b,o); ext.append({"logical":logical,"physical":physical,"length":length,"flags":flags})\n truncated=bool(mapped>=count and not (ext and (ext[-1]["flags"]&1))); return {"start":0,"length":0xffffffffffffffff,"flags":0,"mapped_extents":mapped,"extent_count":count,"truncated":truncated,"extents":ext}\ndef encryption_policy(fd):\n b=bytearray(40); struct.pack_into("=Q",b,0,32); fcntl.ioctl(fd,FS_IOC_GET_ENCRYPTION_POLICY_EX,b,True); n=struct.unpack_from("=Q",b,0)[0]; version=b[8]; out={"policy_size":n,"version":version}\n if version==2 and n>=28: out.update({"contents_encryption_mode":b[9],"filenames_encryption_mode":b[10],"flags":b[11],"log2_data_unit_size":b[12],"master_key_identifier":"base64:"+base64.b64encode(bytes(b[16:32])).decode("ascii")})\n elif version==0 and n>=16: out.update({"contents_encryption_mode":b[9],"filenames_encryption_mode":b[10],"flags":b[11],"master_key_descriptor":"base64:"+base64.b64encode(bytes(b[16:24])).decode("ascii")})\n else: out["raw_policy"]="base64:"+base64.b64encode(bytes(b[8:8+min(n,32)])).decode("ascii")\n return out\ndef collect(p,t):\n errors=[]; statx=xattrs=posix_acl=capabilities=chattr=fsxattr=fiemap_data=encryption=None; capture={"statx":"capture_failed","xattrs":"capture_failed","posix_acl":"capture_failed","chattr":"capture_failed","fsxattr":"capture_failed","fiemap":"capture_failed","encryption":"unsupported"}; s=SX()\n if libc.statx(AT_FDCWD,p,AT_SYMLINK_NOFOLLOW,STATX_BASIC_STATS|STATX_BTIME|STATX_MNT_ID|STATX_DIOALIGN|STATX_SUBVOL|STATX_WRITE_ATOMIC,ctypes.byref(s))==0:\n  statx={"stx_mask":s.mask,"stx_blksize":s.blksize,"stx_attributes":s.attributes,"stx_nlink":s.nlink,"stx_uid":s.uid,"stx_gid":s.gid,"stx_mode":s.mode,"stx_ino":s.ino,"stx_size":s.size,"stx_blocks":s.blocks,"stx_attributes_mask":s.attributes_mask,"stx_atime":ts(s.atime),"stx_btime":ts(s.btime),"stx_ctime":ts(s.ctime),"stx_mtime":ts(s.mtime),"stx_rdev_major":s.rdev_major,"stx_rdev_minor":s.rdev_minor,"stx_dev_major":s.dev_major,"stx_dev_minor":s.dev_minor,"stx_mnt_id":s.mnt_id,"stx_dio_mem_align":s.dio_mem_align,"stx_dio_offset_align":s.dio_offset_align,"stx_subvol":s.subvol,"stx_atomic_write_unit_min":s.atomic_write_unit_min,"stx_atomic_write_unit_max":s.atomic_write_unit_max,"stx_atomic_write_segments_max":s.atomic_write_segments_max}\n else: errors.append("statx")\n try:\n  xattrs={}; xattr_failed=False\n  try: xattr_names=os.listxattr(p,follow_symlinks=False)\n  except AttributeError: xattrs=None; xattr_names=None; capture["xattrs"]="unavailable"; errors.append("xattrs")\n  if xattrs is not None:\n   for n in xattr_names:\n    try: xattrs[n]="base64:"+base64.b64encode(os.getxattr(p,n,follow_symlinks=False)).decode("ascii")\n    except OSError: errors.append("xattr:"+n); xattr_failed=True\n   capture["xattrs"]="capture_failed" if xattr_failed else ("captured" if xattrs else "absent")\n except OSError as e: errors.append("xattrs"); xattrs=None; capture["xattrs"]="unsupported" if e.errno in (errno.ENOTSUP,errno.EOPNOTSUPP) else "unavailable" if e.errno==errno.ENOSYS else "capture_failed"\n if xattrs is not None:\n  posix_acl={}; acl_failed=any(e.startswith("xattr:system.posix_acl_") for e in errors)\n  if "system.posix_acl_access" in xattrs: posix_acl["access"]={"xattr":"system.posix_acl_access"}\n  if "system.posix_acl_default" in xattrs: posix_acl["default"]={"xattr":"system.posix_acl_default"}\n  capture["posix_acl"]="capture_failed" if acl_failed else ("captured" if posix_acl else "absent"); posix_acl=posix_acl or None\n  if "security.capability" in xattrs: capabilities={"xattr":"security.capability"}; capture["capabilities"]="captured"\n  elif any(e=="xattr:security.capability" for e in errors): capture["capabilities"]="capture_failed"\n  else: capture["capabilities"]="absent"\n else: capture["posix_acl"]=capture["xattrs"]; capture["capabilities"]=capture["xattrs"]\n fd=-1\n if t!="symlink":\n  try:\n   fd=os.open(p,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC)\n   try: fsxattr=fsgetxattr(fd); capture["fsxattr"]="captured"\n   except OSError as e: capture["fsxattr"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("fsxattr")\n   try: b=bytearray(4); fcntl.ioctl(fd,FS_IOC_GETFLAGS,b,True); f=struct.unpack("=I",b)[0]; chattr={"flags":f,"hex":"0x%08x"%f}; capture["chattr"]="captured"\n   except OSError as e: capture["chattr"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("chattr")\n   if t=="file":\n    try: fiemap_data=fiemap(fd); capture["fiemap"]="captured"\n    except OSError as e: capture["fiemap"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("fiemap")\n   else: capture["fiemap"]="unsupported"\n   if statx is not None and statx["stx_attributes"]&STATX_ATTR_ENCRYPTED:\n    try: encryption=encryption_policy(fd); capture["encryption"]="captured"\n    except OSError as e: capture["encryption"]="unsupported" if e.errno in (errno.ENOTTY,errno.ENOTSUP,errno.EOPNOTSUPP) else "capture_failed"; errors.append("encryption")\n   else: capture["encryption"]="absent"\n  except OSError: capture["fsxattr"]="capture_failed"; capture["chattr"]="capture_failed"; capture["fiemap"]="unsupported"; capture["encryption"]="capture_failed"; errors.append("open")\n  finally:\n   if fd>=0: os.close(fd)\n else: capture["chattr"]="unsupported"; capture["fsxattr"]="unsupported"; capture["fiemap"]="unsupported"; capture["encryption"]="unsupported"\n if statx is not None: capture["statx"]="captured"\n metadata={"capture":capture}; statx is not None and metadata.update({"statx":statx}); xattrs is not None and metadata.update({"xattrs":xattrs}); posix_acl is not None and metadata.update({"posix_acl":posix_acl}); capabilities is not None and metadata.update({"capabilities":capabilities}); chattr is not None and metadata.update({"chattr":chattr}); fsxattr is not None and metadata.update({"fsxattr":fsxattr}); fiemap_data is not None and metadata.update({"fiemap":fiemap_data}); encryption is not None and metadata.update({"encryption":encryption}); metadata["errors"]=errors or None; return metadata\nfor l in sys.stdin.buffer:\n if l.startswith(b"\\001\\037REJ\\037"): O.write(l); continue\n try:\n  k,j=l.rstrip(b"\\n").split(b"\\037",1); r=json.loads(u.normalize("NFC",j.decode("utf-8","surrogateescape"))); p=os.fsencode(os.path.join(R,r["path"][2:])); r["metadata"]=collect(p,r["type"]); O.write(k+b"\\037"+json.dumps(r,ensure_ascii=True,separators=(",",":"),sort_keys=False).encode()+b"\\n")\n except Exception: O.write(l)'"'"')' "$METADIR" < "$OUT/metadata.jsonl.raw"
    else
        ## [T3.1] NFC normalization.  [T3.6] Invalid-UTF-8 names are written raw here, which is not valid JSON.
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
    
    ## [T3.3] REL is a string prefix-strip of stat -c %m: wrong for a relative or symlinked METADIR (verify_all fails).
    ##        Fix: realpath -e first (same as T1.1).
    ## [T3.6] The header awk above uses awk -v R=, which interprets backslashes in the root path; it also says "unicode":"NFC".
    REL=${METADIR#"$MANIROOT"}; REL=${REL#/}; python3 -c 'import sys,json;sys.stdin.reconfigure(errors="surrogateescape");sys.stdout.reconfigure(errors="surrogateescape");R=sys.argv[1];q=lambda s:s.replace("\\","\\\\").replace("\n","\\n").replace("\r","\\r");[print(("\\" if q(p)!=p else "")+r["sha256"]+"  "+q(p)) for r in map(json.loads,sys.stdin) if r.get("type")=="file" and r.get("sha256") for p in ["./"+R+r["path"][2:]]]' "${REL:+$REL/}" < "$OUT/._manifest-metadata.jsonl" > "$OUT/._manifest-hashrecord.sha256"; CHECKSUM_HASH=$(sha256sum -- "$OUT/._manifest-hashrecord.sha256" | cut -d' ' -f1) 
    ## [T3.5] STAMP is computed but never used in filenames.  [T2.5] verify_folder (sha256sum -c) warns on SYMLINK: lines.
    ## [T7.3] verify_all interpolates unquoted paths (use printf %q); with no Desktop it becomes /._manifest-hashrecord.sha256.
    STAMP=$(TZ=UTC date +%Y%m%dT%H%M%SZ); N=$(( $(wc -l < "$OUT/._manifest-metadata.jsonl") - 1 )); printf '## Header Generated by TransferManager ## \ngenerated         : %s\nrun_stamp         : %s\nhost              : %s\nroot_directory    : %s\nmetadata_scope    : %s\nmetadata_records  : %s\nhashed_records    : %s\nsymlinks_skipped  : %s\nunhashed_records  : %s\nlast_operation    : metadata\ninvoked_by        : %s\nhistory_dir       : ._MANIFESTS\nmetadata_sha256   : %s\nhashrecord_sha256 : %s\nmetadata_header   : %s\nverify_all        : cd "%s" && sha256sum -c --quiet "%s/._manifest-hashrecord.sha256"\nverify_folder     : cd <dir> && sha256sum -c --quiet ._localhash.sha256\n' "$(date -Is)" "$STAMP" "$(hostname)" "$MANIROOT" "$METADIR" "$N" "$(wc -l < "$OUT/._manifest-hashrecord.sha256")" "$(grep -c '"type":"symlink"' "$OUT/._manifest-metadata.jsonl" || :)" "$(grep -c '"sha256":null' "$OUT/._manifest-metadata.jsonl" || :)" "${SUDO_USER:-$(id -un)}" "$(sha256sum < "$OUT/._manifest-metadata.jsonl" | cut -d' ' -f1)" "$CHECKSUM_HASH" "$(head -1 -- "$OUT/._manifest-metadata.jsonl")" "$MANIROOT" "$MANIFEST_DIR" > "$OUT/._manifest-header.meta"
    if [ "$SAVE_DRIVE" -eq 1 ]; then
        ## [T3.5] Fixed filenames: every export overwrites the drive-root copy (exporting subfolder B replaces A's).
        cp -f -- "$OUT/._manifest-metadata.jsonl" "$OUT/._manifest-hashrecord.sha256" "$OUT/._manifest-header.meta" "$MANIROOT/" || { echo "${YELLOW}[!]${NC} Live manifest copy under $MANIROOT failed."; SAVE_DRIVE=0; }
        ## [T3.5] ._MANIFESTS/ is overwritten on every export, so it keeps no history.
        mkdir -p -- "$MANIROOT/._MANIFESTS" && cp -f -- "$OUT/._manifest-metadata.jsonl" "$OUT/._manifest-hashrecord.sha256" "$OUT/._manifest-header.meta" "$MANIROOT/._MANIFESTS/" || echo "${YELLOW}[!]${NC} Historical copy under $MANIROOT/._MANIFESTS failed."
    fi
    echo ""
    echo "${CR}${GREEN}[+] Success!${NC} Wrote $N records."
    ## [T6.1] Root cp -f into the user-writable Desktop folder follows planted symlinks.  [T6.5] $OUT is never cleaned on errors.
    if [ -n "$DROP" ]; then mkdir -p -- "$MANIFEST_DIR" && cp -f -- "$OUT/._manifest-metadata.jsonl" "$OUT/._manifest-hashrecord.sha256" "$OUT/._manifest-header.meta" "$MANIFEST_DIR/" && { chown -R -- "${SUDO_UID:-0}:${SUDO_GID:-0}" "$DROP/DISKUTILS" 2>/dev/null || :; echo "${GREEN}[+]${NC} Desktop copy: $MANIFEST_DIR"; rm -rf -- "$OUT"; } || echo "${YELLOW}[!]${NC} No Desktop copy written (copy failed); files are in $OUT."; elif [ "$SAVE_DRIVE" -eq 1 ]; then echo ""; echo "${GREEN}[+]${NC} Manifest saved to $MANIROOT."; rm -rf -- "$OUT"; else echo "${YELLOW}[!]${NC} No persistent manifest destination available; files are in $OUT."; fi
    echo ""
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

