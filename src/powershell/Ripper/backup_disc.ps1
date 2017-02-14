# Copyright (c) 4252 Concepts and contributors. All rights reserved. Licensed under the Microsoft Reciprocal License. See LICENSE.TXT file in the project root for full license information.

param(
    $MakeMKVPath = ${env:ProgramFiles(x86)} + "\MakeMKV\makemkvcon64.exe",
    $FFmpegPath = ${env:ProgramFiles} + "\FFmpeg\bin\ffmpeg.exe"
)
Set-StrictMode -Version Latest

Set-Variable DISC_TITLE -Value "2"
Set-Variable DISC_TITLE_SHORT -Value "32"
Set-Variable VIDEO_STREAM -Value "0"
Set-Variable VIDEO_STREAM_TYPE -Value "7"
Set-Variable VIDEO_STREAM_RATO -Value "20"
Set-Variable VIDEO_STREAM_RESOLUTION -Value "19"
Set-Variable TITLE_CHAPTERS -Value "8"
Set-Variable TITLE_TIME -Value "9"
Set-Variable TITLE_SIZE -Value "10"
Set-Variable TITLE_NAME -Value "27"

function Get-AvailableDrives {
    param(
        $Path
    )
    Write-Host "Getting Available Drives"
    $options = [ordered]@{ 0 = @{Select = "&Cancel"; Text = "Cancel the operation"; Value = "-1"; }}

    $rdAvailable = &$path -r --cache=1 info disc:9999 | Select-String -Pattern "DRV:\d,2,"

    for ($i = 0; $i -lt $rdAvailable.Matches.Length; $i++) {
        $rdMatches = [regex]::Match($rdAvailable[$i].Line, 'DRV:(\d+).*?"(.*?)","(.*?)","(.*?)"')

        $optSelect = "&{0} {1} ({2})" -f $rdMatches.Captures.Groups[1].Value, $rdMatches.Captures.Groups[4].Value, $rdMatches.Captures.Groups[3].Value
        $optText = "DRV:{0} {1} {2} ({3})" -f $rdMatches.Captures.Groups[1].Value, $rdMatches.Captures.Groups[4].Value, $rdMatches.Captures.Groups[2].Value, $rdMatches.Captures.Groups[3].Value

        $options.Add($i+1, @{Select = $optSelect; Text = $optText; Value = $rdMatches.Captures.Groups[1].Value})
     }

    return $options
}

function Get-DiscInfo {
    param(
        $Path,
        $Disc
    )
    Write-Host "Getting Disc Information"
    #$rdAvailable = Get-Item -Path .\makemkv_out_disc_info.txt | Select-String -Pattern "([CST]INFO)(.*?$)"
    $rdAvailable = &$Path -r info disc:$Disc | Select-String -Pattern "([CST]INFO)(.*?$)"
    $hash = [ordered]@{Disc = [ordered]@{}; Title = [ordered]@{}}

    $rdAvailable.Matches.Captures | %{
        if ($_.Groups[1].Value.ToUpper() -eq "SINFO") {
            $SINFO = [regex]::Match($_.Groups[0].Value, 'SINFO:(\d+),(\d+),(\d+),(\d+),"(.*?)"')

            $title = $SINFO.Groups[1].Value

            $key = $SINFO.Groups[2].Value
            $id = $SINFO.Groups[3].Value
            $value = $SINFO.Groups[5].Value

            if (!$hash["Title"].Contains($title)) {
                $hash["Title"].Add($title, [ordered]@{})
            }

            if (!$hash["Title"][$title].Contains("Details")) {
                $hash["Title"][$title].Add("Details", [ordered]@{})
            }

            if (!$hash["Title"][$title]["Details"].Contains($key)) {
                $hash["Title"][$title]["Details"].Add($key, [ordered]@{})
            }

            $hash["Title"][$title]["Details"][$key].Add($id, $value)
        }
        elseif ($_.Groups[1].Value.ToUpper() -eq "TINFO") {
            $TINFO = [regex]::Match($_, 'TINFO:(\d+),(\d+),(\d+),"(.*?)"')

            $title = $TINFO.Groups[1].Value

            $key = $TINFO.Groups[2].Value
            $value = $TINFO.Groups[4].Value

            if (!$hash["Title"].Contains($title)) {
                $hash["Title"].Add($title, [ordered]@{})
            }

            $hash["Title"][$title].Add($key, $value)
        }
        elseif ($_.Groups[1].Value.ToUpper() -eq "CINFO") {
            $CINFO = [regex]::Match($_, 'CINFO:(\d+),(\d+),"(.*?)"')

            $key = $CINFO.Groups[1].Value
            $value = $CINFO.Groups[3].Value

            $hash["Disc"].Add($key, $value)
        }
    }

    return $hash
}

function Get-DiscInfoOptions {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Info
    )

    $options = [ordered]@{ 0 = @{Select = "&Cancel"; Text = "Cancel the operation"; Value = "-1"; };
                           1 = @{Select = "&Reset"; Text = "Reset the selections"; Value = "-2"; };
                           2 = @{Select = "&Go"; Text = "Selections good to go"; Value = "-3"; } }

    $i = 3
    foreach ($key in $Info["Title"].Keys) {
        $index = [int]$key
        $item = $Info["Title"][$key]

        if ($index -lt 10) {
            $optSelect = "Title &{0} - {2} {3}" -f $key, $item[$TITLE_CHAPTERS], $item[$TITLE_TIME], $item[$TITLE_SIZE]
            $optText = "Title {0}: Chapters ({1}) {2} {3} {4} - {5}" -f $key, $item[$TITLE_CHAPTERS], $item[$TITLE_TIME], $item[$TITLE_SIZE], $item["Details"][$VIDEO_STREAM][$VIDEO_STREAM_RATO], $item[$TITLE_NAME]

            $options.Add($i, @{Select = $optSelect; Text = $optText; Value = $key})
        }
        else {
            "SKIPPING: Title {0} Chapters ({1}) {2} {3} {4} - {5}" -f $key, $item[$TITLE_CHAPTERS], $item[$TITLE_TIME], $item[$TITLE_SIZE], $item["Details"][$VIDEO_STREAM][$VIDEO_STREAM_RATO], $item[$TITLE_NAME] | Write-Host -ForegroundColor Yellow
        }

        $i++
    }

    return $options
}

function Prompt-General {
    param(
        [string]$Title = 'Questions',
        [string]$Message = 'Please select an option.',
        [System.Collections.Specialized.OrderedDictionary]$Choices,

        [parameter(mandatory = $false)]
        [int]$DefaultChoice = 0
    )
    $options = @()

    foreach ($key in $Choices.Keys){
        $item = New-Object System.Management.Automation.Host.ChoiceDescription $Choices[$key]["Select"], $Choices[$key]["Text"]

        $options += $item
    }

    return $host.ui.PromptForChoice(
        $Title,
        $Message,
        [System.Management.Automation.Host.ChoiceDescription[]]$options,
        $DefaultChoice
    ) 
}

function Print-Titles {
    param(
        [System.Collections.Specialized.OrderedDictionary]$DiscInfo
    )
    "A list of Titles from disc '{0}'" -f $DiscInfo["Disc"][$DISC_TITLE] | Write-Host -ForegroundColor Cyan

    $i = 0
    foreach($index in $DiscInfo["Title"].Keys) {
        $item = $DiscInfo["Title"][$index]

        if ($i -lt 10) {
            "Title {0}: Chapters ({1}) {2} {3} {4} - {5}" -f $index, $item[$TITLE_CHAPTERS], $item[$TITLE_TIME], $item[$TITLE_SIZE], $item["Details"][$VIDEO_STREAM][$VIDEO_STREAM_RATO], $item[$TITLE_NAME] | Write-Host -ForegroundColor Green
        }
        else {
            "SKIPPING: Title {0}: Chapters ({1}) {2} {3} {4} - {5}" -f $index, $item[$TITLE_CHAPTERS], $item[$TITLE_TIME], $item[$TITLE_SIZE], $item["Details"][$VIDEO_STREAM][$VIDEO_STREAM_RATO], $item[$TITLE_NAME] | Write-Debug
        }

        $i++
    }
}

function Print-TitleSelected {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Choices,
        [System.Collections.ArrayList]$Selected
    )

    if ($Selected -and $Selected.Count -gt 0) {
        Write-Host "The following titles are selected:"

        foreach ($item in $Selected) {
            $Choices[$item]["Text"] | Write-Host -ForegroundColor Green
        }
    }
}

# https://trac.ffmpeg.org/wiki/HWAccelIntro
# https://trac.ffmpeg.org/wiki/Encode/H.264

function Start-FFmpeg {
    param(
        $FFmpeg,
        $Path,
        $DiscTitle,
        $TitleName
    )

    $newName = ".\{0}\{1}.mkv"-f $DiscTitle, $TitleName
    Write-Host $newName

    $testDir = Test-Path $DiscTitle

    if (-not $testDir) {
        New-Item -Path $DiscTitle -ItemType "directory" | Out-Null
    }

    $time = Get-Date
    "FFmpeg started at {0}" -f $time | Write-Host

    Measure-Command { &$FFmpeg -hide_banner -hwaccel dxva2 -y -i $Path -c:v h264_nvenc -preset slow -level 5.1 -profile:v high -2pass 1 -qdiff 9 -qmin 14 -qmax 24 -minrate 1000k -maxrate 27000k -b:v 6400k -c:a copy -scodec copy $newName| Out-Host }
}

function Start-Ripping {
    param(
        $MakeMKV,
        $FFmpeg
    )
    $rMakeOpt = [ordered]@{ 0 = @{Select = '&Yes'; Text = 'Gets a lists of available discs.'; Value = 0}}
    $rMakeOpt.Add(1, @{Select = '&No'; Text = 'Exit'; Value = "1"})

    $rMakeMKV = Prompt-General -Title "" -Message "Do you want to rip a disc with MakeMKV?" -Choices $rMakeOpt

    if ($rMakeMKV -eq 0) {
        "MakeMKV path '{0}'" -f $MakeMKV | Write-Host -ForegroundColor Gree
        "FFmpeg path '{0}'" -f $FFmpeg | Write-Host -ForegroundColor Gree

        $discOpt = Get-AvailableDrives -Path $MakeMKV

        $rDisc = Prompt-General -Title "Choose Drive for MakeMKV" -Message "Which drive would you like to use?" -Choices $discOpt -DefaultChoice 1

        if ($rDisc -ne 0) {
            $rTitle = 0
            $done = $false
            $selected = New-Object System.Collections.ArrayList

            $discInfo = Get-DiscInfo -Path $MakeMKV -Disc $discOpt[$rDisc]["Value"]

            Print-Titles $discInfo

            $discInfoOpt = Get-DiscInfoOptions $discInfo

            do {
                $rTitle = Prompt-General -Title "" -Message "Which title would you like to use?" -Choices $discInfoOpt -DefaultChoice -1

                if ($rTitle -eq 0) {
                    break
                }
                elseif ($rTitle -eq 1) {
                    $selected.Clear()
                }
                elseif ($rTitle -eq 2) {
                    $done = $true
                }
                elseif ($rTitle -gt 2){
                    if (!$selected.Contains($rTitle)) {
                        $selected.Add($rTitle) | Out-Null
                    }
                    Print-TitleSelected $discInfoOpt $selected
                }
            }
            while(-Not $done)

            if ($rTitle -ne 0) {
                $Process = new-Object System.Diagnostics.Process
                $Process.StartInfo.CreateNoWindow = $true
                $Process.StartInfo.FileName = $MakeMKV
                $Process.StartInfo.Arguments = "-r stream --noscan disc:" + $discOpt[$rDisc]["Value"] + " --bindport=5100" + $discOpt[$rDisc]["Value"]
                $Process.StartInfo.RedirectStandardOutput = $true
                $Process.StartInfo.RedirectStandardError = $true
                $Process.StartInfo.UseShellExecute = $false
                
                Write-Host "Starting MakeMKV HTTP Server"
                $Process.StartInfo.Arguments | Write-Host -ForegroundColor Green

                $Process.Start() | Out-Null
                Start-Sleep -Seconds 10

                $server = $null

                do
                {
                    $msg = $Process.StandardOutput.ReadLine()
                    $stream = $msg | Select-String -Pattern 'MSG:4500.*?address is (.*?) or'
        
                    if ($stream -ne $null -and $stream.Matches.Count -gt 0) {
                        $server = $stream.Matches.Captures.Groups[1].Value
                        break
                    }
                }
                while ($Process.HasExited -ne $true)
                    
                $server | Write-Host -ForegroundColor Green
                    
                Measure-Command {
                    foreach($s in $selected) {
                        $uri = $server + "/web/title" + $discInfoOpt[$s]["Value"]
                        $req = Invoke-WebRequest -Uri $uri
                        $file = [regex]::Match($req.RawContent, '.*?file\d+.*?"(.*?)"')

                        if ($file -and $file.Groups.Count -gt 0) {
                            Start-FFmpeg $FFmpeg $file.Groups[1].Value $discInfo["Disc"][$DISC_TITLE_SHORT] $discInfo["Title"][$discInfoOpt[$s]["Value"]][$TITLE_NAME].Split(".")[0]
                        }
                        else {
                            Write-Host "Could not find file to convert."
                        }
                    }

                    $Process.Kill()
                }
            }
        }
    }
}

Start-Ripping $MakeMKVPath $FFmpegPath

Remove-Variable DISC_TITLE
Remove-Variable DISC_TITLE_SHORT
Remove-Variable VIDEO_STREAM
Remove-Variable VIDEO_STREAM_TYPE
Remove-Variable VIDEO_STREAM_RATO
Remove-Variable VIDEO_STREAM_RESOLUTION
Remove-Variable TITLE_CHAPTERS
Remove-Variable TITLE_TIME
Remove-Variable TITLE_SIZE
Remove-Variable TITLE_NAME
