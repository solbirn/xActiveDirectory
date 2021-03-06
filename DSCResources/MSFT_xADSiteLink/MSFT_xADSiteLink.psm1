# Localized messages
data LocalisedData
{
    # culture="en-GB"
    ConvertFrom-StringData @'
        RoleNotFoundError              = Please ensure that the PowerShell module for role '{0}' is installed
        RetrievingSiteLink             = Retrieving SiteLink '{0}'.
        UpdatingSiteLink               = Updating SiteLink '{0}'
        DeletingSiteLink               = Deleting SiteLink '{0}'
        CreatingSiteLink               = Creating SiteLink '{0}'
        SiteLinkInDesiredState         = SiteLink '{0}' exists and is in the desired state
        SiteLinkNotInDesiredState      = SiteLink '{0}' exists but is not in the desired state
        SiteLinkExistsButShouldNot     = SiteLink '{0}' exists when it should not exist
        SiteLinkDoesNotExistButShould  = SiteLink '{0}' does not exist when it should exist
        SitesIncludedRemoveError       = You cannot remove all sites from the SiteLink '{0}'
        MultipleSiteLinksError         = IP and SMTP SiteLinks both found with the name '{0}'. Rename one of the sites or include the InterSiteTransportProtocol parameter
        ChangeNotificationValueError   = Invalid setting of '{0}' provided for ChangeNotification. Valid values are 0, 1 and 5
        ReplicationScheduleValueError  = Invalid setting of provided for ReplicationSchedule
        UnsupportedOperatingSystem     = Unsupported operating system. xADSiteLink resource requires Microsoft Windows Server 2012 or later
'@
}

function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $SiteLinkName,

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $EnterpriseAdministratorCredential,

        [parameter()]
        [ValidateSet("IP","SMTP")]
        [System.String]
        $InterSiteTransportProtocol,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $DomainController,
        
        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.UInt32]
        $ChangeNotification,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String[]]
        $ReplicationSchedule
    )
    
    $operatingSystem = (Get-CimInstance -Class win32_operatingsystem).Caption

    # The cmdlets used by this resource are not part of the ActiveDirectory module on 2008 R2

    if ($operatingSystem -like "*Windows Server 2008*"){
        throw ($LocalisedData.UnsupportedOperatingSystem)
    }
    
    Assert-Module -ModuleName 'ActiveDirectory'
    Import-Module -Name 'ActiveDirectory' -Verbose:$false

    Write-Verbose ($LocalisedData.RetrievingSiteLink -f $SiteLinkName)
    $getADReplicationSiteLinkParams = @{
        Filter = "Name -eq '$SiteLinkName'"
        Credential = $EnterpriseAdministratorCredential
    }

    if ($PSBoundParameters.ContainsKey('DomainController'))
    {
        $getADReplicationSiteLinkParams['Server'] = $DomainController
    }

    if ($PSBoundParameters.ContainsKey('InterSiteTransportProtocol'))
    {
        # If a transport protocol is specified, ensure that both the site link name and transport protocol match
        $properties = @('InterSiteTransportProtocol','Description')
        if ($PSBoundParameters.ContainsKey('ChangeNotification'))
        {
            $properties += 'options'
        }

        if ($PSBoundParameters.ContainsKey('ReplicationSchedule'))
        {
            $properties += 'ReplicationSchedule'
        }

        $getADReplicationSiteLinkParams['Properties'] = $Properties
        $siteLink = Get-ADReplicationSiteLink @getADReplicationSiteLinkParams | Where-Object InterSiteTransportProtocol -eq $InterSiteTransportProtocol
    }
    else
    {
        $properties = @('Description')
        if ($PSBoundParameters.ContainsKey('ChangeNotification'))
        {
            $properties += 'options'
        }

        if ($PSBoundParameters.ContainsKey('ReplicationSchedule'))
        {
            $properties += 'ReplicationSchedule'
        }

        $getADReplicationSiteLinkParams['Properties'] = $properties
        $siteLink = Get-ADReplicationSiteLink @getADReplicationSiteLinkParams
    }

    if ($null -eq $siteLink)
    {
        $targetResourceStatus = 'Absent'
    }

    elseif ($siteLink.IsArray)
    {
        <# 
            If $siteLink is an array then more than one matching site link has been found, which would only happen if someone named
            an IP site link the same as an SMTP site link
        #>
        throw ($LocalisedData.MultipleSiteLinksError -f $SiteLinkName)
    }

    else
    {
        $targetResourceStatus = 'Present'
    }

    $sitesIncludedFriendlyName = @()

    foreach ($site in $siteLink.SitesIncluded)
    {
        $site = $site -replace '^CN=|,\S.*$'-as [string]
        $sitesIncludedFriendlyName += $site
    }

    $targetResource = @{
        SiteLinkName = $SiteLinkName
        Ensure = $targetResourceStatus
        SitesIncluded = $sitesIncludedFriendlyName
        Description = $siteLink.Description
        EnterpriseAdministratorCredential = $EnterpriseAdministratorCredential
        DomainController = $DomainController
        Cost = $siteLink.Cost
        ReplicationFrequencyInMinutes = $siteLink.ReplicationFrequencyInMinutes
    }

    if ($PSBoundParameters.ContainsKey('InterSiteTransportProtocol'))
    {
        $targetResource['InterSiteTransportProtocol'] = $InterSiteTransportProtocol
    }

    if ($PSBoundParameters.ContainsKey('ChangeNotification'))
    {
        if ($siteLink.options)
        {
            $targetResource['ChangeNotification'] = $siteLink.options
        }

        else
        {
            $targetResource['ChangeNotification'] = 0
        }
    }

    if ($PSBoundParameters.ContainsKey('ReplicationSchedule'))
    {
        if ($null -eq $siteLink.ReplicationSchedule)
        {
            <# 
                If no ReplicationSchedule is found, then the site link is using the default 24x7 schedule.
                Create an AD Schedule object that represents this to enable comparison with desired state
            #>
            $defaultSchedule = New-Object -TypeName System.DirectoryServices.ActiveDirectory.ActiveDirectorySchedule
            $defaultSchedule.SetDailySchedule('Zero','Zero','TwentyThree','FortyFive')
            $defaultRawSchedule = $defaultSchedule.RawSchedule
            $defaultRawSchedule
            $targetResource['ReplicationSchedule'] = ConvertFrom-3dBoolArray $defaultRawSchedule
        }

        else
        {
            $siteLinkRawSchedule = $siteLink.ReplicationSchedule.RawSchedule
            $targetResource['ReplicationSchedule'] = ConvertFrom-3dBoolArray $siteLinkRawSchedule
        }
    }

    return $targetResource
}

function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $SiteLinkName,

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $EnterpriseAdministratorCredential,

        [parameter()]
        [ValidateSet("Present","Absent")]
        [System.String]
        $Ensure = 'Present',

        [parameter()]
        [ValidateSet("IP","SMTP")]
        [System.String]
        $InterSiteTransportProtocol,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Description,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.UInt32]
        $Cost,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.UInt32]
        $ReplicationFrequencyInMinutes,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String[]]
        $SitesIncluded,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $DomainController,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.UInt32]
        $ChangeNotification,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String[]]
        $ReplicationSchedule
    )

    $operatingSystem = (Get-CimInstance -Class win32_operatingsystem).Caption

    # The cmdlets used by this resource are not part of the ActiveDirectory module on 2008 R2

    if ($operatingSystem -like "*Windows Server 2008*"){
        throw ($LocalisedData.UnsupportedOperatingSystem)
    }

    $isCompliant = $true

    $targetResourceParams = @{
        SiteLinkName = $SiteLinkName
        EnterpriseAdministratorCredential = $EnterpriseAdministratorCredential
    }

    if ($PSBoundParameters.ContainsKey('DomainController'))
    {
        $targetResourceParams['DomainController'] = $DomainController
    }

    if ($PSBoundParameters.ContainsKey('InterSiteTransportProtocol'))
    {
        $targetResourceParams['InterSiteTransportProtocol'] = $InterSiteTransportProtocol
    }

    if ($PSBoundParameters.ContainsKey('ChangeNotification'))
    {
        if(($ChangeNotification -ne 0) -and ($ChangeNotification -ne 1) -and ($ChangeNotification -ne 5))
        {
            throw ($LocalisedData.ChangeNotificationValueError -f $ChangeNotification)
        }
        
        else
        {
            $targetResourceParams['ChangeNotification'] = $ChangeNotification
        }
    }

    if ($PSBoundParameters.ContainsKey('ReplicationSchedule'))
    {
        $daysOfWeek = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
        $hoursOfDay = @('Zero','One','Two','Three','Four','Five','Six','Seven','Eight','Nine','Ten','Eleven','Twelve','Thirteen','Fourteen','Fifteen','Sixteen','Seventeen','Eighteen','Nineteen','Twenty','TwentyOne','TwentyTwo','TwentyThree')
        [System.DayOfWeek] $day = 'Monday'
        [System.DirectoryServices.ActiveDirectory.HourOfDay] $fromHour = 'Zero'
        [System.DirectoryServices.ActiveDirectory.MinuteOfHour] $fromMinute = 'Zero'
        [System.DirectoryServices.ActiveDirectory.HourOfDay] $toHour = 'TwentyThree'
        [System.DirectoryServices.ActiveDirectory.MinuteOfHour] $toMinute = 'FortyFive'

        $activeDirectorySchedule = New-Object -TypeName System.DirectoryServices.ActiveDirectory.ActiveDirectorySchedule
        
        if ($ReplicationSchedule[0] -eq '24x7')
        {
            $activeDirectorySchedule.SetDailySchedule($fromHour,$fromMinute,$toHour,$toMinute)
            
        }

        elseif ($ReplicationSchedule[0] -in $daysOfWeek)
        {
            $scheduleLength = $ReplicationSchedule.Length
            $scheduleCounter = 0

            Do
            {
                $day = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $fromHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $fromMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $activeDirectorySchedule.SetSchedule($day,$fromHour,$fromMinute,$toHour,$toMinute)
            } Until ($scheduleCounter -eq $scheduleLength)
        }

        elseif ($ReplicationSchedule[0] -in $hoursOfDay)
        {
            $scheduleLength = $ReplicationSchedule.Length
            $scheduleCounter = 0

            Do
            {
                $fromHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $fromMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $activeDirectorySchedule.SetDailySchedule($fromHour,$fromMinute,$toHour,$toMinute)
            } Until ($scheduleCounter -eq $scheduleLength)
        }

        else
        {
            throw ($LocalisedData.ReplicationScheduleValueError -f $ChangeNotification)
        }

        # The value of this parameter when passed to Get-TargetResource just needs to be a string
        $targetResourceParams['ReplicationSchedule'] = @('Required')
    }

    $targetResource = Get-TargetResource @targetResourceParams

    if ($targetResource.Ensure -eq 'Present')
    {
        # Site link exists
        if ($Ensure -eq 'Present')
        {
            # Site link exists and should
            foreach ($parameter in $PSBoundParameters.Keys)
            {
                if ($parameter -eq 'SitesIncluded')
                {
                    foreach ($site in $PSBoundParameters.SitesIncluded)
                    {
                        # Check all required sites are included on the site link
                        if ($site -notin $targetResource.SitesIncluded)
                        {
                            Write-Verbose ($LocalisedData.SiteLinkNotInDesiredState -f $targetResource.SiteLinkName)
                            $isCompliant = $false
                        }
                    }

                    foreach ($site in $targetResource.SitesIncluded)
                    {
                        # Check that the site link doesn't include sites that should not be included
                        if ($site -notin $PSBoundParameters.SitesIncluded)
                        {
                            Write-Verbose ($LocalisedData.SiteLinkNotInDesiredState -f $targetResource.SiteLinkName)
                            $isCompliant = $false
                        }
                    }
                }

                elseif ($parameter -eq 'ReplicationSchedule')
                {
                    
                    $scheduleComparison = Compare-Object -ReferenceObject ($activeDirectorySchedule.RawSchedule) -DifferenceObject ($targetResource.ReplicationSchedule)
                    if($null -ne $scheduleComparison)
                    {
                        Write-Verbose ($LocalisedData.SiteLinkNotInDesiredState -f $targetResource.SiteLinkName)
                        $isCompliant = $false
                    }
                }
                
                elseif ($targetResource.ContainsKey($parameter))
                {
                    # This check is required to be able to explicitly remove values with an empty string, if required
                    if (([System.String]::IsNullOrEmpty($PSBoundParameters.$parameter)) -and ([System.String]::IsNullOrEmpty($targetResource.$parameter)))
                    {
                        # Both values are null/empty and therefore compliant
                        Write-Verbose ($LocalisedData.SiteLinkInDesiredState -f $parameter, $PSBoundParameters.$parameter, $targetResource.$parameter)
                    }

                    elseif ($PSBoundParameters.$parameter -ne $targetResource.$parameter)
                    {
                        Write-Verbose ($LocalisedData.SiteLinkNotInDesiredState -f $targetResource.SiteLinkName)
                        $isCompliant = $false
                    }
                }
            }

            if ($isCompliant -eq $true)
            {
                # All values on targetResource match the desired state
                Write-Verbose ($LocalisedData.SiteLinkInDesiredState -f $targetResource.SiteLinkName)
            }
        }

        else
        {
            # Site link exists but should not
            $isCompliant = $false
            Write-Verbose ($LocalisedData.SiteLinkExistsButShouldNot -f $targetResource.SiteLinkName)
        }
    }

    else
    {
        # Site link does not exist
        if ($Ensure -eq 'Present')
        {
            $isCompliant = $false
            Write-Verbose ($LocalisedData.SiteLinkDoesNotExistButShould -f $targetResource.SiteLinkName)
        }

        else
        {
            Write-Verbose ($LocalisedData.SiteLinkInDesiredState -f $targetResource.SiteLinkName)
        }
    }

    return $isCompliant
}

function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $SiteLinkName,

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $EnterpriseAdministratorCredential,

        [parameter()]
        [ValidateSet("Present","Absent")]
        [System.String]
        $Ensure = 'Present',

        [parameter()]
        [ValidateSet("IP","SMTP")]
        [System.String]
        $InterSiteTransportProtocol,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Description,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.UInt32]
        $Cost,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.UInt32]
        $ReplicationFrequencyInMinutes,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String[]]
        $SitesIncluded,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $DomainController,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.UInt32]
        $ChangeNotification,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String[]]
        $ReplicationSchedule
    )

    $operatingSystem = (Get-CimInstance -Class win32_operatingsystem).Caption

    # The cmdlets used by this resource are not part of the ActiveDirectory module on 2008 R2

    if ($operatingSystem -like "*Windows Server 2008*"){
        throw ($LocalisedData.UnsupportedOperatingSystem)
    }
    
    Assert-Module -ModuleName 'ActiveDirectory'
    Import-Module -Name 'ActiveDirectory' -Verbose:$false

    $targetResourceParams = @{
        SiteLinkName = $SiteLinkName
        EnterpriseAdministratorCredential = $EnterpriseAdministratorCredential
    }

    if ($PSBoundParameters.ContainsKey('DomainController'))
    {
        $targetResourceParams['DomainController'] = $DomainController
    }

    if ($PSBoundParameters.ContainsKey('InterSiteTransportProtocol'))
    {
        $targetResourceParams['InterSiteTransportProtocol'] = $InterSiteTransportProtocol
    }

    if ($PSBoundParameters.ContainsKey('ChangeNotification'))
    {
        $targetResourceParams['ChangeNotification'] = $ChangeNotification
    }

    if ($PSBoundParameters.ContainsKey('ReplicationSchedule'))
    {
        $daysOfWeek = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
        $hoursOfDay = @('Zero','One','Two','Three','Four','Five','Six','Seven','Eight','Nine','Ten','Eleven','Twelve','Thirteen','Fourteen','Fifteen','Sixteen','Seventeen','Eighteen','Nineteen','Twenty','TwentyOne','TwentyTwo','TwentyThree')
        [System.DayOfWeek] $day = 'Monday'
        [System.DirectoryServices.ActiveDirectory.HourOfDay] $fromHour = 'Zero'
        [System.DirectoryServices.ActiveDirectory.MinuteOfHour] $fromMinute = 'Zero'
        [System.DirectoryServices.ActiveDirectory.HourOfDay] $toHour = 'TwentyThree'
        [System.DirectoryServices.ActiveDirectory.MinuteOfHour] $toMinute = 'FortyFive'
        $activeDirectorySchedule = New-Object -TypeName System.DirectoryServices.ActiveDirectory.ActiveDirectorySchedule
        
        if ($ReplicationSchedule[0] -eq '24x7')
        {
            $activeDirectorySchedule.SetDailySchedule($fromHour,$fromMinute,$toHour,$toMinute)
            
        }

        elseif ($ReplicationSchedule[0] -in $daysOfWeek)
        {
            $scheduleLength = $ReplicationSchedule.Length
            $scheduleCounter = 0

            Do
            {
                $day = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $fromHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $fromMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $activeDirectorySchedule.SetSchedule($day,$fromHour,$fromMinute,$toHour,$toMinute)
            } Until ($scheduleCounter -eq $scheduleLength)
        }

        elseif ($ReplicationSchedule[0] -in $hoursOfDay)
        {
            $scheduleLength = $ReplicationSchedule.Length
            $scheduleCounter = 0

            Do
            {
                $fromHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $fromMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toHour = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $toMinute = $ReplicationSchedule[$scheduleCounter]
                $scheduleCounter++
                $activeDirectorySchedule.SetDailySchedule($fromHour,$fromMinute,$toHour,$toMinute)
            } Until ($scheduleCounter -eq $scheduleLength)
        }

        else
        {
            throw ($LocalisedData.ReplicationScheduleValueError -f $ChangeNotification)
        }

        # The value of this parameter when passed to Get-TargetResource just needs to be a string
        $targetResourceParams['ReplicationSchedule'] = 'Required'
    }

    $targetResource = Get-TargetResource @targetResourceParams

    if ($targetResource.Ensure -eq 'Present')
    {
        # Site link exists
        if ($Ensure -eq 'Present')
        {
            <#
                Site link exists and should, but some properties do not match.
                Find the relevant properties and update the site link accordingly
            #>
            $setADReplicationSiteLinkParams = @{
                Identity = $SiteLinkName
                Credential = $EnterpriseAdministratorCredential
            }

            if ($PSBoundParameters.ContainsKey('DomainController'))
            {
                $setADReplicationSiteLinkParams['Server'] = $DomainController
            }

            foreach ($parameter in $PSBoundParameters.Keys)
            {
                if ($parameter -eq 'SitesIncluded')
                {
                    $sitesToAdd = @()
                    $sitesToRemove = @()
                    foreach ($site in $PSBoundParameters.SitesIncluded)
                    {
                        if ($site -notin $targetResource.SitesIncluded)
                        {
                            # Site needs to be added to SitesIncluded
                            $sitesToAdd += $site
                        }
                    }
                    foreach ($site in $targetResource.SitesIncluded)
                    {
                        if ($site -notin $PSBoundParameters.SitesIncluded)
                        {
                            # Site needs to be removed from SitesIncluded
                            $sitesToRemove += $site
                        }
                    }

                    if (($sitesToAdd) -and ($sitesToRemove))
                    {
                        # Sites need to be added and removed
                        $sitesIncludedValue = @{
                            Add = $sitesToAdd
                            Remove = $sitesToRemove
                        }

                        $setADReplicationSiteLinkParams.Add('SitesIncluded',$sitesIncludedValue)
                    }

                    elseif ($sitesToAdd)
                    {
                        # Sites need to be added but not removed
                        $sitesIncludedValue = @{
                            Add = $sitesToAdd
                        }

                        $setADReplicationSiteLinkParams.Add('SitesIncluded',$sitesIncludedValue)
                    }

                    elseif ($sitesToRemove)
                    {
                        # Sites need to be removed but not added
                        if ($sitesToRemove.Count -ge $targetResource.SitesIncluded.Count)
                        {
                            # Set-ADReplicationSiteLink cmdlet doesn't let you remove all sites from a site link object
                            throw ($LocalisedData.SitesIncludedRemoveError -f $targetResource.SiteLinkName)
                        }

                        $sitesIncludedValue = @{
                            Remove = $sitesToRemove
                        }

                        $setADReplicationSiteLinkParams.Add('SitesIncluded',$sitesIncludedValue)
                    }
                }

                elseif ($parameter -eq 'ChangeNotification')
                {
                    if ($PSBoundParameters.ChangeNotification -ne $targetResource.$parameter)
                    {
                        if ($PSBoundParameters.ChangeNotification -eq 0)
                        {
                            $clearProperties = @('Options')
                            $setADReplicationSiteLinkParams.Add('Clear',$clearProperties)
                        }
                        else
                        {
                            $replaceProperties = @{
                                Options = $PSBoundParameters.ChangeNotification
                            }
                            $setADReplicationSiteLinkParams.Add('Replace',$replaceProperties)
                        }
                    }
                }

                elseif ($parameter -eq 'ReplicationSchedule')
                {
                    
                    $scheduleComparison = Compare-Object -ReferenceObject ($activeDirectorySchedule.RawSchedule) -DifferenceObject ($targetResource.ReplicationSchedule)
                    if($null -ne $scheduleComparison)
                    {
                        $setADReplicationSiteLinkParams['ReplicationSchedule'] = $activeDirectorySchedule
                    }
                }
                
                elseif ($targetResource.ContainsKey($parameter))
                {
                    # This check is required to be able to explicitly remove values with an empty string, if required
                    if (($parameter -ne 'EnterpriseAdministratorCredential') -and ($parameter -ne 'SiteLinkName') -and ($parameter -ne 'DomainController'))
                    {
                        if ($PSBoundParameters.$parameter -ne $targetResource.$parameter)
                        {
                            $setADReplicationSiteLinkParams["$parameter"] = $PSBoundParameters.$parameter
                        }
                    }
                }
            }

            # When all the params are set, run Set-ADReplicationSiteLink

            Write-Verbose ($LocalisedData.UpdatingSiteLink -f $targetResource.SiteLinkName)
            Set-ADReplicationSiteLink @setADReplicationSiteLinkParams
        }

        else
        {
            # Site link should not exist but does. Delete the site link
            $removeADReplicationSiteLinkParams = @{
                Identity = $SiteLinkName
                Credential = $EnterpriseAdministratorCredential
            }

            if ($PSBoundParameters.ContainsKey('DomainController'))
            {
                $targetResourceParams['Server'] = $DomainController
            }

            Write-Verbose ($LocalisedData.DeletingSiteLink -f $targetResource.SiteLinkName)
            Remove-ADReplicationSiteLink @removeADReplicationSiteLinkParams
        }
    }

    else
    {
        # Site link does not exist
        if ($Ensure -eq 'Present')
        {
            # Site link should exist but does not. Create site link
            $newADReplicationSiteLinkParams = @{
                Name = $SiteLinkName
                Credential = $EnterpriseAdministratorCredential
            }

            foreach ($parameter in $PSBoundParameters.Keys)
            {
                if ($parameter -eq 'DomainController')
                {
                    $newADReplicationSiteLinkParams['Server'] = $DomainController
                }

                elseif ($parameter -eq 'SitesIncluded')
                {
                    $newADReplicationSiteLinkParams.Add('SitesIncluded', $SitesIncluded)
                }

                elseif ($parameter -eq 'ChangeNotification')
                {
                    if ($PSBoundParameters.ChangeNotification -ne 0)
                    {
                        $otherAttributes = @{
                            Options = $ChangeNotification
                        }
                        $newADReplicationSiteLinkParams.Add('OtherAttributes', $otherAttributes)
                    }
                }

                elseif ($parameter -eq 'ReplicationSchedule')
                {
                    $newADReplicationSiteLinkParams['ReplicationSchedule'] = $activeDirectorySchedule
                }

                elseif (($parameter -ne 'SiteLinkName') -and ($parameter -ne 'EnterpriseAdministratorCredential') -and ($parameter -ne 'Ensure'))
                {
                    $newADReplicationSiteLinkParams[$parameter] = $PSBoundParameters.$parameter
                }
            }

            Write-Verbose ($LocalisedData.CreatingSiteLink -f $SiteLinkName)
            New-ADReplicationSiteLink @newADReplicationSiteLinkParams
        }
    }

}

function ConvertFrom-3dBoolArray{
    param(
        [parameter(Mandatory=$true, Position=0)]
        [System.Boolean[,,]]
        $ThreeDimensionalBooleanArray
    )

    $dimensionOne = New-Object bool[][][] 7
    for($i=0; $i -lt 7; $i++)
    {
        $dimensionTwo = New-Object bool[][] 24
        for($j=0; $j -lt 24; $j++)
        {
            $dimensionThree = New-Object bool[] 4
            for($k=0; $k -lt 4; $k++)
            {
                if($ThreeDimensionalBooleanArray[$i, $j, $k] -eq $true)
                {
                    $dimensionThree[$k] = $true
                }
            }
            $dimensionTwo[$j] = $dimensionThree
        }
        $dimensionOne[$i] = $dimensionTwo
    }

    return $dimensionOne
}


# Import the common AD functions
$adCommonFunctions = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath '\MSFT_xADCommon\MSFT_xADCommon.ps1'
. $adCommonFunctions