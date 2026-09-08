<#
.SYNOPSIS
    Converts a TurboOCR-style OCR JSON output file (as produced by
    ocr-request.ps1) into a readable Markdown file.

.DESCRIPTION
    Reads an OCR JSON file shaped like:

        {
          "pages": [
            {
              "page": 1,
              "results": [ { "id": 0, "text": "...", "layout_id": 14 }, ... ],
              "layout":  [ { "id": 14, "class": "doc_title" }, ... ],
              "tables":  [ { "layout_id": 0, "html": "<html>...</html>" }, ... ]  # optional
            },
            ...
          ]
        }

    This script accepts either of two on-disk shapes for the input JSON:

      - Enveloped (current ocr-request.ps1 output): the object above is
        nested under an "ocr" key, alongside sibling "request" and
        "response" metadata, i.e. { "request": {...}, "response": {...},
        "ocr": { "pages": [...] } }. When an "ocr" property is present at
        the root, its value is used as the effective document.
      - Flat (legacy, pre-envelope ocr-request.ps1 output, or any
        already-generated file predating the envelope change): the "pages"
        array sits directly at the JSON root, as shown above. Used as-is
        when no "ocr" property is present.

    and converts it to Markdown, preserving reading order:

      - Pages are processed in ascending "page" number order.
      - Within a page, "results" entries are already top-to-bottom reading
        order (sequential "id"). Consecutive results that share the same
        "layout_id" are joined (with spaces) into a single block, because
        they are OCR line-fragments of the same paragraph/title/etc. The
        same "layout_id" CAN reappear later in a page as a separate,
        non-contiguous run (observed in real data for large tables split
        into a header run and a body run) -- each contiguous run is treated
        as its own block, not merged with a distant run of the same id.
      - Each block's Markdown treatment is driven by the "class" of the
        layout entry referenced by its "layout_id" (looked up in that
        page's "layout" array):
          * Heading classes ("doc_title", "paragraph_title") become
            "#"/"##" headings.
          * Body classes ("text", "abstract", "content") become plain
            paragraphs.
          * Boilerplate classes ("footer", "number" -- running headers and
            page numbers repeated on every page) are dropped by default;
            use -IncludeBoilerplate to keep them as plain paragraphs.
          * The "table" class is special-cased: many OCR table blocks have
            their "results" text in useless (non-reading-order) per-cell
            order, but the page-level "tables" array (when present) carries
            a proper HTML rendition of the same table, keyed by
            "layout_id". When available, that HTML is embedded verbatim
            (Markdown renderers natively support embedded HTML tables, and
            this preserves colspan/structure that a hand-rolled HTML-to-
            pipe-table converter would lose). If no matching "tables" entry
            exists, the block falls back to its raw joined OCR text so
            nothing is silently dropped.
          * Any other/unrecognized class (e.g. "vision_footnote",
            "SupplementaryRegion" -- both observed in real OCR output) is
            still emitted as a plain paragraph, preceded by an HTML comment
            noting the unrecognized class name, so nothing goes missing
            silently.
      - A lightweight YAML frontmatter block records the source filename
        and generation timestamp.

    The script has two mutually exclusive modes, mirroring ocr-request.ps1:

    Single-file mode (-InputPath): converts one JSON file. By default the
    output is written next to the input file, same base name, ".md"
    extension. Override with -OutFile.

    Batch mode (-SourceDir): converts every top-level *.json file found in
    the given directory (non-recursive, same rationale as ocr-request.ps1's
    batch mode: flat drop folders, simple per-file failure/summary
    semantics). Each file's output defaults to alongside that file unless
    -TargetDir is given. A per-file failure is caught and reported without
    stopping the rest of the batch; a summary prints at the end.

    Exactly one of -InputPath or -SourceDir must be supplied.

.PARAMETER InputPath
    Path to a single OCR JSON file to convert. Mutually exclusive with
    -SourceDir. Exactly one of -InputPath / -SourceDir is required.

.PARAMETER SourceDir
    Path to a directory containing OCR JSON files to convert in batch.
    Every top-level file matching *.json in this directory is converted in
    turn. Mutually exclusive with -InputPath. Exactly one of -InputPath /
    -SourceDir is required.

.PARAMETER OutFile
    Single-file mode only. Explicit output path for the generated Markdown.
    If omitted, defaults to the input JSON's directory and base name with a
    ".md" extension (e.g. "report.json" -> "report.md" in the same folder).
    An existing file at this path is overwritten.

.PARAMETER TargetDir
    Batch mode only. Overrides the default output location for each
    converted file, which is otherwise the same directory as that file's
    source JSON. Each file's output is written as
    "<TargetDir>\<json-base-name>.md". The directory is created if it does
    not already exist.

.PARAMETER IncludePageBreaks
    Switch. When set, inserts an HTML comment marker (e.g. "<!-- page 2 -->")
    at each page boundary in the generated Markdown, for traceability back
    to the source page. Default: off (no visible page breaks), since
    boilerplate footers/page-numbers are already stripped and the text is
    meant to read as one flowing document.

.PARAMETER IncludeBoilerplate
    Switch. When set, blocks classified as boilerplate ("footer", "number")
    are included as plain paragraphs instead of being dropped. Default:
    off. Useful for debugging/auditing what the OCR engine classified as
    boilerplate.

.EXAMPLE
    # Basic usage: writes "minutes.md" next to "minutes.json"
    .\ocr-json-to-markdown.ps1 -InputPath "C:\docs\to-text\minutes.json"

.EXAMPLE
    # Override the output path
    .\ocr-json-to-markdown.ps1 -InputPath "C:\docs\to-text\minutes.json" -OutFile "C:\out\minutes.md"

.EXAMPLE
    # Keep page-boundary markers for traceability
    .\ocr-json-to-markdown.ps1 -InputPath "C:\docs\to-text\minutes.json" -IncludePageBreaks

.EXAMPLE
    # Batch mode: convert every *.json in a folder, writing "<name>.md"
    # alongside each source file
    .\ocr-json-to-markdown.ps1 -SourceDir "C:\docs\to-text"

.EXAMPLE
    # Batch mode with a custom output directory instead of alongside each file
    .\ocr-json-to-markdown.ps1 -SourceDir "C:\docs\to-text" -TargetDir "C:\docs\markdown"

.NOTES
    Requires PowerShell 7+ (pwsh) for ConvertFrom-Json/ConvertTo-Json
    behavior consistent with the rest of this repo's scripts.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath,

    [string]$SourceDir,

    [string]$OutFile,

    [string]$TargetDir,

    [switch]$IncludePageBreaks,

    [switch]$IncludeBoilerplate
)

$ErrorActionPreference = "Stop"

# --- Class-to-Markdown mapping tables (edit here to tune classification) ---

# Heading classes -> Markdown heading level.
$script:HeadingClassLevels = @{
    "doc_title"       = 1
    "paragraph_title" = 2
}

# Recognized body/paragraph classes (rendered as plain paragraphs, no
# diagnostic comment).
$script:BodyClasses = @("text", "abstract", "content")

# Boilerplate classes dropped by default (running headers/footers, page
# numbers repeated on every page). Toggle with -IncludeBoilerplate.
$script:BoilerplateClasses = @("footer", "number")

# Class that receives special HTML-table handling.
$script:TableClass = "table"

# --- Enforce mutually exclusive modes: exactly one of -InputPath / -SourceDir ---
if ($InputPath -and $SourceDir) {
    Write-Error "Specify only one of -InputPath or -SourceDir, not both."
    exit 1
}
if (-not $InputPath -and -not $SourceDir) {
    Write-Error "You must specify either -InputPath (single file) or -SourceDir (batch directory)."
    exit 1
}

function Format-MarkdownParagraphText {
    <#
    .SYNOPSIS
        Joins OCR text fragments into one paragraph string and lightly
        escapes leading sequences that Markdown would otherwise interpret
        as block-level syntax (heading, list, blockquote).

    .PARAMETER Fragments
        Array of OCR text strings (one per "results" entry) belonging to
        the same block, already in reading order.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Fragments
    )

    $joined = (($Fragments | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }) -join " ").Trim()

    # Defensively escape a leading token that Markdown would otherwise treat
    # as block syntax (#, -, *, +, >, or "1." style ordered-list markers).
    if ($joined -match '^(#+|[-*+]|>|\d+\.)(\s|$)') {
        $joined = "\" + $joined
    }

    return $joined
}

function Get-ResultRuns {
    <#
    .SYNOPSIS
        Groups a page's "results" array into contiguous runs sharing the
        same layout_id, in reading order.

    .DESCRIPTION
        The same layout_id can legitimately reappear later in a page as a
        separate, non-contiguous run (observed in real OCR output for large
        tables split into a header run and a body run). Grouping is
        therefore by contiguous run of matching layout_id, not by
        collecting every result with a given layout_id across the page.

    .PARAMETER Results
        The page's "results" array, expected in ascending "id" order.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $runs = [System.Collections.Generic.List[object]]::new()
    $currentRun = $null

    foreach ($result in ($Results | Sort-Object -Property id)) {
        if ($null -ne $currentRun -and $currentRun.LayoutId -eq $result.layout_id) {
            [void]$currentRun.Texts.Add($result.text)
        }
        else {
            if ($null -ne $currentRun) { $runs.Add($currentRun) }
            $currentRun = [PSCustomObject]@{
                LayoutId = $result.layout_id
                Texts    = [System.Collections.Generic.List[string]]::new()
            }
            [void]$currentRun.Texts.Add($result.text)
        }
    }
    if ($null -ne $currentRun) { $runs.Add($currentRun) }

    return $runs
}

function Convert-OcrJsonToMarkdown {
    <#
    .SYNOPSIS
        Converts one parsed OCR JSON document into a Markdown string.

    .PARAMETER OcrData
        The parsed OCR JSON object (must have a "pages" array).

    .PARAMETER SourceFileName
        Filename recorded in the generated frontmatter.

    .PARAMETER IncludePageBreaks
        Whether to emit "<!-- page N -->" markers between pages.

    .PARAMETER IncludeBoilerplate
        Whether to include footer/number-class blocks instead of dropping
        them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$OcrData,

        [Parameter(Mandatory = $true)]
        [string]$SourceFileName,

        [bool]$IncludePageBreaks = $false,

        [bool]$IncludeBoilerplate = $false
    )

    if (-not (Get-Member -InputObject $OcrData -Name "pages" -MemberType Properties) -or $null -eq $OcrData.pages) {
        throw "Input JSON does not contain a 'pages' array -- unexpected OCR output shape."
    }

    $pages = @($OcrData.pages | Sort-Object -Property page)

    $blocks = [System.Collections.Generic.List[string]]::new()

    $generatedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $blocks.Add("---`nsource: $SourceFileName`ngenerated: $generatedAt`ngenerator: ocr-json-to-markdown.ps1`n---")

    $isFirstPage = $true
    foreach ($page in $pages) {
        if ($IncludePageBreaks -and -not $isFirstPage) {
            $blocks.Add("<!-- page $($page.page) -->")
        }
        $isFirstPage = $false

        # Map layout id -> layout entry (class, etc.) for this page.
        $layoutById = @{}
        foreach ($layoutEntry in @($page.layout)) {
            if ($null -ne $layoutEntry) { $layoutById[[int]$layoutEntry.id] = $layoutEntry }
        }

        # Map layout id -> queue of not-yet-consumed table HTML strings for
        # this page (a queue, not a single value, in case more than one
        # "tables" entry ever shares a layout_id).
        $tableHtmlById = @{}
        if (Get-Member -InputObject $page -Name "tables" -MemberType Properties) {
            foreach ($tableEntry in @($page.tables)) {
                if ($null -eq $tableEntry) { continue }
                $lid = [int]$tableEntry.layout_id
                if (-not $tableHtmlById.ContainsKey($lid)) {
                    $tableHtmlById[$lid] = [System.Collections.Generic.Queue[string]]::new()
                }
                $tableHtmlById[$lid].Enqueue($tableEntry.html)
            }
        }
        $consumedTableIds = @{}

        $runs = Get-ResultRuns -Results @($page.results)

        foreach ($run in $runs) {
            # Cast once to Int32 here so every hashtable lookup below (layout,
            # table HTML, consumed-table tracking) uses a consistent key type
            # -- JSON numeric deserialization yields Int64, and an Int64 key
            # does NOT match an Int32 key of equal value in a Hashtable.
            $layoutId = [int]$run.LayoutId
            $layoutEntry = $layoutById[$layoutId]
            $class = if ($null -ne $layoutEntry) { $layoutEntry.class } else { $null }

            if ($null -eq $class) {
                # Orphan layout_id: no matching layout entry on this page.
                $text = Format-MarkdownParagraphText -Fragments $run.Texts
                if ($text -ne "") {
                    $blocks.Add("<!-- unrecognized layout: no layout entry found for layout_id $layoutId -->`n$text")
                }
                continue
            }

            if ($script:HeadingClassLevels.ContainsKey($class)) {
                $level = $script:HeadingClassLevels[$class]
                $text = Format-MarkdownParagraphText -Fragments $run.Texts
                if ($text -ne "") {
                    $blocks.Add(("#" * $level) + " " + $text)
                }
            }
            elseif ($class -eq $script:TableClass) {
                if ($tableHtmlById.ContainsKey($layoutId) -and $tableHtmlById[$layoutId].Count -gt 0) {
                    $html = $tableHtmlById[$layoutId].Dequeue()
                    $consumedTableIds[$layoutId] = $true
                    $blocks.Add($html)
                }
                elseif ($consumedTableIds.ContainsKey($layoutId)) {
                    # A later, non-contiguous run of the same table's
                    # layout_id (e.g. the body rows following a header
                    # run) -- its HTML was already emitted once above.
                    continue
                }
                else {
                    # No page-level "tables" HTML available for this table
                    # block -- fall back to raw OCR text rather than
                    # silently dropping it.
                    $text = Format-MarkdownParagraphText -Fragments $run.Texts
                    if ($text -ne "") {
                        $blocks.Add("<!-- table structure unavailable for layout_id $layoutId; showing raw OCR text -->`n$text")
                    }
                }
            }
            elseif ($script:BoilerplateClasses -contains $class) {
                if ($IncludeBoilerplate) {
                    $text = Format-MarkdownParagraphText -Fragments $run.Texts
                    if ($text -ne "") { $blocks.Add($text) }
                }
                # else: dropped by design (running header/footer/page number)
            }
            elseif ($script:BodyClasses -contains $class) {
                $text = Format-MarkdownParagraphText -Fragments $run.Texts
                if ($text -ne "") { $blocks.Add($text) }
            }
            else {
                # Unrecognized class: never drop silently.
                $text = Format-MarkdownParagraphText -Fragments $run.Texts
                if ($text -ne "") {
                    $blocks.Add("<!-- unrecognized layout class '$class' (layout_id $layoutId) -->`n$text")
                }
            }
        }
    }

    return ($blocks -join "`n`n") + "`n"
}

function Convert-OcrJsonFile {
    <#
    .SYNOPSIS
        Reads one OCR JSON file from disk, converts it, and writes the
        resulting Markdown to the given output path.

    .PARAMETER ResolvedJsonPath
        Fully resolved, existing path to the input JSON file.

    .PARAMETER ResolvedOutFile
        Path to write the generated Markdown file to. Overwritten if it
        already exists.

    .PARAMETER IncludePageBreaks
        Whether to emit "<!-- page N -->" markers between pages.

    .PARAMETER IncludeBoilerplate
        Whether to include footer/number-class blocks instead of dropping
        them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedJsonPath,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedOutFile,

        [bool]$IncludePageBreaks = $false,

        [bool]$IncludeBoilerplate = $false
    )

    $rawJson = Get-Content -LiteralPath $ResolvedJsonPath -Raw -Encoding utf8

    try {
        $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse '$ResolvedJsonPath' as JSON: $($_.Exception.Message)"
    }

    # Transparently unwrap the enveloped shape ({ request, response, ocr })
    # produced by the current ocr-request.ps1, while remaining backward
    # compatible with flat-format files (the "pages" array at the JSON
    # root) that predate the envelope change.
    $ocrData = if (Get-Member -InputObject $parsed -Name "ocr" -MemberType Properties) {
        $parsed.ocr
    }
    else {
        $parsed
    }

    $markdown = Convert-OcrJsonToMarkdown -OcrData $ocrData -SourceFileName (Split-Path -Leaf $ResolvedJsonPath) `
        -IncludePageBreaks $IncludePageBreaks -IncludeBoilerplate $IncludeBoilerplate

    $outDir = Split-Path -Parent $ResolvedOutFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    $markdown | Out-File -LiteralPath $ResolvedOutFile -Encoding utf8 -NoNewline
}

# --- Single-file mode ---
if ($InputPath) {
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        Write-Error "Input JSON file not found: $InputPath"
        exit 1
    }

    $resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path

    $effectiveOutFile = if ($OutFile) {
        $OutFile
    }
    else {
        Join-Path -Path (Split-Path -Parent $resolvedInputPath) `
            -ChildPath ("$([System.IO.Path]::GetFileNameWithoutExtension($resolvedInputPath)).md")
    }

    Write-Host "Converting '$resolvedInputPath' -> '$effectiveOutFile'..." -ForegroundColor Cyan

    try {
        Convert-OcrJsonFile -ResolvedJsonPath $resolvedInputPath -ResolvedOutFile $effectiveOutFile `
            -IncludePageBreaks:$IncludePageBreaks.IsPresent -IncludeBoilerplate:$IncludeBoilerplate.IsPresent
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }

    Write-Host "Markdown saved to '$effectiveOutFile'" -ForegroundColor Green
    return
}

# --- Batch mode (-SourceDir) ---
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}

$resolvedSourceDir = (Resolve-Path -LiteralPath $SourceDir).Path

# Non-recursive: only top-level *.json files in the source directory are processed.
$jsonFiles = Get-ChildItem -LiteralPath $resolvedSourceDir -Filter "*.json" -File

if ($jsonFiles.Count -eq 0) {
    Write-Warning "No .json files found in '$resolvedSourceDir'."
    exit 0
}

Write-Host "Found $($jsonFiles.Count) JSON file(s) in '$resolvedSourceDir'." -ForegroundColor Cyan

$succeeded = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($jsonFile in $jsonFiles) {
    # Default: alongside each source file, unless -TargetDir overrides it.
    $destDir = if ($TargetDir) { $TargetDir } else { $jsonFile.DirectoryName }
    $outFilePath = Join-Path -Path $destDir -ChildPath "$([System.IO.Path]::GetFileNameWithoutExtension($jsonFile.Name)).md"

    Write-Host "Converting '$($jsonFile.FullName)' -> '$outFilePath'..." -ForegroundColor Cyan

    try {
        Convert-OcrJsonFile -ResolvedJsonPath $jsonFile.FullName -ResolvedOutFile $outFilePath `
            -IncludePageBreaks:$IncludePageBreaks.IsPresent -IncludeBoilerplate:$IncludeBoilerplate.IsPresent
        Write-Host "  -> Saved to '$outFilePath'" -ForegroundColor Green
        $succeeded.Add($jsonFile.Name)
    }
    catch {
        Write-Error "  -> Failed to process '$($jsonFile.Name)': $($_.Exception.Message)" -ErrorAction Continue
        $failed.Add([PSCustomObject]@{
                File  = $jsonFile.Name
                Error = $_.Exception.Message
            })
    }
}

# --- Batch summary ---
Write-Host ""
Write-Host "=== Batch summary ===" -ForegroundColor Cyan
Write-Host "Succeeded: $($succeeded.Count) / $($jsonFiles.Count)" -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host "Failed: $($failed.Count) / $($jsonFiles.Count)" -ForegroundColor Red
    foreach ($failure in $failed) {
        Write-Host "  - $($failure.File): $($failure.Error)" -ForegroundColor Red
    }
    exit 1
}
