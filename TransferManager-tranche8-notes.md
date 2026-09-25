## ----------------------------------------------------------------------------------------------------------
## TRANCHE 8 - LEDGER SYMLINK VULNERABILITY AND ROBUSTNESS GAPS
## ----------------------------------------------------------------------------------------------------------
## [T8.1] The per-folder ledger writer follows symlinks and can disclose or overwrite root-owned files.
##   This affects `._localhash.sha256` and its `.tmp` / `.bak` siblings when Generate Missing Hashes or
##   single-file Copy updates a ledger.
##   - The script runs as root, but these ledger paths are inside user-controlled directories.
##   - `._localhash.sha256` is not checked for symlinks before it is read and rewritten.
##   - `._localhash.sha256.tmp` and `._localhash.sha256.bak` are likewise not checked for symlinks.
##   - A symlinked `._localhash.sha256` can point at a root-readable file such as `/etc/shadow`. The existing
##     contents are read as ledger entries and then written into a new regular ledger in the user's directory,
##     disclosing the contents.
##   - A symlinked `._localhash.sha256.tmp` can point at a root-owned file. The `>` redirection follows the
##     symlink and truncates the target before writing the new ledger contents.
##   Fix:
##   - For each folder, refuse to operate if `._localhash.sha256`, `.tmp`, or `.bak` is a symlink:
##     `[ -L "$CHECKSUM_FILE" ] && { error; skip; }` (using the corresponding paths for `.tmp` and `.bak`).
##   - Create the temporary ledger with `O_EXCL` / `mktemp` in the same directory instead of using the fixed
##     `.tmp` pathname, so a pre-existing symlink cannot occupy the temporary-file path.
##   - Open the existing ledger for reading without following symlinks (`O_NOFOLLOW`), or otherwise retain the
##     explicit symlink check as the protection for that read.
##
## [T8.2] The error summary and metadata completion state have remaining correctness ambiguities.
##   - The "Incomplete!" summary can miscount messages when the error log is empty; `grep -vc` on empty input
##     can produce `2 other messages`.
##   - When `fresh` recreates the Desktop during a run, the displayed Desktop path can differ from the location
##     where the error log actually lands (`/root/Desktop/DISKUTILS` versus `/root/DISKUTILS`).
##   - Metadata can contain records with `"sha256":null` while the header reports `"complete":true`, so a
##     consumer cannot necessarily interpret `complete:true` as meaning that every file has a hash.
##   Fix:
##   - Correct the empty-error-log counting so the "Incomplete!" summary reports only messages actually present.
##   - Keep the error-log path consistent with the actual directory used during the run, including when `fresh`
##     recreates the Desktop.
##   - Make the meaning of `complete` consistent with the presence of `sha256:null` records, so its value is
##     unambiguous to consumers.