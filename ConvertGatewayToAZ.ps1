<#

 
ScriptName : ConvertVPNGatewayToAZ
Description : This script will convert a "regional" VPN gateway to support Availability Zones
Author : Roelf Zomerman (https://blog.azureinfra.com)
Version : 1.01

#Usage
    ./ConvertGatewayToAZ.ps1 -Name <gatewayName> -ResourceGroupName <resourceGroup> -zoneredundant <$true/$false> -zone <1/2/3> -productionRun <$true/$false> 

#Prerequisites#
- Azure Powershell 1.01 or later
- An Azure Subscription and an account which have the proviliges to : Owner of resourcegroup containing Gateway and IP address

#How it works#
- Grab the Gateway specified
- Export the configuration in JSON
    - Gateway configuration
        - Active/Passive
        - BGP settings
        - SKU
    - Connection configuration
- Output existing configuration on-premises (for VPN for example the Public IP's)
- Change the JSON configuration and save a new deployment file
- Delete the Gateway
- Recreate the gateway
    - Gateway configuration as per export JSON file
- Publish the new IP address(es) to change on-premises (VPN)
- Reconfigure the Connection object

A Deployment Template file will be created for every gateway by this script. This allows the recreation of that gateway easily in case something goes wrong - the script actually deletes the gateway
#if required, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>

Note that the public IP address of the VPN Gateway **WILL** change during this script. Access to the on-premises VPN counterpart will be required.

#>


[CmdletBinding()]
Param(
   [Parameter(Mandatory=$True,Position=2)]
   [string]$Name,
   [Parameter(Mandatory=$True,Position=1)]
   [string]$ResourceGroup,
   [Parameter(Mandatory=$False)]
   [ValidateSet('True','False',$null)]
   [string]$Production,
   [ValidateSet('True','False',$null)]
   [string]$ZoneRedundant,
   [Parameter(Mandatory=$False)]
   [ValidateSet('1','2','3',$null)]
   [string]$Zone,
   [Parameter(Mandatory=$False)]
   [boolean]$Login
)

If (!($ZoneRedundant -eq $true -or $Zone -eq "1" -or $Zone -eq "2" -or $Zone -eq "3")) {
    Write-host "Please input zoneredundant or zone"
    Exit
}


Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
write-host ""
write-host ""

#Cosmetic stuff
write-host ""
write-host ""
write-host "                               _____        __                                " -ForegroundColor Green
write-host "     /\                       |_   _|      / _|                               " -ForegroundColor Yellow
write-host "    /  \    _____   _ _ __ ___  | |  _ __ | |_ _ __ __ _   ___ ___  _ __ ___  " -ForegroundColor Red
write-host "   / /\ \  |_  / | | | '__/ _ \ | | | '_ \|  _| '__/ _' | / __/ _ \| '_ ' _ \ " -ForegroundColor Cyan
write-host "  / ____ \  / /| |_| | | |  __/_| |_| | | | | | | | (_| || (_| (_) | | | | | |" -ForegroundColor DarkCyan
write-host " /_/    \_\/___|\__,_|_|  \___|_____|_| |_|_| |_|  \__,_(_)___\___/|_| |_| |_|" -ForegroundColor Magenta
write-host "     "
write-host " This script reconfigures a Gateway to run in AZ redundant mode" -ForegroundColor "Green"
write-host " WARNING: This script in production run WILL delete your gateway and connection(s) - expect up to 1.5 hrs downtime" -ForegroundColor "Yellow"
write-host ""
write-host ""
write-host "This script will create new public IP addresses and will affect your VPN tunnels - please update the VPN device configuration"
write-host "New Public IP address configuration will be shown after creation of the new objects"
write-host "Existing Gateway settings such as BGP, active/active, connections, tags etc will be retained"
write-host "Prior to deleting objects - a reference json file with the old configuration for every item will be saved in the directory of this script"

#Importing the functions module and primary modules for AAD and AD
write-host ""
write-host ""
write-host "loading modules" -ForegroundColor green

If (Get-Module -name Change-RegionToZone) {
    #reload module
    remove-module Change-RegionToZone
}
Import-Module .\Change-RegionToZone.psm1

If (!((LoadModule -name AzureAD))){
    Write-host "Functions Module was not found - cannot continue - please make sure Set-AzAvailabilitySet.psm1 is available in the same directory"
    Exit
}
If (!((LoadModule -name Az.Network))){
    Write-host "Az.Network Module was not found - cannot continue - please install the module using install-module AZ"
    Exit
}

##Setting Global Paramaters##
$ErrorActionPreference = "Stop"
$date = Get-Date -UFormat "%Y-%m-%d-%H-%M"
$workfolder = Split-Path $script:MyInvocation.MyCommand.Path
$logFile = $workfolder+'\ChangeGWSKU'+$date+'.log'
Write-Output "Steps will be tracked on the log file : [ $logFile ]" 

##Login to Azure##
If ($Login) {
    $Description = "Connecting to Azure"
    $Command = {LogintoAzure}
    $AzureAccount = RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
}


##Select the Subscription##
##Login to Azure##
If ($SelectSubscription) {
    $Description = "Selecting the Subscription : $Subscription"
    $Command = {Get-AZSubscription | Out-GridView -PassThru | Select-AZSubscription}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
}

#Load the GW into an object
$GWObject=Get-AzVirtualNetworkGateway -Name $Name -ResourceGroupName $ResourceGroup

If (!($GWObject)) {
    WriteLog "Target Gateway does not exist, cannot move" -LogFile $LogFile -Color "Red" 
        exit
}else{
    #Exporting the GW object to a JSON file - 
    $Command = {ConvertTo-Json -InputObject $GWObject -Depth 100 | Out-File -FilePath $workfolder'\'$ResourceGroupName-$Name'-Object.json'}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"

     #Exporting JSON template for the GW - This allows the GW to be easily re-deployed back to original state in case something goes wrong
                #if so, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>
                [string]$GWExportFile=($workfolder + '\' + $ResourceGroup + '-' + $Name + '.json')
                $Description = "  -Exporting the GW JSON Deployment file: $GWExportFile "
                $Command = {Export-AzResourceGroup -ResourceGroupName $ResourceGroup -Resource $GWObject.id -IncludeParameterDefaultValue -IncludeComments -Force -Path $GWExportFile }
                RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"

    #Setting zone information for new deployment - and as such for IP deployment
    If ($Zone) {[string]$zoneConfig=$zone}         
    If ($ZoneRedundant) {[string]$zoneConfig='"1","2","3"'}     

    #Need to validate the Public IP's and deploy new ones if not Standard Redundant;
    [array]$oldIPAddresses = $gwObject.IpConfigurations | select PublicIPAddress
    
    #New IP Address is created
    #$NewPublicIPAddressesPublicIPAddress=PublicIPAddress -PublicIPAddresses $oldIPAddresses -LogFile $logFile -Zone $zoneConfig

    write-host (" Checking " + $oldIPAddresses.Count + " public IP's")
    $NewPublicIPs=[System.Collections.ArrayList]@()

    foreach ($PublicIP in $oldIPAddresses){
        write-host ("Scanning "+ $PublicIP.PublicIPAddress.id)
        $IPObject=Get-AzResource -ResourceId $PublicIP.PublicIPAddress.id
        $IpAddressConfig=Get-AzPublicIpAddress -Name $IPObject.Name -ResourceGroupName $IPObject.ResourceGroupName 

        if ($IpAddressConfig.sku.Name -eq 'basic' -or $IpAddressConfig.sku.Tier -ne 'Regional' -or $IpAddressConfig.zones.count -ne 3) {
            Writelog ("IP Address is of " + $IpAddressConfig.sku.Name + " type in the " + $IpAddressConfig.sku.Tier + " - deploying new IP address with correct configuration") -LogFile $LogFile

            #Exporting configuration of Public IP address
            [string]$ExportFile=($workfolder + '\' + $IPObject.ResourceGroupName  + '-' + $IpAddressConfig.Name + '.json')
            $Description = "  -Exporting the Public IP JSON Deployment file: $ExportFile "
            $Command = {Export-AzResourceGroup -ResourceGroupName $ResourceGroupName -Resource $IpAddressConfig.id -IncludeParameterDefaultValue -IncludeComments -Force -Path $ExportFile }
            RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"

            $Command=""

            #if DNSSettings where added - will copy and remove from old IP (if DNS based VPN's are used)
            If ( $IpAddressConfig.DnsSettings) {
                Writelog ("DNS Name on IP: " +  $IpAddressConfig.DnsSettings)  -LogFile $LogFile
                $IPDNSConfig=$IpAddressConfig.DnsSettings.DomainNameLabel
                $IpAddressConfig.DnsSettings.DomainNameLabel=$null
                Writelog ("Removing DNS Name from IP")  -LogFile $LogFile
                Set-AzPublicIpAddress -PublicIpAddress $IpAddressConfig
            }
            #setting new name
            $IpAddressNewName=$IpAddressConfig.Name + "_REDUNDANT"
            writelog "Requiring new Public IP address with zone (redundant) configuration for GW deployment"  -LogFile $LogFile

            $ResourceGroupNameForCommand=$IpAddressConfig.ResourceGroupName
            $Location=$IpAddressConfig.Location
            $Command="New-AzPublicIpAddress -Name $IpAddressNewName -ResourceGroupName $ResourceGroupNameForCommand -Location $Location -Sku Standard -Tier Regional -AllocationMethod Static -IpAddressVersion IPv4 -Zone $zoneConfig"
            #if DNSSettings where added - will copy and remove from old IP (if DNS based VPN's are used)
            If ( $IpAddressConfig.DnsSettings) {
                Writelog ("DNS Name on IP: " +  $IpAddressConfig.DnsSettings)  -LogFile $LogFile
                $IPDNSConfig=$IpAddressConfig.DnsSettings.DomainNameLabel
                $IpAddressConfig.DnsSettings.DomainNameLabel=$null
                Writelog ("Removing DNS Name from IP")  -LogFile $LogFile
                Set-AzPublicIpAddress -PublicIpAddress $IpAddressConfig
                $Command = $Command + " -DomainNameLabel $IPDNSConfig" 
            }
            If ($IpAddressConfig.Tag){
                writelog "Tags have been found on the original IP - setting same on new IP" -LogFile $LogFile

                $newtag=""
                $TagsOnIP=$IpAddressConfig.Tag
                #open the new tag to add
                $newtag="@{"
                $TagsOnIP.GetEnumerator() | ForEach-Object{
                    $message = '{0}="{1}";' -f $_.key, $_.value
                    $newtag=$newtag + $message
                }
                #removing last semicolon
                $newtag=$newtag.Substring(0,$newtag.Length-1)
                #closing newtag value
                $newtag=$newtag +"}"

                #@{key0="value0";key1=$null;key2="value2"}
                $Command=$Command + " -tag $newtag"
            }
            
            $ConfigToAdd=($ResourceGroupNameForCommand + "\"+ $IpAddressNewName)
            write-host "Adding: " $ConfigToAdd
            [void]$NewPublicIPs.add($ConfigToAdd)  
            
            $Command = [Scriptblock]::Create($Command)
            $Description = "  -Creating new Public IP"
            writelog "Deploying new Public IP address with correct information"  -LogFile $LogFile
            Write-host $Command

            RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
        }
    }





    [array]$NewPublicIPAddressesPublicIPAddress=$NewPublicIPs

    #(return is [array]ResourceGroup\NewIPAddressName)

    #names of the returned public IP's need to be converted to ID's and we want to return the IP addresses assigned for on-prem changes
    $NewPublicIPObjectIDs=GetPublicIPAddresses -PublicIPAddresses $NewPublicIPAddressesPublicIPAddress -LogFile $logFile


    #Building the new GatewayObject by changing items in the json file and storing it as a new one
    write-host "loading object definition for GW from $GWExportFile"
    $newgw= Get-Content -Raw -Path $GWExportFile | convertfrom-json 

    #Need to change the defaultValue of the deployment file to point to new IP addresses
    ForEach ($IPName in $NewPublicIPAddressesPublicIPAddress) {
        if ($IPName -eq $null){continue}
        #$ResourceGroupNameForCommand + "\"+ $IpAddressNewName
        #split off the resource group to get the name - then delete the _REDUNDANT appendix so we get to the old name
        $IPName=($IPName.Split("\")[1]).replace("_REDUNDANT","")
        $IPName=$IPName.replace("-","_")
        $parameterName=("publicIPAddresses_" + $IPName + "_externalid")
        #building name format for parameter
        $DefaultValue=$newgw.parameters.$parameterName.DefaultValue
        $newgw.parameters.$parameterName.DefaultValue = ($DefaultValue + "_REDUNDANT")
    }

    #Changing SKU (can also be basic - so then need to fix)
    $SKUName=$newgw.resources.properties.sku.name
    If ($SKUName -eq "Basic") {
        writelog "Need to upgrade to VPN1AZ as minimum" -LogFile $LogFile
        $SKUNAME = "VpnGw1AZ"
    }else{
        If (!($SKUName.EndsWith("AZ"))) {
        $SKUName=($SKUName + "AZ")
        }
    }

    #Changing SKU Tier (can also be basic - so then need to fix)
    $SKUTier=$newgw.resources.properties.sku.tier
    If ($SKUTier -eq "Basic") {
        writelog "Need to upgrade to VPN1AZ as minimum" -LogFile $LogFile
        $SKUTier = "VpnGw1AZ"
    }else{
        If (!($SKUTier.EndsWith("AZ"))) {
            $SKUTier=($SKUTier + "AZ")
            }
    }

    $newgw.resources.properties.sku.name=$SKUName
    $newgw.resources.properties.sku.tier=$SKUTier
    
    #Next is exporting the object to a JSON file for deployment
    [string]$newDeploymentFile=($workfolder + '\' + $ResourceGroup + '-' + $Name + '-Redundant.json')
    $newgw | ConvertTo-Json -Depth 100 | % { [System.Text.RegularExpressions.Regex]::Unescape($_) } | Out-File $newDeploymentFile


    #Next Item on the list is to export all connections related to this GW (as they will need to be saved removed and rebuilt)
    [array]$AllConnections=Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroup | where {$_.VirtualNetworkGateway1.id -match $gwobject.id -or $_.VirtualNetworkGateway2.id -match $gwobject.id}
    Foreach ($connection in $AllConnections){
        #Exporting JSON template for the Connection - This allows the GW to be easily re-deployed back to original state in case something goes wrong
                #if so, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>
                [string]$ExportFile=($workfolder + '\' + $connection.ResourceGroupName + '-' + $connection.name + '.json')
                $Description = "  -Exporting the Connection JSON Deployment file: $ExportFile "
                $Command = {Export-AzResourceGroup -ResourceGroupName $ResourceGroupName -Resource $connection.id -IncludeParameterDefaultValue -IncludeComments -Force -Path $ExportFile }
                RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
        $Description = ("  -Deleting connection " + $connection.name)
        If ($Production) {
            $Command = {Remove-AzVirtualNetworkGatewayConnection -Name $connection.name -ResourceGroupName $connection.ResourceGroupName -Force}
        }else{
            $Command = {Remove-AzVirtualNetworkGatewayConnection -Name $connection.name -ResourceGroupName $connection.ResourceGroupName -Force -WhatIf}
        }
        RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
        $Command=""
    }

    #Removing the gateway itself and building a new one
    $Description = "  -Deleting old gateway - this will take a while"
    If ($Production) {
        $Command = {Remove-AzVirtualNetworkGateway -Name $GWObject.name -ResourceGroupName $GWObject.ResourceGroupName -Force}
    }else{
        $Command = {Remove-AzVirtualNetworkGateway -Name $GWObject.name -ResourceGroupName $GWObject.ResourceGroupName -Force -WhatIf}
    }
    #Executing commands
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
    $Command=""

    #Deploying the new Gateway
    $Description = "  -Deploying NEW gateway - this will take a while (up to 45 min) with file $newDeploymentFile"
    $command={new-AzResourceGroupDeployment -Name $gwObject.name -ResourceGroupName $ResourceGroup -TemplateFile $newDeploymentFile -Mode Incremental}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
    $Command=""

    #Recovering connections files
    Foreach ($connection in $AllConnections){
        #build the export file again and use those for import
        #forestroot-NEU-DXB.json
        $ImportFile=($workfolder + '\' + $ResourceGroup + '-' + $connection.name + '.json')
        $Description = ("  -Restoring connection:" + $connection.name)
        $command={new-AzResourceGroupDeployment -Name $connection.name -ResourceGroupName $ResourceGroup -TemplateFile $ImportFile -Mode Incremental}
        RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
        $Command=""
    }

    #Display Private Endpoints if BGP is used
    $newlyDeployedGW=Get-AzvirtualNetworkGateway -Name $gwObject.name -ResourceGroupName $ResourceGroup
    Write-host "please validate the BGP settings for on-premises configuration of BGP (if used)"
    $newlyDeployedGW.BgpSettings |fl

    write-host "End of script - thank you"

} #end of Else to force quit
