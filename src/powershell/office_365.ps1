$UserCredential = Get-Credential

Connect-MsolService -Credential $UserCredential

#Simple request to check if connected
Get-MsolUser

#Connecting to sharepoint
#https://peteskelly.com/enable-external-sharing-for-office-365-group-site-collections/
#Connect-SPOService -url https://bcrimages-admin.sharepoint.com
