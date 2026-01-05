# -------------------------
# Parameters - edit these
# -------------------------
$storageAccount = "<STORAGE_ACCOUNT_NAME>"
$fileShare      = "<FILE_SHARE_NAME>"
$cutoffHours    = <24/48/etc.>
$useManagedIdentity = $true   # $true to use Connect-AzAccount -Identity

# -------------------------
# Acquire token
# -------------------------
Clear-AzContext -Scope Process
if ($useManagedIdentity) { Connect-AzAccount -Identity -ErrorAction Stop } else { Connect-AzAccount -ErrorAction Stop }
$tokenResource = "https://$storageAccount.file.core.windows.net/"
$tok = Get-AzAccessToken -ResourceUrl $tokenResource -ErrorAction Stop
$bearer = if ($tok.Token -is [System.Security.SecureString]) {
    [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok.Token))
} else { $tok.Token }
$bearer = $bearer.Trim() -replace '[\uFEFF\u200B]', ''

# -------------------------
# Helpers
# -------------------------
function Escape-PathSegments {
    param([string]$p)
    if ([string]::IsNullOrEmpty($p)) { return "" }
    $segments = $p -split '/'
    $escaped = $segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }
    return ($escaped -join '/')
}

# FIXED: Build-ListUrl now calls Escape-PathSegments first and uses the result
function Build-ListUrl {
    param(
        [string]$dirPath,
        [string]$marker
    )
    $base = "https://$storageAccount.file.core.windows.net/$($fileShare.Trim('/'))"
    if (-not [string]::IsNullOrEmpty($dirPath)) {
        $escaped = Escape-PathSegments -p $dirPath
        if (-not [string]::IsNullOrEmpty($escaped)) {
            $base += "/$escaped"
        }
    }
    $query = "restype=directory&comp=list"
    if (-not [string]::IsNullOrEmpty($marker)) {
        $query += "&marker=$([System.Uri]::EscapeDataString($marker))"
    }
    return "$base`?$query"
}

function Invoke-FileList {
    param($dirPath,$marker)
    $url = Build-ListUrl -dirPath $dirPath -marker $marker
    $h = @{
        "Authorization" = "Bearer $bearer"
        "x-ms-version"  = "2023-08-03"
        "x-ms-date"     = (Get-Date).ToUniversalTime().ToString("R")
        "x-ms-file-request-intent" = "backup"
        "Accept" = "application/xml"
    }
    try {
        $raw = Invoke-RestMethod -Method Get -Uri $url -Headers $h -ErrorAction Stop
        $clean = $raw.Trim() -replace "^ï»¿", "" -replace "^[^<]+", ""
        [xml]$xml = $clean
        return $xml
    } catch {
        Write-Warning ("List failed for '{0}': {1}" -f $dirPath, $_.Exception.Message)
        if ($_.Exception.Response -and $_.Exception.Response.Headers) { $_.Exception.Response.Headers | Format-List }
        return $null
    }
}

function Head-FileGetTimestampsUtc {
    param([string]$filePath)
    $segments = $filePath -split '/'
    $escaped = $segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }
    $escapedPath = ($escaped -join '/')
    $url = "https://$storageAccount.file.core.windows.net/$fileShare/$escapedPath"
    $h = @{
        "Authorization" = "Bearer $bearer"
        "x-ms-version"  = "2023-08-03"
        "x-ms-date"     = (Get-Date).ToUniversalTime().ToString("R")
        "x-ms-file-request-intent" = "backup"
    }
    try {
        $resp = Invoke-WebRequest -Method Head -Uri $url -Headers $h -ErrorAction Stop
        $change = $resp.Headers["x-ms-file-change-time"]
        $lm = $resp.Headers["Last-Modified"]
        $lastWrite = $resp.Headers["x-ms-file-last-write-time"]
        $parsed = $null
        if ($change) { $parsed = [DateTime]::Parse($change).ToUniversalTime() }
        elseif ($lm) { $parsed = [DateTime]::Parse($lm).ToUniversalTime() }
        elseif ($lastWrite) { $parsed = [DateTime]::Parse($lastWrite).ToUniversalTime() }
        return @{ ParsedUtc = $parsed; Raw = @{ "x-ms-file-change-time" = $change; "Last-Modified" = $lm; "x-ms-file-last-write-time" = $lastWrite } }
    } catch {
        Write-Verbose ("HEAD failed for {0}: {1}" -f $filePath, $_.Exception.Message)
        return @{ ParsedUtc = $null; Raw = $null }
    }
}

# -------------------------
# Enumerator that ensures a reliable timestamp per file
# -------------------------
function Get-StaleFiles {
    param([datetime]$cutoffUtc)
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push("")  # root
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $marker = ""
        do {
            $xml = Invoke-FileList -dirPath $dir -marker $marker
            if (-not $xml -or -not $xml.EnumerationResults) { break }
            $entries = $xml.EnumerationResults.Entries

            if ($entries.Directory) {
                foreach ($d in @($entries.Directory)) {
                    $child = if ([string]::IsNullOrEmpty($dir)) { $d.Name } else { "$dir/$($d.Name)" }
                    $stack.Push($child)
                }
            }

            if ($entries.File) {
                foreach ($f in @($entries.File)) {
                    $fullPath = if ([string]::IsNullOrEmpty($dir)) { $f.Name } else { "$dir/$($f.Name)" }

                    $lmFromList = $f.Properties."Last-Modified"
                    $parsedUtc = $null
                    if ($lmFromList) {
                        try { $parsedUtc = [DateTime]::Parse($lmFromList).ToUniversalTime() } catch { $parsedUtc = $null }
                    }

                    if (-not $parsedUtc) {
                        $head = Head-FileGetTimestampsUtc -filePath $fullPath
                        $parsedUtc = $head.ParsedUtc
                    }

                    $size = 0
                    if ($f.Properties."Content-Length") { try { $size = [int64]$f.Properties."Content-Length" } catch { $size = 0 } }

                    if ($parsedUtc -ne $null) {
                        if ($parsedUtc -lt $cutoffUtc) {
                            [PSCustomObject]@{ Path = $fullPath; Size = $size; LastModifiedUtc = $parsedUtc }
                        } else {
                            Write-Verbose ("Not stale: {0}  LastModifiedUtc: {1:u}" -f $fullPath, $parsedUtc)
                        }
                    } else {
                        Write-Verbose ("No timestamp available for {0}; skipping" -f $fullPath)
                    }
                }
            } else {
                Write-Verbose ("No File nodes returned for directory '{0}'" -f $dir)
            }

            $marker = ""
            if ($xml.EnumerationResults.NextMarker) { $marker = $xml.EnumerationResults.NextMarker.Trim() }
        } while (-not [string]::IsNullOrEmpty($marker))
    }
}

# -------------------------
# Main
# -------------------------
$cutoffUtc = (Get-Date).ToUniversalTime().AddHours(-1 * [int]$cutoffHours)
Write-Output ("Cutoff UTC: {0:u}" -f $cutoffUtc)
$found = 0
foreach ($item in Get-StaleFiles -cutoffUtc $cutoffUtc) {
    $found++
    Write-Output ("STALE: {0}  {1:N0} bytes  LastModifiedUtc: {2:u}" -f $item.Path, $item.Size, $item.LastModifiedUtc)
}
if ($found -eq 0) { Write-Output "No stale files found." } else { Write-Output ("Total stale files found: {0}" -f $found) }
