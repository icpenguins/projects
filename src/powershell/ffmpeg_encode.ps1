<# Copyright (c) 4252 Concepts LLC. Use of this script is at the risk of the consumer and is provided as-is. #>

<#
    .SYNOPSIS
    This script can be used to compress MKV files using FFMpeg. The reduction can often be up to 300% less
    than original while keeping nearly the same level of viewing quality.

    .DESCRIPTION
    Use this script to further compress MKV files.

    .PARAMETER Crop
    The aspect ratio to crop the video. There is no logic behind this so it might be needed to detect the correct
    crop with the detect setting first.

    2.35:1_800 = 1920:800:0:140
    2.35:1_816 = 1920:816:0:132

    .PARAMETER FFmpegPath
    A location for FFMpeg other than ${env:ProgramFiles} + "\FFmpeg\bin\ffmpeg.exe"

    .PARAMETER InputName
    Takes a folder which will be compressed.

    .PARAMETER Process
    Use a 0 or 1 to process even or odd file counts in a folder. This is good when running two scripts at
    the same time to increase throughput.

    .PARAMETER Spatial
    Enables Spatial Adaptive Quantization (AQ) (-spatial_aq) to enhance compression (docs\NVENC_VideoEncoder_API_ProgGuide.pdf)

    .PARAMETER Test
    Test the settings by outputting the first 3 minutes of the video.

    .PARAMETER UseDevice
    Specify which hardware device (GPU) number to use. This is typcially selected from a zero-based array.

    How to get a list of hardware devices:
    https://stackoverflow.com/questions/40424350/how-to-specify-the-gpu-to-be-used-by-nvenc-in-ffmpeg

    & "c:\Program Files\FFmpeg\bin\ffmpeg.exe" -f lavfi -i nullsrc -c:v h264_nvenc -gpu list -f null -

    .EXAMPLE
    Produces a medium quality output file.

    C:\PS> .\ffmpeg_encode.ps1 -InputName C:\MKVPath\video.mkv

    .EXAMPLE
    Allows alternate input processing from a directory. Running two different powershell commands will,
    effectively, thread the processing.

    WINDOW 1: C:\PS> .\ffmpeg_encode.ps1 -InputName C:\MKVPath\ -Process 0
    WINDOW 2: C:\PS> .\ffmpeg_encode.ps1 -InputName C:\MKVPath\ -Process 1

    .EXAMPLE
    Produces a cropped 2.35:1 3 minute long clip.

    C:\PS> .\ffmpeg_encode.ps1 -InputName C:\MKVPath\video.mkv -Crop 2.35:1 -Test

    .EXAMPLE
    Get Video Stream Size
    & 'C:\Program Files\FFmpeg\bin\ffprobe.exe' -i 'D:\RIP\RockyIII\enc\Rocky III.mkv' 2>&1 | Select-String -Pattern '(?ims)Stream\s#\d:\d.*?(\d+x\d+).*?$' -all | %{$_.matches} | %{$_.Groups[1].Value}
#>
function Convert-Media {
    [CmdletBinding()]
param (
    [ValidateSet('detect', '2:1_352', '2.35:1_800', '2.35:1_816', '2.70:1_704', '4:3_1440')]
    $Crop,
    $FFmpegPath = ${env:ProgramFiles} + "\FFmpeg\bin\ffmpeg.exe",
    $InputName,
    [ValidateRange(-1,1)]
    [Int]
    $Process = -1,
    [ValidateSet('verylow', 'low', 'medium', 'high')]
    $Quality = "medium",
    [switch]$Spatial,
    [switch]$Test,
    [ValidateRange(-1,5)]
    [Int]
    $UseDevice = -1
)

$list
$subDir = "\enc\"
$sysObj

try {
    $sysObj = (Get-Item $InputName -ErrorAction Stop)
} catch {
    Write-Error "InputName must be a file or directory."
}

if ($sysObj -is [System.IO.DirectoryInfo]) {
    $dir = Get-ChildItem $sysObj -File
} elseif ($sysObj -is [System.IO.FileInfo]) {
    $dir = $sysObj
}

if ($dir -is [System.IO.FileInfo]) {
    $dir = @($dir)
}

for ($i = 0; $i -lt $dir.Length; $i++) {
    if ($Process -eq 0 -and $i % 2 -ne 0) {
        continue;
    } elseif ($Process -eq 1 -and $i % 2 -eq 0) {
        continue;
    }

    $file = $dir[$i]
    $dirPath = Join-Path $file.DirectoryName $subDir
    $fileOut = Join-Path -Path $dirPath -ChildPath $file.Name
    $list += @($file.FullName, $fileOut)

    if (!(Test-Path $dirPath)) {
        New-Item -ItemType Directory -Force -Path $dirPath
    }
}

for ($i = 0; $i -lt $list.Count - 1; $i = $i + 2) {
    Write-Host "In: " $list[$i] " Out: " $list[$i + 1]

    # Per https://trac.ffmpeg.org/wiki/HWAccelIntro add hardware output
    $cmd = '"$FFmpegPath" -hide_banner -hwaccel cuda '

    if (-1 -lt $UseDevice) {
        $cmd += '-hwaccel_device $UseDevice '
    }

    # Order is important for command line placement
    if ($null -ne $Crop) {
        $cmd += "-hwaccel_output_format cuda "
    }

    $cmd += '-y -probesize 60000000 -analyzeduration 340000000 -fix_sub_duration -i "$($list[$i])" '

    if ($Test.IsPresent) {
        $cmd += '-t 00:03:00 '
    }

    # Use the following command to determine the type of cropping required if not already known.
    if ($null -ne $Crop) {
        switch ($crop) {
            "2:1_352" {
                $cmd += '-vf "crop=704:352:8:62" '
                break;
            }
            "2.35:1_800" {
                $cmd += '-vf "crop=1920:800:0:140" '
                break;
            }
            "2.35:1_816" {
                $cmd += '-vf "crop=1920:816:0:132" '
                break;
            }
            "2.70:1_704" {
                $cmd += '-vf "crop=1904:704:8:138" '
                break;
            }
            "4:3_1440" {
                $cmd += '-vf "crop=1440:1072:240:4" '
                break;
            }
            "detect" {
                $cmd += '-vf "cropdetect" '
                break;
            }
            Default {
                throw [System.ArgumentOutOfRangeException] "The cropping value was incorrect."
            }
        }
    }

    switch ($Quality) {
        "verylow" {
            $cmd += '-qmin 27 -qmax 32 '
            break;
        }
        "low" {
            $cmd += '-qmin 23 -qmax 28 '
            break;
        }
        "medium" {
            $cmd += '-qmin 15 -qmax 24 '
            break;
        }
        "high" {
            $cmd += '-qmin 8 -qmax 18 '
            break;
        }
    }

    $cmd += '-c:v hevc_nvenc '

    if (-1 -lt $UseDevice) {
        $cmd += '-gpu $UseDevice '
    }

    if ($Spatial.IsPresent) {
        $cmd += '-spatial_aq 1 '
    }

    # Lookahead improves the video encoder’s rate-control accuracy by enabling the encoder to buffer the specified number of frames, estimate their complexity,
    # and allocate the bits appropriately among these frames proportional to their complexity.
    # https://docs.nvidia.com/video-technologies/video-codec-sdk/12.0/ffmpeg-with-nvidia-gpu/index.html
    $cmd += '-preset slow -rc vbr -rc-lookahead 20 -2pass 1 -c:a copy -scodec copy -map 0:? -max_muxing_queue_size 1024 "$($list[$i + 1])"'
    $cmd = $ExecutionContext.InvokeCommand.ExpandString($cmd)
    Write-Host $cmd

    Measure-Command { Invoke-Expression "& $cmd" }

    [console]::beep(300,200)
}

[System.Media.SystemSounds]::Beep.Play()
}
