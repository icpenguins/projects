#Requires -Version 7.0
<#
.SYNOPSIS
    Defines New-GrokVoice, which converts a text file to speech with the xAI
    (Grok) text-to-speech API and writes the audio to a file.

.DESCRIPTION
    Minimal wrapper around POST https://api.x.ai/v1/tts. The function takes
    two required arguments, the text file to read and the audio file to write,
    plus two optional switches: -VoiceId (default "eve") and
    -CredentialTarget (default "localAgentKey").

    Load the function into your session by dot-sourcing this file:

        . .\New-GrokVoice.ps1
        New-GrokVoice .\notes.txt .\notes.mp3

    Running the file directly with the arguments also works:

        .\New-GrokVoice.ps1 .\notes.txt .\notes.mp3 -VoiceId ara

    The API key is read from Windows Credential Manager at run time with the
    CredentialManager module from the PowerShell Gallery (installed for the
    current user on first use if missing). It is never placed in an
    environment variable, a file, the command line, or output. The key stays
    a SecureString and is handed to Invoke-WebRequest through
    -Authentication Bearer -Token, so it is never interpolated into a plain
    string header that could end up in an error message or a transcript.

    One-time setup (the /pass switch with no value prompts for the secret
    without echo, so the key never appears in shell history):

        cmdkey /generic:localAgentKey /user:xai /pass

    The output codec is chosen from the output path's extension:
    .mp3 (default bit rate), .wav, or .pcm. The language is a fixed constant
    inside the function. The endpoint accepts up to 60,000 characters of text
    per call.

.PARAMETER TextFile
    Path to a UTF-8 text file whose contents will be spoken.

.PARAMETER OutFile
    Path of the audio file to write. The extension selects the codec.

.PARAMETER VoiceId
    Built-in xAI voice name (for example eve, ara) or a custom voice ID.
    Defaults to "eve".

.PARAMETER CredentialTarget
    Name of the generic credential in Windows Credential Manager that holds
    the API key. Defaults to "localAgentKey".
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialTarget',
    Justification = 'Holds the Credential Manager target name, not a secret.')]
param(
    [Parameter(Position = 0)]
    [string]$TextFile,

    [Parameter(Position = 1)]
    [string]$OutFile,

    [Parameter()]
    [string]$VoiceId = 'eve',

    [Parameter()]
    [string]$CredentialTarget = 'localAgentKey'
)

function New-GrokVoice {
    <#
    .SYNOPSIS
        Converts a text file to speech with the xAI (Grok) API and writes the
        audio to a file. The API key is read from Windows Credential Manager
        (target name "localAgentKey" unless -CredentialTarget is given).

    .PARAMETER TextFile
        Path to a UTF-8 text file whose contents will be spoken.

    .PARAMETER OutFile
        Path of the audio file to write. The extension (.mp3, .wav, .pcm)
        selects the codec.

    .PARAMETER VoiceId
        Built-in xAI voice name (for example eve, ara) or a custom voice ID.
        Defaults to "eve".

    .PARAMETER CredentialTarget
        Name of the generic credential in Windows Credential Manager that
        holds the API key. Defaults to "localAgentKey".

    .EXAMPLE
        New-GrokVoice .\notes.txt .\notes.mp3

    .EXAMPLE
        New-GrokVoice -TextFile script.txt -OutFile script.wav

    .EXAMPLE
        New-GrokVoice .\notes.txt .\notes.mp3 -VoiceId ara -CredentialTarget grok-voice
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialTarget',
        Justification = 'Holds the Credential Manager target name, not a secret.')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$TextFile,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutFile,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$VoiceId = 'eve',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$CredentialTarget = 'localAgentKey'
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # ---- Constants ---------------------------------------------------------
    $TtsUri       = 'https://api.x.ai/v1/tts'
    $Language     = 'en'                    # BCP-47 code, or 'auto'
    $MaxTextChars = 60000

    # ---- Validate input ----------------------------------------------------
    if (-not (Test-Path -LiteralPath $TextFile -PathType Leaf)) {
        throw "Text file not found: $TextFile"
    }
    $textFull = (Resolve-Path -LiteralPath $TextFile).Path

    $text = [System.IO.File]::ReadAllText($textFull, [System.Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Text file is empty: $TextFile"
    }
    if ($text.Length -gt $MaxTextChars) {
        throw "Text is $($text.Length) characters; the endpoint accepts at most $MaxTextChars."
    }

    $codec = switch ([System.IO.Path]::GetExtension($OutFile).ToLowerInvariant()) {
        '.mp3'  { 'mp3' }
        '.wav'  { 'wav' }
        '.pcm'  { 'pcm' }
        default { throw "Output extension must be .mp3, .wav, or .pcm: $OutFile" }
    }

    $outFull = if ([System.IO.Path]::IsPathRooted($OutFile)) {
        [System.IO.Path]::GetFullPath($OutFile)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutFile))
    }
    $outDir = [System.IO.Path]::GetDirectoryName($outFull)
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    # ---- Read the key from Credential Manager ------------------------------
    if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
        Install-Module -Name CredentialManager -Scope CurrentUser -Force
    }
    Import-Module CredentialManager -ErrorAction Stop

    $stored = Get-StoredCredential -Target $CredentialTarget
    if ($null -eq $stored -or $null -eq $stored.Password -or $stored.Password.Length -eq 0) {
        throw "No credential named '$CredentialTarget' in Windows Credential Manager. Create it with:  cmdkey /generic:$CredentialTarget /user:xai /pass"
    }
    $apiKey = $stored.Password   # SecureString; never converted to plain text here

    # ---- Call the speech endpoint -----------------------------------------
    $body = @{
        text          = $text
        voice_id      = $VoiceId
        language      = $Language
        output_format = @{ codec = $codec }
    } | ConvertTo-Json -Compress -Depth 4

    try {
        $response = Invoke-WebRequest -Uri $TtsUri -Method Post `
            -Authentication Bearer -Token $apiKey `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -OutFile $outFull -PassThru
    }
    catch {
        # Surface the status and the server's error body; neither contains the key.
        $status = $null
        $detail = $_.Exception.Message
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force -ErrorAction SilentlyContinue }
        $suffix = if ($status) { " (HTTP $status)" } else { '' }
        throw "Text-to-speech request failed${suffix}: $detail"
    }
    finally {
        if ($apiKey) { $apiKey.Dispose() }
        $stored = $null
    }

    $contentType = [string]$response.Headers['Content-Type']
    if ($contentType -notmatch '^audio/') {
        $preview = ''
        try {
            $raw = Get-Content -LiteralPath $outFull -Raw -ErrorAction Stop
            $preview = $raw.Substring(0, [Math]::Min(300, $raw.Length))
        } catch {}
        Remove-Item -LiteralPath $outFull -Force -ErrorAction SilentlyContinue
        throw "Expected an audio response but got '$contentType'. $preview"
    }

    $bytes = (Get-Item -LiteralPath $outFull).Length
    Write-Output "Wrote $outFull ($bytes bytes, $contentType)"
}

# When the file is executed directly (not dot-sourced), run the function with
# the supplied arguments. When dot-sourced, only define the function.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $TextFile -or -not $OutFile) {
        throw "Usage: New-GrokVoice.ps1 <TextFile> <OutFile> [-VoiceId <id>] [-CredentialTarget <name>]   (or dot-source the file and call New-GrokVoice)"
    }
    New-GrokVoice -TextFile $TextFile -OutFile $OutFile -VoiceId $VoiceId -CredentialTarget $CredentialTarget
}
