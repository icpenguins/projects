<#
    The following script can be run after logging into Azure using the Azure PowerShell extensions.
    It will attempt to create the basic DNS entries typically required by Office 365.
#>


# the Azure DNS Zone Name
$dnsZone = 'contoso.com'

# the Azure DNS Zone Resource Group
$resGroup = 'DNS'

# the Office 365 zone
$365zone = 'mydomain-com'

# The default Office 365 mail exchange
$mxExchange = $365zone + '.mail.protection.outlook.com'

# CNAME Records
New-AzureRmDnsRecordSet -Name 'autodiscover' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Cname "autodiscover.outlook.com")
New-AzureRmDnsRecordSet -Name 'enterpriseenrollment' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Cname "enterpriseenrollment.manage.microsoft.com")
New-AzureRmDnsRecordSet -Name 'enterpriseregistration' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Cname "enterpriseregistration.windows.net")
New-AzureRmDnsRecordSet -Name 'lyncdiscover' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Cname "webdir.online.lync.com")
New-AzureRmDnsRecordSet -Name 'msoid' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Cname "clientconfig.microsoftonline-p.net")
New-AzureRmDnsRecordSet -Name 'sip' -RecordType CNAME -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Cname "sipdir.online.lync.com")

# MX Records
New-AzureRmDnsRecordSet -Name "@" -RecordType MX -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Exchange $mxExchange -Preference 0)

# SRV Records
New-AzureRmDnsRecordSet -Name '_sipfederationtls._tcp' -RecordType SRV -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Priority 0 -Weight 1 -Port 5061 -Target 'sipfed.online.lync.com')
New-AzureRmDnsRecordSet -Name '_sip._tls' -RecordType SRV -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Priority 0 -Weight 1 -Port 443 -Target 'sipdir.online.lync.com')

# TXT Records
New-AzureRmDnsRecordSet -Name '@' -RecordType TXT -ZoneName $dnsZone -ResourceGroupName $resGroup -Ttl 3600 -DnsRecords (New-AzureRmDnsRecordConfig -Value "v=spf1 include:spf.protection.outlook.com -all")
