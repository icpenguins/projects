<#
    The following script can be run after logging into Azure using the Azure PowerShell extensions.
    It will attempt to create the basic DNS entries typically required by Office 365.

    Import-Module -Name Az

    Connect-AzAccount

    Update-Module -Name Az
#>


# the Azure DNS Zone Name
$dnsZone = 'contoso.com'

# the Office 365 zone
$365zone = 'contoso-com'

# the Azure DNS Zone Resource Group
$resGroup = 'DNS'

#Website IP
$ipAddress = "10.0.0.0"

#Website CNAME
$webCname = "somesite.azurewebsites.net"

# The default Office 365 mail exchange
$mxExchange = $365zone + '.mail.protection.outlook.com'

#Create DNS Zone
New-AzDnsZone -Name $dnsZone -ResourceGroupName $resGroup

# A Records
New-AzDnsRecordSet -Name '@' -RecordType A -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -IPv4Address $ipAddress)

# CNAME Records
New-AzDnsRecordSet -Name 'autodiscover' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Cname "autodiscover.outlook.com")
New-AzDnsRecordSet -Name 'enterpriseenrollment' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Cname "enterpriseenrollment.manage.microsoft.com")
New-AzDnsRecordSet -Name 'enterpriseregistration' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Cname "enterpriseregistration.windows.net")
New-AzDnsRecordSet -Name 'lyncdiscover' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Cname "webdir.online.lync.com")
New-AzDnsRecordSet -Name 'msoid' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Cname "clientconfig.microsoftonline-p.net")
New-AzDnsRecordSet -Name 'sip' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Cname "sipdir.online.lync.com")
New-AzDnsRecordSet -Name 'www' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig  -Cname $dnsZone)

# MX Records
New-AzDnsRecordSet -Name "@" -RecordType MX -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Exchange $mxExchange -Preference 0)

# SRV Records
New-AzDnsRecordSet -Name '_sipfederationtls._tcp' -RecordType SRV -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Priority 0 -Weight 1 -Port 5061 -Target 'sipfed.online.lync.com')
New-AzDnsRecordSet -Name '_sip._tls' -RecordType SRV -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzDnsRecordConfig -Priority 0 -Weight 1 -Port 443 -Target 'sipdir.online.lync.com')

# TXT Records
$txtSet = @()
$txtSet += New-AzDnsRecordConfig -Value "v=spf1 include:spf.protection.outlook.com -all"
$txtSet += New-AzDnsRecordConfig -Value $webCname

New-AzDnsRecordSet -Name '@' -RecordType TXT -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords $txtSet
