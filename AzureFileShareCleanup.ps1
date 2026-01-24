<#
.SYNOPSIS
    Daily maintenance script for Azure File Share.

.DESCRIPTION
    - Connects with Automation Account managed identity, assuming the script is used as PS runbook in Azure Automation account.
    - Uses Azure Storage REST API for direct HTTP requests.
    - Lightweight and dependency-free (no Az PowerShell modules required).
    - Ideal for automation jobs, restricted environments, or custom integrations.
    - Deletes files older than N hours

.PARAMETER storageAccount
    Name of the storage account.

.PARAMETER fileShare
    Name of the file share.

.PARAMETER cutoffHours
    Number of hours. Files that have not been modified in last $cutoffHours will be deleted.

.PARAMETER useManagedIdentity
    Accepted values are $true or $false. If $false, then the script uses logged-in user's identity.

.NOTES
    Author: Handover2AI-byExistence
    Date:   2026-01-09
    Doesn't Require: Az PowerShell modules required
#>

# Parameters
$storageAccount = "<NAME OF THE STORAGE ACCOUNT>"
$fileShare      = "<NAME OF THE FILE SHARE>"
$cutoffHours    = 24
$useManagedIdentity = $true 

# Acquire token
Clear-AzContext -Scope Process
if ($useManagedIdentity) { Connect-AzAccount -Identity -ErrorAction Stop } else { Connect-AzAccount -ErrorAction Stop }
$tokenResource = "https://$storageAccount.file.core.windows.net/"
$tok = Get-AzAccessToken -ResourceUrl $tokenResource -ErrorAction Stop
$bearer = if ($tok.Token -is [System.Security.SecureString]) {
    [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok.Token))
} else { $tok.Token }
$bearer = $bearer.Trim() -replace '[\uFEFF\u200B]', ''

# Helper Functions
function Escape-PathSegments {
    param([string]$p)
    if ([string]::IsNullOrEmpty($p)) { return "" }
    $segments = $p -split '/'
    $escaped = $segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }
    return ($escaped -join '/')
}

function Build-ListUrl {
    param([string]$dirPath, [string]$marker)
    $base = "https://$storageAccount.file.core.windows.net/$($fileShare.Trim('/'))"
    if (-not [string]::IsNullOrEmpty($dirPath)) {
        $escaped = Escape-PathSegments -p $dirPath
        if (-not [string]::IsNullOrEmpty($escaped)) { $base += "/$escaped" }
    }
    $query = "restype=directory&comp=list"
    if (-not [string]::IsNullOrEmpty($marker)) { $query += "&marker=$([System.Uri]::EscapeDataString($marker))" }
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
    } catch { return $null }
}

function Remove-AzureFile {
    param([string]$filePath)
    $escapedPath = Escape-PathSegments -p $filePath
    $url = "https://$storageAccount.file.core.windows.net/$fileShare/$escapedPath"
    $h = @{
        "Authorization" = "Bearer $bearer"
        "x-ms-version"  = "2023-08-03"
        "x-ms-date"     = (Get-Date).ToUniversalTime().ToString("R")
        "x-ms-file-request-intent" = "backup"
    }
    try {
        Invoke-RestMethod -Method Delete -Uri $url -Headers $h -ErrorAction Stop
        Write-Output "DELETED: $filePath"
    } catch {
        Write-Error "Failed to delete ${filePath}. Error: $($_.Exception.Message)"
    }
}

function Head-FileGetTimestampsUtc {
    param([string]$filePath)
    $escapedPath = Escape-PathSegments -p $filePath
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
        $parsed = $null
        if ($change) { $parsed = [DateTime]::Parse($change).ToUniversalTime() }
        elseif ($lm) { $parsed = [DateTime]::Parse($lm).ToUniversalTime() }
        return @{ ParsedUtc = $parsed }
    } catch { return @{ ParsedUtc = $null } }
}

# Main Logic
$cutoffUtc = (Get-Date).ToUniversalTime().AddHours(-1 * [int]$cutoffHours)
Write-Output "Cutoff UTC: $($cutoffUtc.ToString('u'))"

$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push("") 

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
                $parsedUtc = if ($lmFromList) { [DateTime]::Parse($lmFromList).ToUniversalTime() } else { (Head-FileGetTimestampsUtc -filePath $fullPath).ParsedUtc }

                if ($parsedUtc -and $parsedUtc -lt $cutoffUtc) {
                    Remove-AzureFile -filePath $fullPath
                }
            }
        }
        $marker = if ($xml.EnumerationResults.NextMarker) { $xml.EnumerationResults.NextMarker.Trim() } else { "" }
    } while (-not [string]::IsNullOrEmpty($marker))
}
