<#
.SYNOPSIS
    Generic client for a local OCR HTTP API. Uploads a PDF as multipart/form-data
    to POST {BaseUrl}/ocr/raw and prints/saves the JSON response.

.DESCRIPTION
    Calls a local OCR service (default: http://localhost:8000) at the /ocr/raw
    endpoint, uploading the given PDF file as multipart/form-data. Query params
    (layout, tables, formulas) and the base URL are all configurable. The form
    field name used for the file upload defaults to "file" but can be changed
    with -FieldName if the API expects a different field name.

.PARAMETER PdfPath
    Path to the PDF file to upload. Required.

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
    Optional path to save the raw JSON response to disk. If omitted, the
    response is only printed to stdout.

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

.NOTES
    Requires PowerShell 7+ (pwsh) for Invoke-WebRequest -Form multipart support.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$PdfPath,

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

# --- Validate the PDF file exists before doing any network work ---
if (-not (Test-Path -LiteralPath $PdfPath -PathType Leaf)) {
    Write-Error "PDF file not found: $PdfPath"
    exit 1
}

$resolvedPdfPath = (Resolve-Path -LiteralPath $PdfPath).Path

# --- Build the target URI ---
$endpoint = "$($BaseUrl.TrimEnd('/'))/$($EndpointPath.TrimStart('/'))"
$queryString = "layout=$Layout&tables=$Tables&formulas=$Formulas"
$uri = "$endpoint`?$queryString"

Write-Host "Uploading '$resolvedPdfPath' to $uri (field name: '$FieldName')..." -ForegroundColor Cyan

# --- Build multipart form ---
$form = @{
    $FieldName = Get-Item -LiteralPath $resolvedPdfPath
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
        Write-Error "OCR API at '$uri' returned HTTP $statusCode. Response body: $body"
        exit 1
    }

    # Case 2: A local file-access problem (e.g. the PDF is locked by another
    # process, such as OneDrive syncing or another program having it open),
    # not a server connectivity issue.
    if ($ex -is [System.IO.IOException] -or $ex.InnerException -is [System.IO.IOException]) {
        Write-Error "Could not read the PDF file '$resolvedPdfPath'. It may be open/locked by another process (e.g. OneDrive, another OCR job, a PDF viewer). Details: $($ex.Message)"
        exit 1
    }

    # Case 3: Genuine network unreachability (connection refused, DNS
    # failure, timeout, etc.)
    Write-Error "Could not reach OCR API at '$BaseUrl'. Is the server running? Details: $($ex.Message)"
    exit 1
}

$rawJson = $response.Content

# --- Print the response ---
try {
    $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    $prettyJson = $parsed | ConvertTo-Json -Depth 50
    Write-Output $prettyJson
}
catch {
    # If it isn't valid JSON for some reason, just print the raw body
    Write-Output $rawJson
}

# --- Optionally save the raw response to disk ---
if ($OutFile) {
    try {
        $rawJson | Out-File -LiteralPath $OutFile -Encoding utf8 -NoNewline
        Write-Host "Response saved to '$OutFile'" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to write response to '$OutFile': $($_.Exception.Message)"
        exit 1
    }
}
