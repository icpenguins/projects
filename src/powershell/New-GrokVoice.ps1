#Requires -Version 7.0
<#
.SYNOPSIS
    Defines New-GrokVoice, which converts text to speech with the xAI (Grok)
    text-to-speech API (POST https://api.x.ai/v1/tts) and writes the audio to
    a file.

.DESCRIPTION
    This file only defines the function. Load it into your session with
    Import-Module or by dot-sourcing, then call New-GrokVoice:

        Import-Module .\New-GrokVoice.ps1
        New-GrokVoice .\notes.txt .\notes.mp3 -VoiceId ara -Speed 1.1

    The API key is read at run time from a PowerShell SecretManagement vault
    (Microsoft.PowerShell.SecretManagement, backed by the
    Microsoft.PowerShell.SecretStore vault). It is never placed in an
    environment variable, a file, the command line, or output. Get-Secret
    returns it as a SecureString, which is handed to Invoke-WebRequest
    through -Authentication Bearer -Token, so it is never interpolated into a
    plain string header that could end up in an error message or a
    transcript.

    Register the local SecretStore vault and set it as the default:

        Register-SecretVault -ModuleName Microsoft.PowerShell.SecretStore -Name LocalStore -DefaultVault
        Reset-SecretStore -Authentication None -Interaction None -Force

        Set-SecretVaultDefault -Name LocalStore

    One-time setup with the companion Set-StoredSecret.ps1 (registers the
    SecretStore vault if needed and prompts for the key without echo):

        . .\Set-StoredSecret.ps1
        Set-StoredSecret -Name localAgentKey

    SecretStore asks for a store password the first time it is used and
    locks again after a timeout. For unattended use either run
    Unlock-SecretStore first, or configure the store once with
    Set-SecretStoreConfiguration -Authentication None.

    Text may contain xAI speech tags. Inline tags: [pause] [long-pause]
    [laugh] [cry] [sniff] [gasp] [sigh] [clear-throat]. Wrapping tags:
    <loud> <soft> <whisper> <fast> <slow> <high-pitch> <low-pitch> <singing>
    <robot>, e.g. "I walked in and [pause] <whisper>there it was</whisper>."

.PARAMETER TextFile
    Path to a UTF-8 text file whose contents will be spoken (File parameter
    set, the default). At most 60,000 characters.

.PARAMETER Text
    The text to speak, given directly instead of a file (Text parameter set).
    At most 60,000 characters.

.PARAMETER OutFile
    Path of the audio file to write. Unless -Codec is given, the extension
    selects the codec: .mp3, .wav, .pcm/.raw, .ulaw/.mulaw, .alaw.

.PARAMETER VoiceId
    Built-in xAI voice name (eve, ara, rex, ...) or a custom voice ID.
    Case-insensitive. Defaults to "eve".

.PARAMETER Language
    BCP-47 language code or "auto" for detection. Defaults to "en".
    Documented codes: auto, en, ar-EG, ar-SA, ar-AE, bn, zh, fr, de, hi, id,
    it, ja, ko, pt-BR, pt-PT, ru, es-MX, es-ES, tr, vi.

.PARAMETER Speed
    Speech rate multiplier from 0.7 to 1.5. Defaults to 1.0.

.PARAMETER Codec
    Output codec: mp3, wav, pcm, mulaw, alaw. Overrides the extension of
    -OutFile.

.PARAMETER SampleRate
    Output sample rate in Hz: 8000, 16000, 22050, 24000, 44100, 48000.
    Defaults to the service default (24000).

.PARAMETER BitRate
    MP3 bit rate in bps: 32000, 64000, 96000, 128000, 192000. Only valid with
    the mp3 codec. Defaults to the service default (128000).

.PARAMETER TextNormalization
    Ask the service to expand written forms (numbers, abbreviations, dates)
    into their spoken form before synthesis.

.PARAMETER Replace
    Hashtable mapping phrases to pronunciations, applied before synthesis.
    Values may be respellings or IPA, e.g. @{ 'xAI' = 'ex A I'; 'nginx' =
    '/ˈɛndʒɪn ˈɛks/' }. Matching is case-insensitive on whole words. At most
    200 entries; keys up to 100 characters, values up to 128.

.PARAMETER WithTimestamps
    Also request character-level timing. The audio is still written to
    -OutFile; the timing data (duration, graph_chars, graph_times) is written
    as JSON next to it with the extension .timestamps.json.

.PARAMETER SecretName
    Name of the secret in the SecretManagement vault that holds the API key.
    Defaults to "localAgentKey".

.PARAMETER Vault
    Name of the registered SecretManagement vault to read from. When omitted,
    every registered vault is searched (the default vault first).

.PARAMETER Force
    Overwrite -OutFile (and the timestamps sidecar) if it already exists.

.OUTPUTS
    System.IO.FileInfo for the audio file written.

.EXAMPLE
    New-GrokVoice .\notes.txt .\notes.mp3

.EXAMPLE
    New-GrokVoice -Text 'Build finished. [pause] All tests passed.' -OutFile .\done.wav -VoiceId rex

.EXAMPLE
    New-GrokVoice .\script.txt .\script.mp3 -Language es-MX -Speed 0.9 -BitRate 192000 -TextNormalization

.EXAMPLE
    New-GrokVoice .\ivr.txt .\ivr.ulaw -SampleRate 8000 -Replace @{ 'SQL' = 'sequel' } -Force

.EXAMPLE
    New-GrokVoice .\notes.txt .\notes.mp3 -WithTimestamps -WhatIf
#>

function New-GrokVoice {
    <#
    .SYNOPSIS
        Converts text to speech with the xAI (Grok) API and writes the audio
        to a file. The API key is read from a PowerShell SecretManagement
        vault (secret name "localAgentKey" unless -SecretName is given).

    .DESCRIPTION
        Wraps POST https://api.x.ai/v1/tts. Text comes from -TextFile (the
        default parameter set) or -Text. The codec is taken from -Codec or,
        failing that, from the -OutFile extension (.mp3, .wav, .pcm/.raw,
        .ulaw/.mulaw, .alaw). See the file-level help for speech tags and
        full parameter descriptions.

    .PARAMETER TextFile
        Path to a UTF-8 text file whose contents will be spoken.

    .PARAMETER Text
        The text to speak, given directly instead of a file.

    .PARAMETER OutFile
        Path of the audio file to write.

    .PARAMETER VoiceId
        Built-in xAI voice name or custom voice ID. Defaults to "eve".

    .PARAMETER Language
        BCP-47 code or "auto". Defaults to "en".

    .PARAMETER Speed
        Speech rate multiplier, 0.7 to 1.5. Defaults to 1.0.

    .PARAMETER Codec
        mp3, wav, pcm, mulaw, or alaw. Overrides the -OutFile extension.

    .PARAMETER SampleRate
        8000, 16000, 22050, 24000, 44100, or 48000 Hz.

    .PARAMETER BitRate
        32000, 64000, 96000, 128000, or 192000 bps. MP3 only.

    .PARAMETER TextNormalization
        Expand numbers and abbreviations to spoken form.

    .PARAMETER Replace
        Hashtable of phrase-to-pronunciation substitutions (max 200).

    .PARAMETER WithTimestamps
        Also write character timing JSON next to the audio file.

    .PARAMETER SecretName
        Vault secret holding the key. Defaults to "localAgentKey".

    .PARAMETER Vault
        Registered vault to read from. Omit to search all registered vaults.

    .PARAMETER Force
        Overwrite existing output files.

    .OUTPUTS
        System.IO.FileInfo for the audio file written.

    .EXAMPLE
        New-GrokVoice .\notes.txt .\notes.mp3

    .EXAMPLE
        New-GrokVoice -Text 'Hello [pause] world.' -OutFile hi.wav -VoiceId ara -Speed 1.2
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'File')]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'File', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$TextFile,

        [Parameter(Mandatory = $true, ParameterSetName = 'Text')]
        [ValidateNotNullOrEmpty()]
        [string]$Text,

        [Parameter(Mandatory = $true, ParameterSetName = 'File', Position = 1)]
        [Parameter(Mandatory = $true, ParameterSetName = 'Text', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$OutFile,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$VoiceId = 'eve',

        [Parameter()]
        [ValidatePattern('^(auto|[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*)$')]
        [string]$Language = 'en',

        [Parameter()]
        [ValidateRange(0.7, 1.5)]
        [double]$Speed = 1.0,

        [Parameter()]
        [ValidateSet('mp3', 'wav', 'pcm', 'mulaw', 'alaw')]
        [string]$Codec,

        [Parameter()]
        [ValidateSet(8000, 16000, 22050, 24000, 44100, 48000)]
        [int]$SampleRate,

        [Parameter()]
        [ValidateSet(32000, 64000, 96000, 128000, 192000)]
        [int]$BitRate,

        [Parameter()]
        [switch]$TextNormalization,

        [Parameter()]
        [hashtable]$Replace,

        [Parameter()]
        [switch]$WithTimestamps,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SecretName = 'localAgentKey',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Vault = 'LocalStore',

        [Parameter()]
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # ---- Constants (from https://docs.x.ai/developers/model-capabilities/audio/text-to-speech)
    $TtsUri             = 'https://api.x.ai/v1/tts'
    $MaxTextChars       = 60000     # per unary request
    $MaxReplaceEntries  = 200
    $MaxReplaceKeyLen   = 100
    $MaxReplaceValueLen = 128
    $TimeoutSec         = 900       # the unary endpoint times out at 15 minutes
    $ExtensionCodecs    = @{
        '.mp3' = 'mp3'; '.wav' = 'wav'; '.pcm' = 'pcm'; '.raw' = 'pcm'
        '.ulaw' = 'mulaw'; '.mulaw' = 'mulaw'; '.alaw' = 'alaw'
    }

    # ---- Resolve the text --------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        if (-not (Test-Path -LiteralPath $TextFile -PathType Leaf)) {
            throw "Text file not found: $TextFile"
        }
        $textFull = (Resolve-Path -LiteralPath $TextFile).Path
        $speech = [System.IO.File]::ReadAllText($textFull, [System.Text.Encoding]::UTF8).Trim()
        $source = $textFull
    }
    else {
        $speech = $Text.Trim()
        $source = '-Text'
    }
    if ([string]::IsNullOrWhiteSpace($speech)) {
        throw "No text to speak (source: $source)."
    }
    if ($speech.Length -gt $MaxTextChars) {
        throw "Text is $($speech.Length) characters; the endpoint accepts at most $MaxTextChars per request."
    }

    # ---- Resolve output format --------------------------------------------
    if (-not $Codec) {
        $ext = [System.IO.Path]::GetExtension($OutFile).ToLowerInvariant()
        if (-not $ExtensionCodecs.ContainsKey($ext)) {
            throw "Cannot infer a codec from extension '$ext'. Use .mp3, .wav, .pcm, .raw, .ulaw, .mulaw or .alaw, or pass -Codec."
        }
        $Codec = $ExtensionCodecs[$ext]
    }
    if ($BitRate -and $Codec -ne 'mp3') {
        throw "-BitRate applies only to the mp3 codec (requested codec: $Codec)."
    }

    $outputFormat = [ordered]@{ codec = $Codec }
    if ($SampleRate) { $outputFormat.sample_rate = $SampleRate }
    if ($BitRate)    { $outputFormat.bit_rate    = $BitRate }

    # ---- Validate the replace map -----------------------------------------
    if ($Replace) {
        if ($Replace.Count -gt $MaxReplaceEntries) {
            throw "-Replace has $($Replace.Count) entries; the limit is $MaxReplaceEntries."
        }
        foreach ($entry in $Replace.GetEnumerator()) {
            $k = [string]$entry.Key
            $v = [string]$entry.Value
            if ([string]::IsNullOrWhiteSpace($k) -or $k.Length -gt $MaxReplaceKeyLen) {
                throw "-Replace key '$k' must be 1 to $MaxReplaceKeyLen characters."
            }
            if ([string]::IsNullOrWhiteSpace($v) -or $v.Length -gt $MaxReplaceValueLen) {
                throw "-Replace value for '$k' must be 1 to $MaxReplaceValueLen characters."
            }
        }
    }

    # ---- Resolve output paths ---------------------------------------------
    $outFull = if ([System.IO.Path]::IsPathRooted($OutFile)) {
        [System.IO.Path]::GetFullPath($OutFile)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutFile))
    }
    $timestampsFull = if ($WithTimestamps) { [System.IO.Path]::ChangeExtension($outFull, '.timestamps.json') } else { $null }

    foreach ($p in @($outFull, $timestampsFull) | Where-Object { $_ }) {
        if ((Test-Path -LiteralPath $p) -and -not $Force) {
            throw "Output file already exists: $p (use -Force to overwrite)."
        }
    }
    $outDir = [System.IO.Path]::GetDirectoryName($outFull)
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($outDir, 'Create directory')) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
    }

    # ---- Build the request body -------------------------------------------
    $body = [ordered]@{
        text          = $speech
        voice_id      = $VoiceId
        language      = $Language
        output_format = $outputFormat
    }
    if ($Speed -ne 1.0)      { $body.speed              = $Speed }
    if ($TextNormalization)  { $body.text_normalization = $true }
    if ($WithTimestamps)     { $body.with_timestamps    = $true }
    if ($Replace)            { $body.replace            = $Replace }
    $json = $body | ConvertTo-Json -Compress -Depth 5

    $action = "Synthesize $($speech.Length) characters with voice '$VoiceId' ($Language, $Codec) via $TtsUri"
    if (-not $PSCmdlet.ShouldProcess($outFull, $action)) {
        return
    }

    # ---- Read the key from the SecretManagement vault ----------------------
    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)) {
        Install-Module -Name Microsoft.PowerShell.SecretManagement -Scope CurrentUser -Force
    }
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop

    if (-not (Get-SecretVault)) {
        throw "No SecretManagement vault is registered. Run Set-StoredSecret -Name $SecretName (from Set-StoredSecret.ps1) to register the SecretStore vault and store the key."
    }
    $lookup = @{ Name = $SecretName }
    if ($Vault) { $lookup.Vault = $Vault }

    $where = if ($Vault) { "vault '$Vault'" } else { 'any registered vault' }
    if (-not (Get-SecretInfo @lookup -ErrorAction SilentlyContinue)) {
        throw "No secret named '$SecretName' in $where. Store it with:  Set-StoredSecret -Name $SecretName"
    }
    try {
        $stored = Get-Secret @lookup -ErrorAction Stop
    }
    catch {
        # Typically the SecretStore is locked; the message says how to unlock it.
        throw "Could not read secret '$SecretName' from $where. $($_.Exception.Message)"
    }

    $apiKey = switch ($stored) {
        { $_ -is [securestring] }  { $_ }
        { $_ -is [pscredential] }  { $_.Password }
        default { throw "Secret '$SecretName' is a $($_.GetType().Name); it must be stored as a string (SecureString) or PSCredential." }
    }
    if ($apiKey.Length -eq 0) {
        throw "Secret '$SecretName' is empty."
    }
    # $apiKey is a SecureString and is never converted to plain text here.

    # ---- Call the speech endpoint -----------------------------------------
    $request = @{
        Uri            = $TtsUri
        Method         = 'Post'
        Authentication = 'Bearer'
        Token          = $apiKey
        ContentType    = 'application/json; charset=utf-8'
        Body           = [System.Text.Encoding]::UTF8.GetBytes($json)
        TimeoutSec     = $TimeoutSec
    }

    try {
        if ($WithTimestamps) {
            $response = Invoke-WebRequest @request
        }
        else {
            $response = Invoke-WebRequest @request -OutFile $outFull -PassThru
        }
    }
    catch {
        # Surface the status and the server's error body; neither contains the key.
        $status = $null
        $detail = $_.Exception.Message
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        if (-not $WithTimestamps -and (Test-Path -LiteralPath $outFull)) {
            Remove-Item -LiteralPath $outFull -Force -ErrorAction SilentlyContinue
        }
        $suffix = if ($status) { " (HTTP $status)" } else { '' }
        throw "Text-to-speech request failed${suffix}: $detail"
    }
    finally {
        if ($apiKey) { $apiKey.Dispose() }
        $stored = $null
    }

    # ---- Write the result -------------------------------------------------
    $contentType = [string]$response.Headers['Content-Type']

    if ($WithTimestamps) {
        if ($contentType -notmatch '^application/json') {
            throw "Expected a JSON response with timestamps but got '$contentType'."
        }
        $payload = $response.Content | ConvertFrom-Json
        if (-not $payload.audio) {
            throw 'The timestamps response contained no audio.'
        }
        [System.IO.File]::WriteAllBytes($outFull, [Convert]::FromBase64String($payload.audio))
        $meta = [ordered]@{
            content_type     = $payload.content_type
            duration         = $payload.duration
            audio_timestamps = $payload.audio_timestamps
        }
        $meta | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $timestampsFull -Encoding utf8
        Write-Verbose "Wrote timestamps to $timestampsFull (duration $($payload.duration) s)"
        $contentType = [string]$payload.content_type
    }
    elseif ($contentType -notmatch '^audio/') {
        $preview = ''
        try {
            $raw = Get-Content -LiteralPath $outFull -Raw -ErrorAction Stop
            $preview = $raw.Substring(0, [Math]::Min(300, $raw.Length))
        } catch {}
        Remove-Item -LiteralPath $outFull -Force -ErrorAction SilentlyContinue
        throw "Expected an audio response but got '$contentType'. $preview"
    }

    $item = Get-Item -LiteralPath $outFull
    Write-Verbose "Wrote $outFull ($($item.Length) bytes, $contentType)"
    $item
}
