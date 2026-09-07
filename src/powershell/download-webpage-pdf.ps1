<#
.SYNOPSIS
    Downloads every archived meeting-minutes document (PDF/DOC/DOCX) linked from a
    given "Archived Minutes" (or similar document-archive) page.

.DESCRIPTION
    Fetches the page at -Url, parses the raw HTML for hyperlinks pointing at document
    files (.pdf, .doc, .docx, .xls, .xlsx), resolves them to absolute URLs, and
    downloads each one into -OutputDirectory.

    The page is parsed live on every run (rather than working from a hard-coded list of
    filenames) so the script keeps working as the site posts new months' minutes or
    renames files. Already-downloaded files are skipped unless -Force is used, so
    re-running the script is safe and only pulls down what's new.

    For every file actually on disk after this run, a JSON metadata sidecar (same base
    name as the file, with a json extension) is written alongside it, recording the
    source file URL, the linked text from the page, the page URL it was found on, the
    ISO 8601 download date, a checksum (see -HashAlgorithm) and the file size.
    Freshly-downloaded files always get a fresh sidecar; a pre-existing file that was
    skipped (no -Force) gets one backfilled only if it doesn't already have one.

    A CSV log (download-log.csv) is written to the output directory summarizing what was
    downloaded, skipped, or failed, with the source URL for each — useful for citing an
    exact source document later.

.PARAMETER Url
    The archived-minutes (or similar document-archive) page to scan. Mandatory — there
    is no default, since a wrong or unset URL would silently do nothing useful.

.PARAMETER OutputDirectory
    Folder to save downloaded files into. Defaults to a "minutes" folder next to this
    script. Created automatically if it doesn't exist.

.PARAMETER FilenamePattern
    Optional regex to restrict which linked files get downloaded (matched against the
    file name only, case-insensitive). Default '.' matches everything found on the page.
    Example: '_minutes' to skip a site map / non-minutes attachments.

.PARAMETER DelayMilliseconds
    Pause between downloads, to be polite to the server. Default 400ms.

.PARAMETER MaxRetries
    Number of attempts per file before giving up. Default 3.

.PARAMETER Force
    Re-download and overwrite files that already exist locally.

.PARAMETER HashAlgorithm
    Hash algorithm used to checksum each downloaded file for its metadata sidecar.
    Accepts the same values as `Get-FileHash -Algorithm` (SHA1, SHA256, SHA384, SHA512,
    MD5). Default 'SHA256'.

.EXAMPLE
    .\download-webpage-pdf.ps1 -Url 'https://example.com/archived-minutes.html'

    Downloads every linked document into .\minutes (created next to the script).

.EXAMPLE
    .\download-webpage-pdf.ps1 -Url 'https://example.com/archived-minutes.html' -OutputDirectory D:\Minutes -FilenamePattern '_minutes' -Force

    Re-downloads only files whose name contains "_minutes" into D:\Minutes,
    overwriting anything already there.

.EXAMPLE
    .\download-webpage-pdf.ps1 -Url 'https://example.com/archived-minutes.html' -WhatIf

    Lists every file that would be downloaded without actually downloading anything.

.EXAMPLE
    .\download-webpage-pdf.ps1 -Url 'https://example.com/archived-minutes.html' -HashAlgorithm SHA1

    Downloads every linked document into .\minutes, checksumming each one with SHA1
    (instead of the default SHA256) in its .json metadata sidecar.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [string] $Url,

    [string] $OutputDirectory = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'minutes' } else { Join-Path (Get-Location) 'minutes' }),

    [string] $FilenamePattern = '.',

    [int] $DelayMilliseconds = 400,

    [int] $MaxRetries = 3,

    [switch] $Force,

    [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
    [string] $HashAlgorithm = 'SHA256'
)

$ErrorActionPreference = 'Stop'

# Older Windows PowerShell (5.1 / .NET Framework) doesn't always default to TLS 1.2,
# which most modern sites now require. Harmless no-op on PowerShell 7+.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "Could not force TLS 1.2 (likely already the default on this host): $($_.Exception.Message)"
}

$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell-Archive-Fetcher/1.0'

function Get-SafeFileName {
    param([Parameter(Mandatory)][string] $Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $clean = ($Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } }) -join ''
    return $clean
}

function Get-LinkedDocumentUrls {
    param(
        [Parameter(Mandatory)][string] $PageUrl,
        [Parameter(Mandatory)][string] $UserAgent
    )

    Write-Host "Fetching page: $PageUrl" -ForegroundColor Cyan
    $response = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }
    $html = $response.Content

    $baseUri = [Uri]::new($PageUrl)

    # Match href="..." / href='...' values ending in a document extension we care about.
    # Regex-based rather than a DOM/HTML parser so this works identically on Windows
    # PowerShell 5.1 and PowerShell 7+ with no extra dependencies.
    $hrefPattern = 'href\s*=\s*[''"]([^''"]+\.(?:pdf|docx?|xlsx?|pptx?|txt|csv))(?:[''"#?])'

    # Match whole <a ...>...</a> elements so the visible link text can be paired with
    # its href — needed for the per-file metadata sidecar written after each download.
    # Singleline so '.' also matches newlines inside a multi-line anchor body.
    $anchorPattern = '<a\b[^>]*>(.*?)</a\s*>'
    $anchorOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
        [System.Text.RegularExpressions.RegexOptions]::Singleline

    $items = New-Object System.Collections.Generic.List[pscustomobject]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    function Resolve-DocumentLink {
        param([string] $RawHref, [string] $RawText)

        $raw = [System.Net.WebUtility]::HtmlDecode($RawHref)
        try {
            $resolved = [Uri]::new($baseUri, $raw)
        } catch {
            Write-Warning "Skipping unresolvable link: $raw"
            return $null
        }
        $key = $resolved.AbsoluteUri.ToLowerInvariant()
        if (-not $seen.Add($key)) {
            return $null
        }

        # Strip any nested markup (e.g. <span>...</span> inside the anchor), decode
        # HTML entities, then collapse/trim whitespace. Falls back to '' when there's
        # no text at all (e.g. an image-only link).
        $text = ''
        if ($RawText) {
            $text = [regex]::Replace($RawText, '<[^>]+>', '')
            $text = [System.Net.WebUtility]::HtmlDecode($text)
            $text = ([regex]::Replace($text, '\s+', ' ')).Trim()
        }

        return [pscustomobject]@{ Url = $resolved.AbsoluteUri; LinkText = $text }
    }

    foreach ($a in [regex]::Matches($html, $anchorPattern, $anchorOpts)) {
        $hrefMatch = [regex]::Match($a.Value, $hrefPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $hrefMatch.Success) { continue }
        $item = Resolve-DocumentLink -RawHref $hrefMatch.Groups[1].Value -RawText $a.Groups[1].Value
        if ($item) { $items.Add($item) }
    }

    # Fallback: catch any href matching our extensions that wasn't inside a well-formed
    # <a>...</a> pair (e.g. malformed/unclosed markup), so link discovery never regresses
    # versus a plain href scan. These get an empty LinkText since there's no anchor body
    # to read text from.
    foreach ($m in [regex]::Matches($html, $hrefPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $item = Resolve-DocumentLink -RawHref $m.Groups[1].Value -RawText $null
        if ($item) { $items.Add($item) }
    }

    return $items
}

function Write-FileMetadata {
    <#
    .SYNOPSIS
        Writes (or overwrites) the .json metadata sidecar for a downloaded file.
    #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $FileUrl,
        [AllowEmptyString()][string] $LinkText = '',
        [Parameter(Mandatory)][string] $PageUrl,
        [Parameter(Mandatory)][string] $HashAlgorithm,
        [string] $DownloadDate,
        [switch] $Backfilled
    )

    $fileInfo = Get-Item -LiteralPath $FilePath -ErrorAction Stop
    $hash = Get-FileHash -LiteralPath $FilePath -Algorithm $HashAlgorithm -ErrorAction Stop

    if (-not $DownloadDate) {
        $DownloadDate = Get-Date -Format 'o'
    }

    $metadata = [pscustomobject]@{
        FileUrl           = $FileUrl
        LinkText          = $LinkText
        PageUrl           = $PageUrl
        DownloadDate      = $DownloadDate
        ChecksumAlgorithm = $HashAlgorithm
        Checksum          = $hash.Hash
        SizeBytes         = $fileInfo.Length
        Backfilled        = [bool]$Backfilled
    }

    $metadataPath = [System.IO.Path]::ChangeExtension($FilePath, '.json')
    $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
}

# --- Discover files ---
$documentUrls = Get-LinkedDocumentUrls -PageUrl $Url -UserAgent $UserAgent

if ($documentUrls.Count -eq 0) {
    Write-Warning "No document links (.pdf/.doc/.docx/.xls/.xlsx) were found on $Url. The page structure may have changed."
    return
}

if ($FilenamePattern -ne '.') {
    $before = $documentUrls.Count
    $documentUrls = $documentUrls | Where-Object {
        $name = [Uri]::UnescapeDataString([System.IO.Path]::GetFileName(([Uri]$_.Url).AbsolutePath))
        $name -match $FilenamePattern
    }
    Write-Host "Filtered $before link(s) down to $($documentUrls.Count) matching -FilenamePattern '$FilenamePattern'." -ForegroundColor DarkGray
}

Write-Host "Found $($documentUrls.Count) unique document link(s) on the page." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    # Creating the folder is a harmless prerequisite, not the operation -WhatIf should
    # suppress (which is the actual file downloads below) — force it regardless of the
    # ambient WhatIf/Confirm preference so path resolution below always succeeds.
    New-Item -ItemType Directory -Path $OutputDirectory -Force -WhatIf:$false -Confirm:$false | Out-Null
}
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

# --- Download loop ---
$results = New-Object System.Collections.Generic.List[pscustomobject]
$index = 0

foreach ($doc in $documentUrls) {
    $index++
    $fileUrl = $doc.Url
    $linkText = $doc.LinkText
    $uri = [Uri]$fileUrl
    $decodedName = [Uri]::UnescapeDataString([System.IO.Path]::GetFileName($uri.AbsolutePath))
    $safeName = Get-SafeFileName -Name $decodedName
    $destination = Join-Path $OutputDirectory $safeName

    Write-Progress -Activity 'Downloading archived minutes' -Status "$index of $($documentUrls.Count): $safeName" -PercentComplete (($index / $documentUrls.Count) * 100)

    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        $existingFile = Get-Item -LiteralPath $destination
        Write-Host "[skip]      $safeName (already exists)" -ForegroundColor DarkGray
        $results.Add([pscustomobject]@{ File = $safeName; Url = $fileUrl; Status = 'Skipped (exists)'; SizeBytes = $existingFile.Length })

        # Backfill a metadata sidecar for a pre-existing file that doesn't have one yet.
        # Never overwrite an existing sidecar here (mirrors the download skip semantics
        # above: only -Force causes anything already on disk to be rewritten). The
        # download date is unknowable for a file we didn't just download, so the file's
        # own LastWriteTime is used as the best available approximation and the record
        # is flagged Backfilled so that distinction isn't lost.
        $metadataPath = [System.IO.Path]::ChangeExtension($destination, '.json')
        if (-not (Test-Path -LiteralPath $metadataPath)) {
            if ($PSCmdlet.ShouldProcess($metadataPath, "Backfill metadata for existing $safeName")) {
                try {
                    Write-FileMetadata -FilePath $destination -FileUrl $fileUrl -LinkText $linkText -PageUrl $Url `
                        -HashAlgorithm $HashAlgorithm -DownloadDate $existingFile.LastWriteTime.ToString('o') -Backfilled
                } catch {
                    Write-Warning "Failed to backfill metadata for $safeName : $($_.Exception.Message)"
                }
            }
        }
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($destination, "Download from $fileUrl")) {
        $results.Add([pscustomobject]@{ File = $safeName; Url = $fileUrl; Status = 'Skipped (-WhatIf)'; SizeBytes = 0 })
        continue
    }

    $attempt = 0
    $downloaded = $false
    $lastError = $null

    while (-not $downloaded -and $attempt -lt $MaxRetries) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $fileUrl -OutFile $destination -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }

            $fileInfo = Get-Item -LiteralPath $destination -ErrorAction Stop
            if ($fileInfo.Length -le 0) {
                throw "Downloaded file is empty (0 bytes)."
            }

            Write-Host "[ok]        $safeName ($([math]::Round($fileInfo.Length / 1KB, 1)) KB)" -ForegroundColor Green
            $results.Add([pscustomobject]@{ File = $safeName; Url = $fileUrl; Status = 'Downloaded'; SizeBytes = $fileInfo.Length })
            $downloaded = $true

            # Nested try/catch so a metadata-write problem can never be mistaken by the
            # outer catch for a failed download (which would delete the file and retry).
            try {
                Write-FileMetadata -FilePath $destination -FileUrl $fileUrl -LinkText $linkText -PageUrl $Url -HashAlgorithm $HashAlgorithm
            } catch {
                Write-Warning "Failed to write metadata for $safeName : $($_.Exception.Message)"
            }
        } catch {
            $lastError = $_.Exception.Message
            if (Test-Path -LiteralPath $destination) {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -lt $MaxRetries) {
                Write-Warning "Attempt $attempt/$MaxRetries failed for $safeName ($lastError). Retrying..."
                Start-Sleep -Milliseconds ($DelayMilliseconds * 2)
            }
        }
    }

    if (-not $downloaded) {
        Write-Warning "[failed]    $safeName after $MaxRetries attempt(s): $lastError"
        $results.Add([pscustomobject]@{ File = $safeName; Url = $fileUrl; Status = "Failed: $lastError"; SizeBytes = 0 })
    }

    Start-Sleep -Milliseconds $DelayMilliseconds
}

Write-Progress -Activity 'Downloading archived minutes' -Completed

# --- Summary & log ---
$logPath = Join-Path $OutputDirectory 'download-log.csv'
$results | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8

$downloadedCount = ($results | Where-Object { $_.Status -eq 'Downloaded' }).Count
$skippedCount    = ($results | Where-Object { $_.Status -like 'Skipped*' }).Count
$failedCount     = ($results | Where-Object { $_.Status -like 'Failed*' }).Count

Write-Host ""
Write-Host "===================== Summary =====================" -ForegroundColor Cyan
Write-Host ("Downloaded : {0}" -f $downloadedCount)
Write-Host ("Skipped    : {0}" -f $skippedCount)
Write-Host ("Failed     : {0}" -f $failedCount)
Write-Host ("Saved to   : {0}" -f $OutputDirectory)
Write-Host ("Log file   : {0}" -f $logPath)
Write-Host "====================================================" -ForegroundColor Cyan

if ($failedCount -gt 0) {
    Write-Host ""
    Write-Host "Failed files:" -ForegroundColor Yellow
    $results | Where-Object { $_.Status -like 'Failed*' } | ForEach-Object { Write-Host ("  - {0}  ({1})" -f $_.File, $_.Status) -ForegroundColor Yellow }
}
