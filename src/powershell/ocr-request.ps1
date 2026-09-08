<#
.SYNOPSIS
    Generic client for a local OCR HTTP API. Uploads a PDF (or a directory of
    PDFs) as multipart/form-data to POST {BaseUrl}/ocr/raw and prints/saves
    the JSON response(s).

.DESCRIPTION
    Calls a local OCR service (default: http://localhost:8000) at the /ocr/raw
    endpoint, uploading the given PDF file as multipart/form-data. Query params
    (layout, tables, formulas) and the base URL are all configurable. The form
    field name used for the file upload defaults to "file" but can be changed
    with -FieldName if the API expects a different field name.

    The saved output file is a JSON envelope, not the server's raw response
    body verbatim: it wraps the OCR content alongside the request context
    (source PDF, endpoint, query params) and the HTTP response metadata
    (status code, headers), so each output file is self-describing. Shape:

        {
          "request":  { "pdfPath": "...", "pdfFileName": "...", "uri": "...",
                        "baseUrl": "...", "endpointPath": "...",
                        "layout": "...", "tables": "...", "formulas": "...",
                        "fieldName": "..." },
          "response": { "statusCode": 200, "statusDescription": "OK",
                        "headers": { "Content-Type": "application/json", ... } },
          "ocr":      { ...exactly what the OCR server returned as its
                        response body... }
        }

    The script has two mutually exclusive modes:

    Single-file mode (-PdfPath): uploads one PDF and prints the JSON response.
    Optionally saves it with -OutFile, or -TargetDir (see below).

    Batch mode (-SourceDir): uploads every top-level *.pdf file found in the
    given directory (non-recursive -- subfolders are not scanned, since batch
    input directories are typically flat drop folders; recursion was left out
    to keep the failure/summary semantics per requirement 5 easy to reason
    about, not because it would be hard to add). Each PDF is processed in
    turn using the same upload/request logic as single-file mode. A per-file
    failure is caught and reported, and does NOT stop the rest of the batch;
    a summary of successes/failures is printed at the end.

    Exactly one of -PdfPath or -SourceDir must be supplied.

    Timing: every OCR request's upload+response duration is measured with
    System.Diagnostics.Stopwatch and reported as it completes (e.g.
    "Processed 'foo.pdf' in 12.3s"). Batch mode also lists each succeeded
    file's duration in the final summary, and both modes report the total
    wall-clock time for the whole run at the end.

.PARAMETER PdfPath
    Path to a single PDF file to upload. Mutually exclusive with -SourceDir.
    Exactly one of -PdfPath / -SourceDir is required.

.PARAMETER SourceDir
    Path to a directory containing PDF files to process in batch. Every
    top-level file matching *.pdf in this directory is uploaded in turn.
    Mutually exclusive with -PdfPath. Exactly one of -PdfPath / -SourceDir
    is required.

.PARAMETER TargetDir
    Directory to write JSON output file(s) to.

    In batch mode (-SourceDir), this overrides the default output location,
    which is the source directory itself ("<SourceDir>"). Each PDF's output
    is written as "<TargetDir>\<pdf-base-name>_ocr.json". The directory is
    created if it does not already exist. An existing output file for the
    same PDF name is overwritten.

    In single-file mode (-PdfPath), -TargetDir is optional: if supplied
    (and -OutFile is not), the response is saved as
    "<TargetDir>\<pdf-base-name>_ocr.json" instead of requiring an explicit
    -OutFile. If both -OutFile and -TargetDir are given in single-file mode,
    -OutFile takes precedence (it is the more explicit/specific instruction).

.PARAMETER BaseUrl
    Base URL of the OCR API. Defaults to http://localhost:8000.

.PARAMETER Layout
    Value for the "layout" query parameter. Defaults to 1.

.PARAMETER Tables
    Value for the "tables" query parameter. Defaults to 0.

.PARAMETER Formulas
    Value for the "formulas" query parameter. Defaults to 0.

.PARAMETER FieldName
    Name of the multipart form field the PDF is uploaded under. Defaults to
    "file". Change this if the API expects a different field name (e.g.
    "document" or "pdf").

.PARAMETER EndpointPath
    URL path appended to -BaseUrl. Defaults to "/ocr/raw" per the target API.
    Override this (e.g. "/ocr/pdf") if your server build routes whole-PDF
    uploads to a different path than /ocr/raw (some OCR servers treat "raw"
    as raw pixel bytes rather than an encoded PDF/image container -- check
    GET {BaseUrl}/capabilities on your server if /ocr/raw rejects a PDF).

.PARAMETER OutFile
    Optional path to save the raw JSON response to disk. Single-file mode
    only. If omitted (and -TargetDir is not given either), the response is
    only printed to stdout. Takes precedence over -TargetDir if both are
    supplied.

.PARAMETER TimeoutSec
    Optional request timeout in seconds. Defaults to 300 (OCR can be slow on
    large PDFs).

.EXAMPLE
    # Basic usage against the default local server with default query params
    .\ocr-request.ps1 -PdfPath ".\test\5c_approved_sept_minutes.pdf"

.EXAMPLE
    # Save the response to a file and override the base URL / query params
    .\ocr-request.ps1 -PdfPath "C:\docs\sample.pdf" -BaseUrl "http://localhost:9000" -Layout 0 -Tables 1 -Formulas 0 -OutFile "C:\out\sample.json"

.EXAMPLE
    # Use a different multipart field name if the API doesn't expect "file"
    .\ocr-request.ps1 -PdfPath "C:\docs\sample.pdf" -FieldName "document"

.EXAMPLE
    # Batch mode: OCR every PDF in a folder, writing results directly into
    # that same folder as C:\docs\to-process\<name>_ocr.json
    .\ocr-request.ps1 -SourceDir "C:\docs\to-process"

.EXAMPLE
    # Batch mode with a custom output directory instead of the default
    # (the source directory itself)
    .\ocr-request.ps1 -SourceDir "C:\docs\to-process" -TargetDir "C:\docs\results"

.NOTES
    Requires PowerShell 7+ (pwsh) for Invoke-WebRequest -Form multipart support.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$PdfPath,

    [string]$SourceDir,

    [string]$TargetDir,

    [Parameter(Position = 1)]
    [string]$BaseUrl = "http://localhost:8000",

    [ValidateSet("0", "1")]
    [string]$Layout = "1",

    [ValidateSet("0", "1")]
    [string]$Tables = "0",

    [ValidateSet("0", "1")]
    [string]$Formulas = "0",

    [string]$FieldName = "file",

    [string]$EndpointPath = "/ocr/raw",

    [string]$OutFile,

    [int]$TimeoutSec = 300
)

$ErrorActionPreference = "Stop"

# --- Enforce mutually exclusive modes: exactly one of -PdfPath / -SourceDir ---
if ($PdfPath -and $SourceDir) {
    Write-Error "Specify only one of -PdfPath or -SourceDir, not both."
    exit 1
}
if (-not $PdfPath -and -not $SourceDir) {
    Write-Error "You must specify either -PdfPath (single file) or -SourceDir (batch directory)."
    exit 1
}

# --- Start the total wall-clock timer for this run (covers the single file
# in single-file mode, or the entire batch in -SourceDir mode) ---
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# --- Build the target URI (shared by single-file and batch modes) ---
$endpoint = "$($BaseUrl.TrimEnd('/'))/$($EndpointPath.TrimStart('/'))"
$queryString = "layout=$Layout&tables=$Tables&formulas=$Formulas"
$uri = "$endpoint`?$queryString"

# --- Shared duration-formatting helper used by both single-file and batch modes ---
function Format-Duration {
    <#
    .SYNOPSIS
        Formats a TimeSpan as a compact, human-readable duration string.

    .DESCRIPTION
        Renders total elapsed seconds with one decimal place (e.g. "12.3s"),
        matching the style used throughout this script's timing output.

    .PARAMETER Duration
        The TimeSpan to format, typically a Stopwatch's .Elapsed value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Duration
    )

    return "{0:N1}s" -f $Duration.TotalSeconds
}

# --- Shared header-flattening helper used by Invoke-OcrUpload ---
function Get-FlattenedHeaders {
    <#
    .SYNOPSIS
        Flattens an HTTP response's Headers dictionary into a plain ordered
        hashtable suitable for JSON serialization.

    .DESCRIPTION
        Invoke-WebRequest's $response.Headers is a
        Dictionary<string, IEnumerable<string>>. This collapses each entry
        to a plain string when it has exactly one value, or keeps it as a
        string array when it has multiple values, so ConvertTo-Json renders
        it naturally instead of as nested enumerator objects.

    .PARAMETER Headers
        The response Headers dictionary (e.g. $response.Headers).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Headers
    )

    $flattened = [ordered]@{}
    foreach ($key in $Headers.Keys) {
        $values = @($Headers[$key])
        if ($values.Count -eq 1) {
            $flattened[$key] = $values[0]
        }
        else {
            $flattened[$key] = $values
        }
    }
    return $flattened
}

# --- Shared upload/response function used by both single-file and batch modes ---
function Invoke-OcrUpload {
    <#
    .SYNOPSIS
        Uploads one PDF to the OCR API and returns a JSON envelope wrapping
        the request context, HTTP response metadata, and the OCR content.

    .DESCRIPTION
        Performs the multipart POST for a single resolved PDF path and
        returns an object whose Json property is the fully-serialized
        envelope (see this script's top-level .DESCRIPTION for the shape).
        Throws on any failure; the caller is responsible for catching and
        reporting (single-file mode exits on failure, batch mode catches
        per-file and continues). No envelope is built on failure -- a
        failed request throws before this point, so nothing is written.

    .PARAMETER ResolvedPdfPath
        Fully resolved, existing path to the PDF file to upload.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedPdfPath
    )

    # --- Build multipart form ---
    $form = @{
        $FieldName = Get-Item -LiteralPath $ResolvedPdfPath
    }

    try {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Form $form -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    catch {
        $ex = $_.Exception

        # Case 1: The server responded, but with a non-success HTTP status
        # (e.g. 400/404/500). This means the server IS reachable -- report the
        # actual status and body instead of a misleading "server unreachable".
        if ($ex.Response -and $ex.Response.StatusCode) {
            $statusCode = [int]$ex.Response.StatusCode
            $body = $_.ErrorDetails.Message
            if (-not $body) { $body = "<no response body>" }
            throw "OCR API at '$uri' returned HTTP $statusCode. Response body: $body"
        }

        # Case 2: A local file-access problem (e.g. the PDF is locked by another
        # process, such as OneDrive syncing or another program having it open),
        # not a server connectivity issue.
        if ($ex -is [System.IO.IOException] -or $ex.InnerException -is [System.IO.IOException]) {
            throw "Could not read the PDF file '$ResolvedPdfPath'. It may be open/locked by another process (e.g. OneDrive, another OCR job, a PDF viewer). Details: $($ex.Message)"
        }

        # Case 3: Genuine network unreachability (connection refused, DNS
        # failure, timeout, etc.)
        throw "Could not reach OCR API at '$BaseUrl'. Is the server running? Details: $($ex.Message)"
    }

    $rawJson = $response.Content

    try {
        $ocrContent = $rawJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        # If it isn't valid JSON for some reason, fall back to keeping the
        # raw text as the "ocr" value -- never silently drop data.
        $ocrContent = $rawJson
    }

    $envelope = [ordered]@{
        request  = [ordered]@{
            pdfPath      = $ResolvedPdfPath
            pdfFileName  = [System.IO.Path]::GetFileName($ResolvedPdfPath)
            uri          = $uri
            baseUrl      = $BaseUrl
            endpointPath = $EndpointPath
            layout       = $Layout
            tables       = $Tables
            formulas     = $Formulas
            fieldName    = $FieldName
        }
        response = [ordered]@{
            statusCode        = [int]$response.StatusCode
            statusDescription = $response.StatusDescription
            headers           = Get-FlattenedHeaders -Headers $response.Headers
        }
        ocr      = $ocrContent
    }

    $json = $envelope | ConvertTo-Json -Depth 50

    return [PSCustomObject]@{
        Json = $json
    }
}

# --- Single-file mode ---
if ($PdfPath) {
    if (-not (Test-Path -LiteralPath $PdfPath -PathType Leaf)) {
        Write-Error "PDF file not found: $PdfPath"
        exit 1
    }

    $resolvedPdfPath = (Resolve-Path -LiteralPath $PdfPath).Path

    Write-Host "Uploading '$resolvedPdfPath' to $uri (field name: '$FieldName')..." -ForegroundColor Cyan

    $fileStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Invoke-OcrUpload -ResolvedPdfPath $resolvedPdfPath
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
    $fileStopwatch.Stop()
    Write-Host "Processed '$resolvedPdfPath' in $(Format-Duration $fileStopwatch.Elapsed)" -ForegroundColor Cyan

    Write-Output $result.Json

    # --- Resolve where (if anywhere) to save the response ---
    # -OutFile takes precedence over -TargetDir when both are supplied.
    $effectiveOutFile = $null
    if ($OutFile) {
        $effectiveOutFile = $OutFile
    }
    elseif ($TargetDir) {
        if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
        }
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPdfPath)
        $effectiveOutFile = Join-Path -Path $TargetDir -ChildPath "${baseName}_ocr.json"
    }

    if ($effectiveOutFile) {
        try {
            $result.Json | Out-File -LiteralPath $effectiveOutFile -Encoding utf8 -NoNewline
            Write-Host "Response saved to '$effectiveOutFile'" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to write response to '$effectiveOutFile': $($_.Exception.Message)"
            exit 1
        }
    }

    $totalStopwatch.Stop()
    Write-Host "Total elapsed: $(Format-Duration $totalStopwatch.Elapsed)" -ForegroundColor Cyan

    return
}

# --- Batch mode (-SourceDir) ---
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}

$resolvedSourceDir = (Resolve-Path -LiteralPath $SourceDir).Path

# Default output directory is the source directory itself unless -TargetDir overrides it.
$resolvedTargetDir = if ($TargetDir) { $TargetDir } else { $resolvedSourceDir }
if (-not (Test-Path -LiteralPath $resolvedTargetDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $resolvedTargetDir | Out-Null
}

# Non-recursive: only top-level *.pdf files in the source directory are processed.
$pdfFiles = Get-ChildItem -LiteralPath $resolvedSourceDir -Filter "*.pdf" -File

if ($pdfFiles.Count -eq 0) {
    Write-Warning "No .pdf files found in '$resolvedSourceDir'."
    exit 0
}

Write-Host "Found $($pdfFiles.Count) PDF file(s) in '$resolvedSourceDir'. Output directory: '$resolvedTargetDir'" -ForegroundColor Cyan

$succeeded = [System.Collections.Generic.List[PSCustomObject]]::new()
$failed = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($pdfFile in $pdfFiles) {
    $outFilePath = Join-Path -Path $resolvedTargetDir -ChildPath "$([System.IO.Path]::GetFileNameWithoutExtension($pdfFile.Name))_ocr.json"

    Write-Host "Uploading '$($pdfFile.FullName)' to $uri (field name: '$FieldName')..." -ForegroundColor Cyan

    $fileStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Invoke-OcrUpload -ResolvedPdfPath $pdfFile.FullName
        $fileStopwatch.Stop()
        Write-Host "  -> Processed '$($pdfFile.Name)' in $(Format-Duration $fileStopwatch.Elapsed)" -ForegroundColor Cyan
        $result.Json | Out-File -LiteralPath $outFilePath -Encoding utf8 -NoNewline
        Write-Host "  -> Saved to '$outFilePath'" -ForegroundColor Green
        $succeeded.Add([PSCustomObject]@{
                File     = $pdfFile.Name
                Duration = $fileStopwatch.Elapsed
            })
    }
    catch {
        $fileStopwatch.Stop()
        Write-Error "  -> Failed to process '$($pdfFile.Name)': $($_.Exception.Message)" -ErrorAction Continue
        $failed.Add([PSCustomObject]@{
                File  = $pdfFile.Name
                Error = $_.Exception.Message
            })
    }
}

# --- Batch summary ---
$totalStopwatch.Stop()
Write-Host ""
Write-Host "=== Batch summary ===" -ForegroundColor Cyan
Write-Host "Succeeded: $($succeeded.Count) / $($pdfFiles.Count)" -ForegroundColor Green
foreach ($success in $succeeded) {
    Write-Host "  - $($success.File): $(Format-Duration $success.Duration)" -ForegroundColor Green
}
if ($failed.Count -gt 0) {
    Write-Host "Failed: $($failed.Count) / $($pdfFiles.Count)" -ForegroundColor Red
    foreach ($failure in $failed) {
        Write-Host "  - $($failure.File): $($failure.Error)" -ForegroundColor Red
    }
}
Write-Host "Total elapsed: $(Format-Duration $totalStopwatch.Elapsed)" -ForegroundColor Cyan
if ($failed.Count -gt 0) {
    exit 1
}
