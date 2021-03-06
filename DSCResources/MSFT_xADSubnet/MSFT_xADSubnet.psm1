# Localized messages
data LocalisedData
{
    # culture="en-US"
    ConvertFrom-StringData @'
        RoleNotFoundError              = Please ensure that the PowerShell module for role '{0}' is installed
        RetrievingSubnet             = Retrieving Subnet '{0}'.
        UpdatingSubnet               = Updating Subnet '{0}'
        DeletingSubnet               = Deleting Subnet '{0}'
        CreatingSubnet               = Creating Subnet '{0}'
        SubnetInDesiredState         = Subnet '{0}' exists and is in the desired state
        SubnetNotInDesiredState      = Subnet '{0}' exists but is not in the desired state
        SubnetExistsButShouldNot     = Subnet '{0}' exists when it should not exist
        SubnetDoesNotExistButShould  = Subnet '{0}' does not exist when it should exist
        SubnetsIncludedRemoveError       = You cannot remove all Subnets from the Subnet '{0}'
        MultipleSubnetsError         = IP and SMTP Subnets both found with the name '{0}'. Rename one of the Subnets or include the InterSubnetTransportProtocol parameter
        ChangeNotificationValueError   = Invalid setting of '{0}' provided for ChangeNotification. Valid values are 0, 1 and 5
        ReplicationScheduleValueError  = Invalid setting of provided for ReplicationSchedule
        UnsupportedOperatingSystem     = Unsupported operating system. xADSubnet resource requires Microsoft Windows Server 2012 or later
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
        $Subnet,

        [parameter()]
        [System.String]
        $Description,

        [parameter()]
        [System.String]
        $Location,

        [parameter()]
        [System.String]
        $Site,

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $EnterpriseAdministratorCredential,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $DomainController
    )
    
    $operatingSystem = (Get-CimInstance -Class win32_operatingsystem).Caption

    # The cmdlets used by this resource are not part of the ActiveDirectory module on 2008 R2

    if ($operatingSystem -like "*Windows Server 2008*"){
        throw ($LocalisedData.UnsupportedOperatingSystem)
    }
    
    Assert-Module -ModuleName 'ActiveDirectory'
    Import-Module -Name 'ActiveDirectory' -Verbose:$false

    Write-Verbose ($LocalisedData.RetrievingSubnet -f $Subnet)
    $getADReplicationSubnetParams = @{
        Filter = "Name -eq '$Subnet'"
        Credential = $EnterpriseAdministratorCredential
    }

    if ($PSBoundParameters.ContainsKey('DomainController'))
    {
        $getADReplicationSubnetParams['Server'] = $DomainController
    }
    
    $properties = @('Description')
  
    $getADReplicationSubnetParams['Properties'] = $properties
    $SubnetObj = Get-ADReplicationSubnet @getADReplicationSubnetParams
    

    if ($null -eq $SubnetObj)
    {
        $targetResourceStatus = 'Absent'
    }

    elseif ($SubnetObj.IsArray)
    {
        <# 
            If $Subnet is an array then more than one matching Subnet has been found, which would only happen if someone named
            an IP Subnet the same as an SMTP Subnet
        #>
        throw ($LocalisedData.MultipleSubnetsError -f $Subnet)
    }

    else
    {
        $targetResourceStatus = 'Present'
    }

    $targetResource = @{
        Subnet = $Subnet
        Ensure = $targetResourceStatus
        Description = $SubnetObj.Description
        Location = $SubnetObj.Location
        Site = $SubnetObj.Site
        EnterpriseAdministratorCredential = $EnterpriseAdministratorCredential
        DomainController = $DomainController
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
        $Subnet,

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $EnterpriseAdministratorCredential,

        [parameter()]
        [ValidateSet("Present","Absent")]
        [System.String]
        $Ensure = 'Present',

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Description,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Location,
        
        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Site,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $DomainController
    )

    $operatingSystem = (Get-CimInstance -Class win32_operatingsystem).Caption

    # The cmdlets used by this resource are not part of the ActiveDirectory module on 2008 R2

    if ($operatingSystem -like "*Windows Server 2008*"){
        throw ($LocalisedData.UnsupportedOperatingSystem)
    }

    $isCompliant = $true

    $targetResourceParams = @{
        Subnet = $Subnet
        EnterpriseAdministratorCredential = $EnterpriseAdministratorCredential
    }

    if ($PSBoundParameters.ContainsKey('DomainController'))
    {
        $targetResourceParams['DomainController'] = $DomainController
    }

    $targetResource = Get-TargetResource @targetResourceParams

    if ($targetResource.Ensure -eq 'Present')
    {
        # Subnet link exists
        if ($Ensure -eq 'Present')
        {
            # Subnet link exists and should
            foreach ($parameter in $PSBoundParameters.Keys)
            {
               if ($targetResource.ContainsKey($parameter))
                {
                    # This check is required to be able to explicitly remove values with an empty string, if required
                    if (([System.String]::IsNullOrEmpty($PSBoundParameters.$parameter)) -and ([System.String]::IsNullOrEmpty($targetResource.$parameter)))
                    {
                        # Both values are null/empty and therefore compliant
                        Write-Verbose ($LocalisedData.SubnetInDesiredState -f $parameter, $PSBoundParameters.$parameter, $targetResource.$parameter)
                    }

                    elseif ($PSBoundParameters.$parameter -ne $targetResource.$parameter)
                    {
                        Write-Verbose ($LocalisedData.SubnetNotInDesiredState -f $targetResource.Subnet)
                        $isCompliant = $false
                    }
                }
            }

            if ($isCompliant -eq $true)
            {
                # All values on targetResource match the desired state
                Write-Verbose ($LocalisedData.SubnetInDesiredState -f $targetResource.Subnet)
            }
        }

        else
        {
            # Subnet link exists but should not
            $isCompliant = $false
            Write-Verbose ($LocalisedData.SubnetExistsButShouldNot -f $targetResource.Subnet)
        }
    }

    else
    {
        # Subnet link does not exist
        if ($Ensure -eq 'Present')
        {
            $isCompliant = $false
            Write-Verbose ($LocalisedData.SubnetDoesNotExistButShould -f $targetResource.Subnet)
        }

        else
        {
            Write-Verbose ($LocalisedData.SubnetInDesiredState -f $targetResource.Subnet)
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
        $Subnet,

        [parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.CredentialAttribute()]
        $EnterpriseAdministratorCredential,

        [parameter()]
        [ValidateSet("Present","Absent")]
        [System.String]
        $Ensure = 'Present',

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Description,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Location,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Site,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $DomainController
    )

    $operatingSystem = (Get-CimInstance -Class win32_operatingsystem).Caption

    # The cmdlets used by this resource are not part of the ActiveDirectory module on 2008 R2

    if ($operatingSystem -like "*Windows Server 2008*"){
        throw ($LocalisedData.UnsupportedOperatingSystem)
    }
    
    Assert-Module -ModuleName 'ActiveDirectory'
    Import-Module -Name 'ActiveDirectory' -Verbose:$false

    $targetResourceParams = @{
        Subnet = $Subnet
        EnterpriseAdministratorCredential = $EnterpriseAdministratorCredential
    }

    if ($PSBoundParameters.ContainsKey('DomainController'))
    {
        $targetResourceParams['DomainController'] = $DomainController
    }

    $targetResource = Get-TargetResource @targetResourceParams

    if ($targetResource.Ensure -eq 'Present')
    {
        # Subnet link exists
        if ($Ensure -eq 'Present')
        {
            <#
                Subnet link exists and should, but some properties do not match.
                Find the relevant properties and update the Subnet link accordingly
            #>
            $setADReplicationSubnetParams = @{
                Identity = $Subnet
                Credential = $EnterpriseAdministratorCredential
            }

            if ($PSBoundParameters.ContainsKey('DomainController'))
            {
                $setADReplicationSubnetParams['Server'] = $DomainController
            }

            foreach ($parameter in $PSBoundParameters.Keys)
            {
               if ($targetResource.ContainsKey($parameter))
                {
                    # This check is required to be able to explicitly remove values with an empty string, if required
                    if (($parameter -ne 'EnterpriseAdministratorCredential') -and ($parameter -ne 'Subnet') -and ($parameter -ne 'DomainController'))
                    {
                        if ($PSBoundParameters.$parameter -ne $targetResource.$parameter)
                        {
                            $setADReplicationSubnetParams["$parameter"] = $PSBoundParameters.$parameter
                        }
                    }
                }
            }

            # When all the params are set, run Set-ADReplicationSubnet

            Write-Verbose ($LocalisedData.UpdatingSubnet -f $targetResource.Subnet)
            Set-ADReplicationSubnet @setADReplicationSubnetParams
        }

        else
        {
            # Subnet link should not exist but does. Delete the Subnet link
            $removeADReplicationSubnetParams = @{
                Identity = $Subnet
                Credential = $EnterpriseAdministratorCredential
            }

            if ($PSBoundParameters.ContainsKey('DomainController'))
            {
                $targetResourceParams['Server'] = $DomainController
            }

            Write-Verbose ($LocalisedData.DeletingSubnet -f $targetResource.Subnet)
            Remove-ADReplicationSubnet @removeADReplicationSubnetParams
        }
    }

    else
    {
        # Subnet does not exist
        if ($Ensure -eq 'Present')
        {
            # Subnet link should exist but does not. Create Subnet link
            $newADReplicationSubnetParams = @{
                Name = $Subnet
                Credential = $EnterpriseAdministratorCredential
            }

            foreach ($parameter in $PSBoundParameters.Keys)
            {
                if ($parameter -eq 'DomainController')
                {
                    $newADReplicationSubnetParams['Server'] = $DomainController
                }

                elseif (($parameter -ne 'Subnet') -and ($parameter -ne 'EnterpriseAdministratorCredential') -and ($parameter -ne 'Ensure'))
                {
                    $newADReplicationSubnetParams[$parameter] = $PSBoundParameters.$parameter
                }
            }

            Write-Verbose ($LocalisedData.CreatingSubnet -f $Subnet)
            New-ADReplicationSubnet @newADReplicationSubnetParams
        }
    }
}

# Import the common AD functions
$adCommonFunctions = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath '\MSFT_xADCommon\MSFT_xADCommon.ps1'
. $adCommonFunctions


