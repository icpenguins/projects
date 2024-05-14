<# Copyright (c) 4252 Concepts LLC. Use of this script is at the risk of the consumer and is provided as-is. #>

<#
    .SYNOPSIS
    This function can be used to toggle an Elgato Wi-Fi light

    .DESCRIPTION
    Use this function to toggle an Elgato Wi-Fi light

    .PARAMETER IpAddressOrHostName
    Pass in the IP address or host name for the Elgato Wi-Fi light

    .PARAMETER Port
    Used '9123' as the default port but can be changed using this parameter

    .EXAMPLE
    Toggles (switches) the state of the light.

    C:\PS> Switch-Light -IpAddressOrHostName 192.168.1.12
#>
function Switch-Light {
    [CmdletBinding()]
    param (
        $IpAddressOrHostName,
        $Port = 9123
    )

    $uri = 'http://' + $IpAddressOrHostName + ':' + $Port + '/elgato/lights'

    $toggle = 0

    $headers = @{
        Accept = 'application/json'
    }

    $json = Invoke-RestMethod `
        -Method GET `
        -Uri $uri `
        -Headers $headers

    $json

    if (0 -eq $json.lights[0].on) {
        $toggle = 1
    } else {
        $toggle = 0
    }

    $data = @{
        lights = @(@{
            on = $toggle
        })
    }

    Invoke-RestMethod `
        -Method PUT `
        -Uri $uri `
        -ContentType 'application/json' `
        -Headers $headers `
        -Body ($data | ConvertTo-Json)

    #[System.Media.SystemSounds]::Beep.Play()
}
