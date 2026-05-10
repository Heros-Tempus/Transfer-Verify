# Transfer-Verify

Verifies that files were correctly transferred from a local directory to a remote SMB network share. It checks for missing files, size mismatches, and hash mismatches, and produces a plain-text report.

## Prerequisites

- **PowerShell 7+** on the local machine
- **SSH access** to the remote host (key-based auth recommended — the script cannot accept interactive password prompts)
- **PowerShell 7+** on the remote host (or change `$remotePSExe` to `powershell` for Windows PowerShell 5.1)
- The remote host must expose the target folder as an **SMB share** (so `Get-SmbShare` can resolve it)

## Setup

1. Place `verify.ps1` in the local directory you want to verify.
2. Create `network_location.txt` in the same directory containing the UNC path of the remote share:

   ```text
   \\your-remote-host\your-share-name
   ```

3. Run the script:

   ```powershell
   pwsh -File verify.ps1
   ```

## Output

The script writes `verification_report.txt` to the local directory with three sections:

```text
[FILES MISSING FROM REMOTE]
relative\path\to\missing\file.ext
...

[SIZE MISMATCHES]
relative\path\to\mismatched\file.ext
...

[HASH MISMATCHES]
relative\path\to\corrupt\file.ext
...
```

Each section shows `(none)` if no issues were found. A preliminary report (with hashing marked as in-progress) is written early so results are visible during the long hashing phase.

## Caching

To make repeated runs fast, hashes are cached to disk:

| File | Contents |
| --- | --- |
| `local_hashes_cache.txt` | Relative path \| MD5 hash for each local file |
| `remote_hashes_cache.txt` | Relative path \| MD5 hash for each remote file |

On subsequent runs only new or previously-uncached files are hashed. Stale entries (for files that no longer exist) are pruned automatically.

## Tuning

At the top of `verify.ps1`:

| Variable | Default | Description |
| --- | --- | --- |
| `$hashAlgorithm` | `MD5` | Hash algorithm passed to `Get-FileHash`. MD5 is ~3× faster than SHA256 and sufficient for transfer-corruption detection. |
| `$throttleLimit` | `8` | Parallel threads used when hashing local files. |
| `$batchSize` | `50` | Number of local files hashed per parallel batch. |
| `$remoteIndividualMax` | `10` | Per-directory threshold: if a directory has ≤ this many new remote files they are hashed individually; above it the whole directory is re-scanned in one SSH call. |
| `$remotePSExe` | `pwsh` | PowerShell executable name on the remote host. Change to `powershell` for Windows PowerShell 5.1. |

## How it works

1. Reads `network_location.txt`, connects over SSH, and resolves the share name to its local path on the remote host via `Get-SmbShare`.
2. Builds a recursive file list (with sizes) on both sides.
3. Compares lists: files absent on the remote are flagged as missing; files with a different size are flagged as size mismatches; the rest proceed to hashing.
4. Hashes remote files over SSH using the incremental cache.
5. Hashes local files in parallel batches using the incremental cache.
6. Compares hashes and writes the final report.

## Files managed by the script

The following files are created in the script's directory and are automatically excluded from verification:

- `network_location.txt`
- `verification_report.txt`
- `local_hashes_cache.txt`
- `remote_hashes_cache.txt`
- `verify.ps1` itself
