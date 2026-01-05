# Parameters - edit these
$storageAccount = "<STORAGE_ACCOUNT_NAME>"
$fileShare      = "<FILE_SHARE_NAME>"

# Acquire a fresh AAD token (Automation runbook: system managed identity)
Clear-AzContext -Scope Process

#$bearer = $tok.Token.Trim() -replace '[\uFEFF\u200B]', ''
#$plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok.Token))
#$bearer = $plainToken.Trim() -replace '[\uFEFF\u200B]', ''

# Connect using the System-Assigned Managed Identity
Connect-AzAccount -Identity -ErrorAction Stop

# Get the token
$tokenResource = "https://$storageAccount.file.core.windows.net/"
$tok = Get-AzAccessToken -ResourceUrl $tokenResource -ErrorAction Stop

# Robust conversion (Works in both old and new Az modules)
if ($tok.Token -is [System.Security.SecureString]) {
    # 2025+ logic: Convert SecureString to plain text
    $bearer = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok.Token))
} else {
    # Legacy logic: Token is already a string
    $bearer = $tok.Token
}

# Clean up any potential hidden characters (BOM fix)
$bearer = $bearer.Trim() -replace '[\uFEFF\u200B]', ''


# Helper: call Azure Files REST to list a directory and return parsed XML
function Get-ShareDirectoryListing {
    param(
        [string]$storageAccount,
        [string]$share,
        [string]$directoryPath
    )

    $url = "https://$storageAccount.file.core.windows.net/$($share.Trim('/'))"
    if (-not [string]::IsNullOrEmpty($directoryPath)) {
        $url += "/$([System.Uri]::EscapeDataString($directoryPath.Trim('/')))"
    }
    $url += "?restype=directory&comp=list"

    $headers = @{
        "Authorization" = "Bearer $bearer"
        "x-ms-version"  = "2023-08-03"
        "x-ms-date"     = (Get-Date).ToUniversalTime().ToString("R")
        "x-ms-file-request-intent" = "backup"
    }

    try {
        # 1. Get raw string instead of letting PowerShell guess the object type
        $rawResponse = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop
        
        # 2. Strip the BOM (ï»¿) and any hidden whitespace
        $cleanXmlString = $rawResponse.Trim() -replace "^ï»¿", "" -replace "^[^<]+", ""
        
        # 3. Manually cast to XML object
        [xml]$xml = $cleanXmlString
        return $xml
    } catch {
        Write-Error "Failed path '$directoryPath': $($_.Exception.Message)"
        throw $_
    }
}

# Recursive enumerator: yields PSCustomObject for each file with full path and size
function Get-AllFilesInShare {
    param($storageAccount, $share)

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push("") 
    $results = @()

    while ($stack.Count -gt 0) {
        $path = $stack.Pop()
        $xml = Get-ShareDirectoryListing -storageAccount $storageAccount -share $share -directoryPath $path

        # Navigate the XML hierarchy based on your successful trace
        $entries = $xml.EnumerationResults.Entries

        # Handle Files
        if ($entries.File) {
            foreach ($f in @($entries.File)) {
                $fullPath = if ([string]::IsNullOrEmpty($path)) { $f.Name } else { "$path/$($f.Name)" }
                $results += [PSCustomObject]@{
                    Path = $fullPath
                    Size = $f.Properties."Content-Length"
                }
            }
        }

        # Handle Directories
        if ($entries.Directory) {
            foreach ($d in @($entries.Directory)) {
                $childPath = if ([string]::IsNullOrEmpty($path)) { $d.Name } else { "$path/$($d.Name)" }
                $stack.Push($childPath)
            }
        }
    }
    return $results
}

# Run and collect results
$allFiles = Get-AllFilesInShare -storageAccount $storageAccount -share $fileShare
$allFiles | Format-Table -AutoSize
