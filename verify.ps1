#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

# --- Tuning ---
$hashAlgorithm       = 'MD5'  # ~3x faster than SHA256; adequate for transfer verification
$throttleLimit       = 8      # Parallel threads per batch for local hashing
$batchSize           = 50     # Files per batch for local hashing
$remoteIndividualMax = 10     # Hash this many new remote files individually per directory;
                              # above this threshold the whole directory is re-scanned

# Change to 'powershell' if the remote only has Windows PowerShell 5.1
$remotePSExe = 'pwsh'

function Invoke-RemotePS {
    param([string]$RemoteHost, [string]$Script)
    $fullScript = "`$ProgressPreference = 'SilentlyContinue'`n" + $Script
    $encoded    = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fullScript))
    $output     = ssh $RemoteHost "$script:remotePSExe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $encoded"
    if ($LASTEXITCODE -ne 0) { throw "Remote command failed (exit $LASTEXITCODE)" }
    return , @($output | Where-Object { $_ -ne '' })
}

# --- Configuration ---
$localRoot       = $PSScriptRoot
$netLocFile      = Join-Path $localRoot 'network_location.txt'
$reportFile      = Join-Path $localRoot 'verification_report.txt'
$cacheFile       = Join-Path $localRoot 'local_hashes_cache.txt'
$remoteCacheFile = Join-Path $localRoot 'remote_hashes_cache.txt'
$scriptLeaf      = Split-Path $PSCommandPath -Leaf
$excludeNames    = @($scriptLeaf, 'network_location.txt', 'verification_report.txt', 'local_hashes_cache.txt', 'remote_hashes_cache.txt')

# --- Validate network location file ---
if (-not (Test-Path $netLocFile)) {
    Write-Error "network_location.txt not found at: $netLocFile"
    exit 1
}

$remoteUNC = (Get-Content $netLocFile -Raw).Trim()
$parts = $remoteUNC.TrimStart('\').Split('\', 2)
if ($parts.Count -lt 2 -or -not $parts[0] -or -not $parts[1]) {
    Write-Error "Invalid UNC path in network_location.txt: $remoteUNC"
    exit 1
}
$remoteHost = $parts[0]
$shareName  = $parts[1]

Write-Host "Local root  : $localRoot"
Write-Host "Remote host : $remoteHost  |  Share: $shareName"
Write-Host "Algorithm   : $hashAlgorithm  |  Threads: $throttleLimit  |  Batch: $batchSize"

# --- Resolve share name to local path on remote ---
Write-Host "`nResolving remote share path..."
try {
    $remoteLocalPath = (Invoke-RemotePS $remoteHost "(Get-SmbShare -Name '$shareName' -ErrorAction Stop).Path.TrimEnd('\')" )[0]
} catch {
    Write-Error "Could not resolve share '$shareName' on ${remoteHost}: $_"
    exit 1
}
Write-Host "Remote local path: $remoteLocalPath"

# --- Step 1: Build flat file lists with sizes ---
Write-Host "`n[Step 1] Building file lists..."

$localBase  = $localRoot.TrimEnd('\')
$localItems = Get-ChildItem -Path $localRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $excludeNames -notcontains $_.Name } |
    ForEach-Object {
        [PSCustomObject]@{
            Path = $_.FullName.Substring($localBase.Length).TrimStart('\')
            Size = $_.Length
        }
    }

Write-Host "  Local  : $($localItems.Count) files"

try {
    $remoteListScript = @"
Get-ChildItem -Path '$remoteLocalPath' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    `$rel = `$_.FullName.Substring('$remoteLocalPath'.Length).TrimStart('\')
    "`$rel|`$(`$_.Length)"
}
"@
    $remoteListRaw = Invoke-RemotePS $remoteHost $remoteListScript
} catch {
    Write-Error "Failed to list remote files: $_"
    exit 1
}

$remoteItems = @{}
foreach ($line in $remoteListRaw) {
    $idx = $line.LastIndexOf('|')
    if ($idx -gt 0) {
        $remoteItems[$line.Substring(0, $idx)] = [long]$line.Substring($idx + 1)
    }
}

Write-Host "  Remote : $($remoteItems.Count) files"

# --- Step 2: Name + size check ---
Write-Host "`n[Step 2] Checking file presence and sizes..."

$missingFromRemote = [System.Collections.Generic.List[string]]::new()
$sizeMismatches    = [System.Collections.Generic.List[string]]::new()
$filesToHash       = [System.Collections.Generic.List[string]]::new()

foreach ($item in $localItems) {
    if (-not $remoteItems.ContainsKey($item.Path)) {
        $missingFromRemote.Add($item.Path)
    } elseif ($remoteItems[$item.Path] -ne $item.Size) {
        $sizeMismatches.Add($item.Path)
    } else {
        $filesToHash.Add($item.Path)
    }
}

Write-Host "  Missing from remote : $($missingFromRemote.Count)"
Write-Host "  Size mismatches     : $($sizeMismatches.Count)"
Write-Host "  To hash             : $($filesToHash.Count)"

# Write preliminary report so results are visible during the long hashing phase
$prelimLines = [System.Collections.Generic.List[string]]::new()
$prelimLines.Add("[FILES MISSING FROM REMOTE]")
if ($missingFromRemote.Count -eq 0) { $prelimLines.Add("(none)") }
else { foreach ($f in $missingFromRemote) { $prelimLines.Add($f) } }
$prelimLines.Add("")
$prelimLines.Add("[SIZE MISMATCHES]")
if ($sizeMismatches.Count -eq 0) { $prelimLines.Add("(none)") }
else { foreach ($f in $sizeMismatches) { $prelimLines.Add($f) } }
$prelimLines.Add("")
$prelimLines.Add("[HASH MISMATCHES]")
$prelimLines.Add("(hashing in progress)")
$prelimLines | Out-File $reportFile -Encoding UTF8
Write-Host "  Preliminary report written to: $reportFile"

$filesToHashArr = $filesToHash.ToArray()

# --- Step 3: Remote hashes (incremental cache) ---
Write-Host "`n[Step 3] Remote hashes..."

$remoteHashes = @{}
if (Test-Path $remoteCacheFile) {
    foreach ($line in (Get-Content $remoteCacheFile)) {
        $idx = $line.LastIndexOf('|')
        if ($idx -gt 0) { $remoteHashes[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
    }
    Write-Host "  Loaded $($remoteHashes.Count) cached hashes."
}

# Remove entries for files no longer on remote
$staleRemote = @($remoteHashes.Keys | Where-Object { -not $remoteItems.ContainsKey($_) })
foreach ($f in $staleRemote) { $remoteHashes.Remove($f) }
if ($staleRemote.Count -gt 0) { Write-Host "  Removed $($staleRemote.Count) stale entries." }

# Find remote files with no cached hash
$remoteToHash = @($remoteItems.Keys | Where-Object { -not $remoteHashes.ContainsKey($_) })

if ($remoteToHash.Count -eq 0) {
    Write-Host "  All remote hashes are current."
} else {
    Write-Host "  $($remoteToHash.Count) remote files need hashing..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $dirsWithNewFiles = @($remoteToHash |
        ForEach-Object {
            $sep = $_.IndexOf('\')
            if ($sep -gt 0) { $_.Substring(0, $sep) } else { '' }
        } | Sort-Object -Unique)

    $dirNum = 0
    foreach ($dir in $dirsWithNewFiles) {
        $dirNum++
        $newInDir    = @($remoteToHash | Where-Object {
            $sep = $_.IndexOf('\')
            $d   = if ($sep -gt 0) { $_.Substring(0, $sep) } else { '' }
            $d -eq $dir
        })
        $displayName = if ($dir -eq '') { '(root)' } else { $dir }

        if ($newInDir.Count -le $remoteIndividualMax) {
            # Few new files: hash individually to avoid re-scanning files already in cache
            Write-Host "  Dir $dirNum/$($dirsWithNewFiles.Count): $displayName ($($newInDir.Count) files, individual)... " -NoNewline
            $batchSw = [System.Diagnostics.Stopwatch]::StartNew()
            foreach ($rel in $newInDir) {
                $escapedPath = ("$remoteLocalPath\$rel").Replace("'", "''")
                $hash = (Invoke-RemotePS $remoteHost "(Get-FileHash -Path '$escapedPath' -Algorithm $hashAlgorithm -ErrorAction SilentlyContinue).Hash")[0]
                if ($hash) { $remoteHashes[$rel] = $hash }
            }
            $batchSw.Stop()
            Write-Host "done ($($batchSw.Elapsed.ToString('mm\:ss')))  [$($sw.Elapsed.ToString('hh\:mm\:ss')) elapsed]"
        } else {
            # Many new files: scan entire directory in one SSH call
            Write-Host "  Dir $dirNum/$($dirsWithNewFiles.Count): $displayName ($($newInDir.Count) files, full scan)... " -NoNewline
            $batchSw = [System.Diagnostics.Stopwatch]::StartNew()

            if ($dir -eq '') {
                $dirHashScript = @"
Get-ChildItem -Path '$remoteLocalPath' -File -ErrorAction SilentlyContinue | ForEach-Object {
    `$rel  = `$_.Name
    `$hash = (Get-FileHash -Path `$_.FullName -Algorithm $hashAlgorithm).Hash
    "`$rel|`$hash"
}
"@
            } else {
                $dirPath = "$remoteLocalPath\$dir"
                $dirHashScript = @"
Get-ChildItem -Path '$dirPath' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    `$rel  = `$_.FullName.Substring('$remoteLocalPath'.Length).TrimStart('\')
    `$hash = (Get-FileHash -Path `$_.FullName -Algorithm $hashAlgorithm).Hash
    "`$rel|`$hash"
}
"@
            }

            try {
                $dirOutput = Invoke-RemotePS $remoteHost $dirHashScript
            } catch {
                Write-Error "Remote hashing failed on '$displayName': $_"
                exit 1
            }

            $batchSw.Stop()
            $fileCount = 0
            foreach ($line in $dirOutput) {
                $idx = $line.LastIndexOf('|')
                if ($idx -gt 0) {
                    $remoteHashes[$line.Substring(0, $idx)] = $line.Substring($idx + 1)
                    $fileCount++
                }
            }
            Write-Host "done ($fileCount files, $($batchSw.Elapsed.ToString('mm\:ss')))  [$($sw.Elapsed.ToString('hh\:mm\:ss')) elapsed]"
        }
    }

    $sw.Stop()
    Write-Host "  Hashing complete in $($sw.Elapsed.ToString('hh\:mm\:ss'))."
}

($remoteHashes.Keys | ForEach-Object { "$_|$($remoteHashes[$_])" }) | Out-File $remoteCacheFile -Encoding UTF8
Write-Host "  Remote cache updated ($($remoteHashes.Count) entries)."

# --- Step 4: Local hashes (incremental cache) ---
Write-Host "`n[Step 4] Local hashes..."

$localHashes = @{}
if (Test-Path $cacheFile) {
    foreach ($line in (Get-Content $cacheFile)) {
        $idx = $line.LastIndexOf('|')
        if ($idx -gt 0) { $localHashes[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
    }
    Write-Host "  Loaded $($localHashes.Count) cached hashes."
}

# Remove entries for files no longer needing a hash
$filesToHashSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $filesToHashArr) { [void]$filesToHashSet.Add($f) }
$staleLocal = @($localHashes.Keys | Where-Object { -not $filesToHashSet.Contains($_) })
foreach ($f in $staleLocal) { $localHashes.Remove($f) }
if ($staleLocal.Count -gt 0) { Write-Host "  Removed $($staleLocal.Count) stale entries." }

# Find local files with no cached hash
$localToHash = @($filesToHashArr | Where-Object { -not $localHashes.ContainsKey($_) })

if ($localToHash.Count -eq 0) {
    Write-Host "  All local hashes are current."
} else {
    Write-Host "  $($localToHash.Count) local files need hashing..."
    $processed = 0

    for ($i = 0; $i -lt $localToHash.Count; $i += $batchSize) {
        $batch   = $localToHash[$i..[Math]::Min($i + $batchSize - 1, $localToHash.Count - 1)]
        $results = $batch | ForEach-Object -Parallel {
            [PSCustomObject]@{
                Path = $_
                Hash = (Get-FileHash -Path (Join-Path $using:localRoot $_) -Algorithm $using:hashAlgorithm).Hash
            }
        } -ThrottleLimit $throttleLimit
        foreach ($r in $results) { $localHashes[$r.Path] = $r.Hash }
        $processed += $batch.Count
        Write-Host "  $processed / $($localToHash.Count)"
    }

    Write-Host "  Done."
}

($localHashes.Keys | ForEach-Object { "$_|$($localHashes[$_])" }) | Out-File $cacheFile -Encoding UTF8
Write-Host "  Local cache updated ($($localHashes.Count) entries)."

# --- Step 5: Compare hashes ---
Write-Host "`n[Step 5] Comparing hashes..."

$hashMismatches = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $filesToHash) {
    if ($localHashes[$rel] -ne $remoteHashes[$rel]) {
        $hashMismatches.Add($rel)
    }
}
Write-Host "  Hash mismatches: $($hashMismatches.Count)"

# --- Step 6: Write final report (overwrites preliminary) ---
Write-Host "`n[Step 6] Writing report..."

$lines = [System.Collections.Generic.List[string]]::new()

$lines.Add("[FILES MISSING FROM REMOTE]")
if ($missingFromRemote.Count -eq 0) { $lines.Add("(none)") }
else { foreach ($f in $missingFromRemote) { $lines.Add($f) } }

$lines.Add("")
$lines.Add("[SIZE MISMATCHES]")
if ($sizeMismatches.Count -eq 0) { $lines.Add("(none)") }
else { foreach ($f in $sizeMismatches) { $lines.Add($f) } }

$lines.Add("")
$lines.Add("[HASH MISMATCHES]")
if ($hashMismatches.Count -eq 0) { $lines.Add("(none)") }
else { foreach ($f in $hashMismatches) { $lines.Add($f) } }

$lines | Out-File $reportFile -Encoding UTF8

Write-Host "Done. Results written to: $reportFile"
