<# Copyright (c) 4252 Concepts LLC. Use of this script is at the risk of the consumer and is provided as-is. #>

<#
    .SYNOPSIS
    This script can be used to compress MKV files using FFMpeg. The reduction can often be up to 300% less
    than original while keeping nearly the same level of viewing quality.

    .DESCRIPTION
    Use this script to further compress MKV files.

    .PARAMETER Crop
    The aspect ratio to crop the video. There is no logic behind this so it might be needed to detect the correct
    crop with the -vf "cropdetect" command first.

    2.35:1_800 = 1920:800:0:140
    2.35:1_816 = 1920:816:0:132

    .PARAMETER FFmpegPath
    A location for FFMpeg other than ${env:ProgramFiles} + "\FFmpeg\bin\ffmpeg.exe"

    .PARAMETER InputName
    Takes a folder which will be compressed.

    .PARAMETER Process
    Use a 0 or 1 to process even or odd file counts in a folder. This is good when running two scripts at
    the same time to increase throughput.

    .PARAMETER Test
    Test the settings by outputting the first 3 minutes of the video.

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
#>
param (
    [ValidateSet('2.35:1_800', '2.35:1_816')]
    $Crop,
    $FFmpegPath = ${env:ProgramFiles} + "\FFmpeg\bin\ffmpeg.exe",
    $InputName,
    [ValidateRange(-1,1)]
    [Int]
    $Process = -1,
    [ValidateSet('low', 'medium', 'high')]
    $Quality = "medium",
    [switch]$Test
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

    $cmd = '"$FFmpegPath" -hide_banner -hwaccel cuda -y -probesize 60000000 -analyzeduration 340000000 -fix_sub_duration -i "$($list[$i])"'

    if ($Test.IsPresent) {
        $cmd += '-t 00:03:00 '
    }

    # Use the following command to determine the type of cropping required if not already known.
    # -vf "cropdetect"
    if ($null -ne $Crop) {
        switch ($crop) {
            "2.35:1_800" {
                $cmd += '-vf "crop=1920:800:0:140" '
                break;
            }
            "2.35:1_816" {
                $cmd += '-vf "crop=1920:816:0:132" '
                break;
            }
            Default {
                throw [System.ArgumentOutOfRangeException] "The cropping value was incorrect."
            }
        }
    }

    switch ($Quality) {
        "low" {
            $cmd += '-qmin 20 -qmax 28 -level 3 '
            break;
        }
        "medium" {
            $cmd += '-qmin 2 -qmax 24 -level 4.2 '
            break;
        }
        "high" {
            $cmd += '-qmin 0 -qmax 19 -level 4.2 '
            break;
        }
    }

    $cmd += '-pix_fmt yuv420p -coder 1 -c:v h264_nvenc -preset slow -profile:v high -c:a copy -scodec copy -map 0:? -max_muxing_queue_size 1024 "$($list[$i + 1])"'
    $cmd = $ExecutionContext.InvokeCommand.ExpandString($cmd)
    Write-Host $cmd

    Invoke-Expression "& $cmd"

    [console]::beep(300,200)
}

[System.Media.SystemSounds]::Beep.Play()
