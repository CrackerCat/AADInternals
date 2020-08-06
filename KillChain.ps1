﻿#
# This file contains functions for Azure AD / Office 365 kill chain
#


# Invokes information gathering as an outsider
# Jun 16th 2020
function Invoke-ReconAsOutsider
{
<#
    .SYNOPSIS
    Starts tenant recon of the given domain.

    .DESCRIPTION
    Starts tenant recon of the given domain. Gets all verified domains of the tenant and extracts information such as their type.
    Also checks whether Desktop SSO (aka Seamless SSO) is enabled for the tenant.

    DNS:  Does the DNS record exists?
    MX:   Does the MX point to Office 365?
    SPF:  Does the SPF contain Exchange Online?
    Type: Federated or Managed
    STS:  The FQDN of the federated IdP's (Identity Provider) STS (Security Token Service) server

    .Parameter DomainName
    Any domain name of the Azure AD tenant.

    .Parameter Single
    If the switch is used, doesn't get other domains of the tenant.

    .Example
    Invoke-AADIntReconAsOutsider | Format-Table

    Tenant brand:       Company Ltd
    Tenant name:        company
    Tenant id:          05aea22e-32f3-4c35-831b-52735704feb3
    DesktopSSO enabled: False

    Name                          MX    SPF   Type      STS
    ----                          --    ---   ----      ---
    company.com                   True  True  Federated sts.company.com   
    company.mail.onmicrosoft.com  True  True  Managed    
    company.onmicrosoft.com       True  True  Managed    
    int.company.com               False False Managed 
#>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [String]$DomainName,
        [Switch]$Single
    )
    Process
    {
        Write-Verbose "Checking if the domain $DomainName is registered to Azure AD"
        $tenantId =    Get-TenantID -Domain $DomainName
        $tenantName =  ""
        $tenantBrand = ""
        $tenantSSO =   ""
        if([string]::IsNullOrEmpty($tenantId))
        {
            throw "Domain $DomainName is not registered to Azure AD"
        }

        Write-Verbose "`n*`n* EXAMINING TENANT $tenantId`n*"

        # Don't try to get other domains
        if($Single)
        {
            $domains = @($DomainName)
        }
        else
        {
            Write-Verbose "Getting domains.."
            $domains = Get-TenantDomains -Domain $DomainName
            Write-Verbose "Found $($domains.count) domains!"
        }

        # Create an empty list
        $domainInformation = @()

        # Counter
        $c=1

        # Loop through the domains
        foreach($domain in $domains)
        {
            # Define variables
            $exists =      $false
            $hasCloudMX =  $false
            $hasCloudSPF = $false

            Write-Progress -Activity "Getting DNS information" -Status $domain -PercentComplete (($c/$domains.count)*100)
            $c++

            # Check if this is "the initial" domain
            if([string]::IsNullOrEmpty($tenantName) -and $domain.ToLower() -match "^[^.]*\.onmicrosoft.com$")
            {
                $tenantName = $domain.Substring(0,$domain.IndexOf("."))
                Write-Verbose "TENANT NAME: $tenantName"
            }

            # Check whether the domain exists in DNS
            try { $exists = (Resolve-DnsName -Name $Domain -ErrorAction SilentlyContinue -DnsOnly -NoHostsFile -NoIdn).count -gt 0 }  catch{}

            if($exists)
            {
                # Check the MX record
                $hasCloudMX = HasCloudMX -Domain $domain

                # Check the SPF record
                $hasCloudSPF = HasCloudSPF -Domain $domain
            }

            # Check if the tenant has the Desktop SSO (aka Seamless SSO) enabled
            if([string]::IsNullOrEmpty($tenantSSO) -or $tenantSSO -eq $false)
            {
                $tenantSSO = HasDesktopSSO -Domain $domain
            }

            # Get the federation information
            $realmInfo = Get-UserRealmV2 -UserName "nn@$domain"
            if([string]::IsNullOrEmpty($tenantBrand))
            {
                $tenantBrand = $realmInfo.FederationBrandName
                Write-Verbose "TENANT BRAND: $tenantBrand"
            }
            if($authUrl = $realmInfo.AuthUrl)
            {
                # Get just the server name
                $authUrl = $authUrl.split("/")[2]
            }

            # Set the return object properties
            $attributes=[ordered]@{
                "Name" = $domain
                "DNS" =  $exists
                "MX" =   $hasCloudMX
                "SPF" =  $hasCloudSPF
                "Type" = $realmInfo.NameSpaceType
                "STS" =  $authUrl                    
            }
            $domainInformation += New-Object psobject -Property $attributes
        }

        Write-Host "Tenant brand:       $tenantBrand"
        Write-Host "Tenant name:        $tenantName"
        Write-Host "Tenant id:          $tenantId"

        # DesktopSSO status not definitive with a single domain
        if(!$Single -or $tenantSSO -eq $true)
        {
            Write-Host "DesktopSSO enabled: $tenantSSO"
        }
        
        return $domainInformation
    }

}


# Tests whether the user exists in Azure AD or not
# Jun 16th 2020
function Invoke-UserEnumerationAsOutsider
{
<#
    .SYNOPSIS
    Checks whether the given user exists in Azure AD or not.

    .DESCRIPTION
    Checks whether the given user exists in Azure AD or not. Works only if the user is in the tenant where Desktop SSO (aka Seamless SSO) is enabled for any domain.
    Works also with external users!

    .Parameter Site
    UserName
    User name or email address of the user.

    .Example
    Invoke-AADIntUserEnumerationAsOutsider -UserName user@company.com

    UserName         Exists
    --------         ------
    user@company.com True

    .Example
    Get-Content .\users.txt | Invoke-AADIntUserEnumerationAsOutsider

    UserName                                               Exists
    --------                                               ------
    user@company.com                                       True
    user2@company.com                                      False
    external.user_gmail.com#EXT#@company.onmicrosoft.com   True
    external.user_outlook.com#EXT#@company.onmicrosoft.com False
#>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory,ValueFromPipeline)]
        [String]$UserName
    )
    Process
    {
        return new-object psobject -Property ([ordered]@{"UserName"=$UserName;"Exists" = $(DoesUserExists -User $UserName)})
    }
}

# Invokes information gathering as a guest user
# Jun 16th 2020
function Invoke-ReconAsGuest
{
<#
    .SYNOPSIS
    Starts tenant recon of Azure AD tenant. Prompts for tenant.

    .DESCRIPTION
    Starts tenant recon of Azure AD tenant. Prompts for tenant.
    Retrieves information from Azure AD tenant, such as, the number of Azure AD objects and quota, and the number of domains (both verified and unverified).

    .Example
    Get-AADIntAccessTokenForAzureCoreManagement -SaveToCache

    $results = Invoke-AADIntReconAsGuest

    PS C:\>$results.allowedActions

    application      : {read}
    domain           : {read}
    group            : {read}
    serviceprincipal : {read}
    tenantdetail     : {read}
    user             : {read, update}
    serviceaction    : {consent}

    .Example
    Get-AADIntAccessTokenForAzureCoreManagement -SaveToCache

    PS C:\>Get-AADIntAzureTenants

    Id                                   Country Name                      Domains                                                                                                  
    --                                   ------- ----                      -------                                                                                                  
    221769d7-0747-467c-a5c1-e387a232c58c FI      Firma Oy                  {firma.mail.onmicrosoft.com, firma.onmicrosoft.com, firma.fi}              
    6e3846ee-e8ca-4609-a3ab-f405cfbd02cd US      Company Ltd               {company.onmicrosoft.com, company.mail.onmicrosoft.com,company.com}

    PS C:\>Get-AADIntAccessTokenForAzureCoreManagement -SaveToCache -Tenant 6e3846ee-e8ca-4609-a3ab-f405cfbd02cd

    $results = Invoke-AADIntReconAsGuest

    Tenant brand:                Company Ltd
    Tenant name:                 company.onmicrosoft.com
    Tenant id:                   6e3846ee-e8ca-4609-a3ab-f405cfbd02cd
    Azure AD objects:            520/500000
    Domains:                     6 (4 verified)
    Non-admin users restricted?  True
    Users can register apps?     True
    Directory access restricted? False

    PS C:\>$results.allowedActions

    application      : {read}
    domain           : {read}
    group            : {read}
    serviceprincipal : {read}
    tenantdetail     : {read}
    user             : {read, update}
    serviceaction    : {consent}
    
#>
    [cmdletbinding()]
    Param()
    Begin
    {
        # Choises
        $choises="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!""#%&/()=?*+-_"
    }
    Process
    {
        # Get access token from cache
        $AccessToken = Get-AccessTokenFromCache -AccessToken $AccessToken -Resource "https://management.core.windows.net" -ClientId "d3590ed6-52b3-4102-aeff-aad2292ab01c"

        # Get the list of tenants the user has access to
        $tenants = Get-AzureTenants -AccessToken $AccessToken
        $tenantNames = $tenants | select -ExpandProperty Name

        # Prompt for tenant choice if more than one
        if($tenantNames.count -gt 1)
        {
            $options = [System.Management.Automation.Host.ChoiceDescription[]]@()
            for($p=0; $p -lt $tenantNames.count; $p++)
            {
                $options += New-Object System.Management.Automation.Host.ChoiceDescription "&$($choises[$p % $choises.Length]) $($tenantNames[$p])"
            }
            $opt = $host.UI.PromptForChoice("Choose the tenant","Choose the tenant to recon",$options,0)
            }
        else
        {
            $opt=0
        }
        $tenantInfo = $tenants[$opt]
        $tenant =     $tenantInfo.Id

        # Get the tenant information
        $tenantInformation = Get-AzureInformation -Tenant $tenant

        # Print out some relevant information
        Write-Host "Tenant brand:                $($tenantInformation.displayName)"
        Write-Host "Tenant name:                 $($tenantInformation.domains | where isInitial -eq "True" | select -ExpandProperty id)"
        Write-Host "Tenant id:                   $($tenantInformation.objectId)"
        Write-Host "Azure AD objects:            $($tenantInformation.directorySizeQuota.used)/$($tenantInformation.directorySizeQuota.total)"
        Write-Host "Domains:                     $($tenantInformation.domains.Count) ($(($tenantInformation.domains | where isVerified -eq "True").Count) verified)"
        Write-Host "Non-admin users restricted?  $($tenantInformation.restrictNonAdminUsers)"
        Write-Host "Users can register apps?     $($tenantInformation.usersCanRegisterApps)"
        Write-Host "Directory access restricted? $($tenantInformation.restrictDirectoryAccess)"

        # Return
        return $tenantInformation

    }
}

# Starts crawling the organisation for user names and groups
# Jun 16th 2020
function Invoke-UserEnumerationAsGuest
{
<#
    .SYNOPSIS
    Crawls the target organisation for user names and groups.

    .DESCRIPTION
    Crawls the target organisation for user names, groups, and roles. The starting point is the signed-in user, a given username, or a group id.
    The crawl can be controlled with switches. Group members are limited to 1000 entries per group.

    Groups:       Include user's groups
    GroupMembers: Include members of user's groups
    Roles:        Include roles of user and group members. Can be very time consuming!
    Manager:      Include user's manager
    Subordinates: Include user's subordinates (direct reports)
    
    UserName:     User principal name (UPN) of the user to search.
    GroupId:      Id of the group. If this is given, only the members of the group are included. 

    .Example
    $results = Invoke-AADIntUserEnumerationAsGuest -UserName user@company.com

    Tenant brand: Company Ltd
    Tenant name:  company.onmicrosoft.com
    Tenant id:    6e3846ee-e8ca-4609-a3ab-f405cfbd02cd
    Logged in as: live.com#user@outlook.com
    Users:        5
    Groups:       2
    Roles:        0

#>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$False)]
        [String]$UserName,
        [Switch]$Groups,
        [Switch]$GroupMembers,
        [Switch]$Subordinates,
        [Switch]$Manager,
        [Switch]$Roles,
        [Parameter(Mandatory=$False)]
        [String]$GroupId
    )
    Begin
    {
        # Choises
        $choises="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!""#%&/()=?*+-_"
    }
    Process
    {
        # Get access token from cache
        $AccessToken = Get-AccessTokenFromCache -AccessToken $AccessToken -Resource "https://management.core.windows.net" -ClientId "d3590ed6-52b3-4102-aeff-aad2292ab01c"

        # Get the list of tenants the user has access to
        Write-Verbose "Getting list of user's tenants.."
        $tenants = Get-AzureTenants -AccessToken $AccessToken
        $tenantNames = $tenants | select -ExpandProperty Name

        # Prompt for tenant choice if more than one
        if($tenantNames.count -gt 1)
        {
            $options = [System.Management.Automation.Host.ChoiceDescription[]]@()
            for($p=0; $p -lt $tenantNames.count; $p++)
            {
                $options += New-Object System.Management.Automation.Host.ChoiceDescription "&$($choises[$p % $choises.Length]) $($tenantNames[$p])"
            }
            $opt = $host.UI.PromptForChoice("Choose the tenant","Choose the tenant to recon",$options,0)
            }
        else
        {
            $opt=0
        }
        $tenantInfo = $tenants[$opt]
        $tenant =     $tenantInfo.Id

        # Create a new AccessToken for graph.microsoft.com
        $refresh_token = $script:refresh_tokens["d3590ed6-52b3-4102-aeff-aad2292ab01c-https://management.core.windows.net"]
        if([string]::IsNullOrEmpty($refresh_token))
        {
            throw "No refresh token found! Use Get-AADIntAccessTokenForAzureCoreManagement with -SaveToCache switch"
        }
        $AccessToken = Get-AccessTokenWithRefreshToken -Resource "https://graph.microsoft.com" -ClientId "d3590ed6-52b3-4102-aeff-aad2292ab01c" -TenantId $tenant -RefreshToken $refresh_token -SaveToCache $true

        # Get the initial domain
        $domains = Get-MSGraphDomains -AccessToken $AccessToken
        $tenantDomain = $domains | where isInitial -eq "True" | select -ExpandProperty id
        if([string]::IsNullOrEmpty($tenantDomain))
        {
            Throw "No initial domain found for the tenant $tenant!"
        }
        Write-Verbose "Tenant $Tenant / $tenantDomain selected."

        

        # If GroupID is given, dump only the members of that group
        if($GroupId)
        {
            # Create users object
            $ht_users=@{}

            # Get group members
            $members = Get-MSGraphGroupMembers -AccessToken $AccessToken -GroupId $GroupId

            # Create a variable for members
            $itemMembers = @()

            # Loop trough the members
            foreach($member in $members)
            {
                $ht_users[$member.Id] = $member
                $itemMembers += $member.userPrincipalName
            }
        }
        else
        {

            # If user name not given, try to get one from the access token
            if([string]::IsNullOrEmpty($UserName))
            {
                $UserName = (Read-Accesstoken -AccessToken $AccessToken).upn

                # If upn not found, this is probably live.com user, so use email instead of upn
                if([string]::IsNullOrEmpty($UserName))
                {
                    $UserName = (Read-Accesstoken -AccessToken $AccessToken).email
                }

                if(-not ($UserName -like "*#EXT#*"))
                {
                    # As this must be an extrernal user, convert to external format
                    $UserName = "$($UserName.Replace("@","_"))#EXT#@$tenantDomain"
                }
            }

            Write-Verbose "Getting user information for user $UserName"

            # Get the user information
            $user = Get-MSGraphUser -UserPrincipalName $UserName -AccessToken $AccessToken 

            if([string]::IsNullOrEmpty($user))
            {
                throw "User $UserName not found!"
            }

            # Create the users object
            $ht_users=@{
                $user.id = $user
                }

            # Create the groups object
            $ht_groups=@{}

            # Create the roles object
            $ht_roles=@{}

            Write-Verbose "User found: $($user.id) ($($user.userPrincipalName))"

            # Loop through the user's subordinates
            if($Subordinates)
            {
                # Copy the keys as the hashtable may change
                $so_keys = New-Object string[] $ht_users.Count
                $ht_users.Keys.CopyTo($so_keys,0)

                # Loop through the users
                foreach($userId in $so_keys)
                {
                    $user = $ht_users[$userId].userPrincipalName
                    Write-Verbose "Getting subordinates of $user"

                    # Get user's subordinates
                    $userSubordinates = Get-MSGraphUserDirectReports -AccessToken $AccessToken -UserPrincipalName $user

                    # Loop trough the users
                    foreach($subordinate in $userSubordinates)
                    {
                        $ht_users[$subordinate.Id] = $subordinate
                    }
                }
            }

            # Get user's manager
            if($Manager)
            {
                try{$userManager= Get-MSGraphUserManager -AccessToken $AccessToken -UserPrincipalName $UserName}catch{}
                if($userManager)
                {
                    $ht_users[$userManager.id] = $userManager
                }
            }

            # Loop through the users' groups
            if($Groups -or $GroupMembers)
            {
                foreach($userId in $ht_users.Keys)
                {
                    $groupUser = $ht_users[$userId].userPrincipalName
                    Write-Verbose "Getting groups of $groupUser"

                    # Get user's groups
                    $userGroups = Get-MSGraphUserMemberOf -AccessToken $AccessToken -UserPrincipalName $groupUser

                    # Loop trough the groups
                    foreach($group in $userGroups)
                    {
                        # This is a normal group
                        if($group.'@odata.type' -eq "#microsoft.graph.group")
                        {
                            $ht_groups[$group.id] = $group
                            #$itemGroups += $group.id
                        }
                    }

                }
            }

            # Loop through the group members
            if($GroupMembers)
            {
                foreach($groupId in $ht_groups.Keys)
                {
                    Write-Verbose "Getting groups of $groupUser"

                    # Get group members
                    $members = Get-MSGraphGroupMembers -AccessToken $AccessToken -GroupId $groupId

                    # Create a variable for members
                    $itemMembers = @()

                    # Loop trough the members
                    foreach($member in $members)
                    {
                        $ht_users[$member.Id] = $member
                        $itemMembers += $member.userPrincipalName
                    }

                    # Add members to the group
                    $ht_groups[$groupId] | Add-Member -NotePropertyName "members" -NotePropertyValue $itemMembers

                    # Get group owners
                    $owners = Get-MSGraphGroupOwners -AccessToken $AccessToken -GroupId $groupId

                    # Create a variable for members
                    $itemOwners = @()

                    # Loop trough the members
                    foreach($owner in $owners)
                    {
                        $ht_users[$owner.Id] = $owner
                        $itemOwners += $owner.userPrincipalName
                    }

                    # Add members to the group
                    $ht_groups[$groupId] | Add-Member -NotePropertyName "owners" -NotePropertyValue $itemOwners
                }
            }

            # Loop through the users' roles
            if($Roles)
            {
                foreach($userId in $ht_users.Keys)
                {
                    $roleUser = $ht_users[$userId].userPrincipalName
                    Write-Verbose "Getting roles of $roleUser"

                    # Get user's roles
                    $userRoles = Get-MSGraphUserMemberOf -AccessToken $AccessToken -UserPrincipalName $roleUser

                    # Loop trough the groups
                    foreach($userRole in $userRoles)
                    {
                        if($userRole.'@odata.type' -eq "#microsoft.graph.directoryRole")
                        {
                            # Try to get the existing role first
                            $role = $ht_roles[$userRole.id]
                            if($role)
                            {
                                # Add a new member to the role
                                $role.members+=$ht_users[$userId].userPrincipalName
                            }
                            else
                            {
                                # Create a members attribute
                                $userRole | Add-Member -NotePropertyName "members" -NotePropertyValue @($ht_users[$userId].userPrincipalName)
                                $role = $userRole
                            }

                            $ht_roles[$role.id] = $role
                        }
                    }

                }
            }

            # Loop through the role members
            if($Roles)
            {
                foreach($roleId in $ht_roles.Keys)
                {
                    $members = $null
                    Write-Verbose "Getting role members for '$($ht_roles[$roleId].displayName)'"

                    # Try to get role members, usually fails
                    try{$members = Get-MSGraphRoleMembers -AccessToken $AccessToken -RoleId $roleId}catch{ }

                    if($members)
                    {
                        # Create a variable for members
                        $itemMembers = @()

                        # Loop trough the members
                        foreach($member in $members)
                        {
                            $ht_users[$member.Id] = $member
                            $itemMembers += $member.userPrincipalName
                        }

                        # Add members to the role
                        $ht_roles[$roleId] | Add-Member -NotePropertyName "members" -NotePropertyValue $itemMembers -Force
                    }
                }
            }
        }

        # Print out some relevant information
        Write-Host "Tenant brand: $($tenantInfo.Name)"
        Write-Host "Tenant name:  $tenantDomain"
        Write-Host "Tenant id:    $($tenantInfo.id)"
        Write-Host "Logged in as: $((Read-Accesstoken -AccessToken $AccessToken).unique_name)"
        Write-Host "Users:        $($ht_users.count)"
        Write-Host "Groups:       $($ht_groups.count)"
        Write-Host "Roles:        $($ht_roles.count)"

        # Create the return value
        $attributes=@{
            "Users" =  $ht_users.values
            "Groups" = $ht_groups.Values
            "Roles" =  $ht_roles.Values
        }
        return New-Object psobject -Property $attributes
    }
}


# Invokes information gathering as an internal user
# Aug 4th 2020
function Invoke-ReconAsInsider
{
<#
    .SYNOPSIS
    Starts tenant recon of Azure AD tenant.

    .DESCRIPTION
    Starts tenant recon of Azure AD tenant.
    
    .Example
    Get-AADIntAccessTokenForAADGraph

    $results = Invoke-AADIntReconAsInsider

    PS C:\>$results.allowedActions

    application      : {read}
    domain           : {read}
    group            : {read}
    serviceprincipal : {read}
    tenantdetail     : {read}
    user             : {read, update}
    serviceaction    : {consent}
#>
    [cmdletbinding()]
    Param()
    Begin
    {
        
    }
    Process
    {
        # Get access token from cache
        $AccessToken = Get-AccessTokenFromCache -AccessToken $AccessToken -Resource "https://management.core.windows.net" -ClientId "d3590ed6-52b3-4102-aeff-aad2292ab01c"
        
        # Get the refreshtoken from the cache and create AAD token
        $tenantId = (Read-Accesstoken $AccessToken).tid
        $refresh_token=$script:refresh_tokens["d3590ed6-52b3-4102-aeff-aad2292ab01c-https://management.core.windows.net"]
        $AAD_AccessToken = Get-AccessTokenWithRefreshToken -RefreshToken $refresh_token -Resource "https://graph.windows.net" -ClientId "d3590ed6-52b3-4102-aeff-aad2292ab01c" -TenantId $tenantId

        # Get the tenant information
        Write-Verbose "Getting company information"
        $companyInformation = Get-CompanyInformation -AccessToken $AAD_AccessToken

        # Get the sharepoint information
        Write-Verbose "Getting SharePoint Online information"
        $sharePointInformation = Get-SPOServiceInformation -AccessToken $AAD_AccessToken

        # Get the admins
        Write-Verbose "Getting role information"
        $roles = Get-Roles -AccessToken $AAD_AccessToken
        $roleInformation=@()
        $sortedRoles = $roles.Role | Sort -Property Name
        foreach($role in $roles.Role)
        {
            Write-Verbose "Getting members of role ""$($role.Name)"""
            $attributes=[ordered]@{}
            $attributes["Name"] = $role.Name
            $attributes["IsEnabled"] = $role.IsEnabled
            $attributes["IsSystem"] = $role.IsSystem
            $attributes["ObjectId"] = $role.ObjectId
            $members = Get-RoleMembers -AccessToken $AAD_AccessToken -RoleObjectId $role.ObjectId | select @{N='DisplayName'; E={$_.DisplayName}},@{N='UserPrincipalName'; E={$_.EmailAddress}}

            $attributes["Members"] = $members

            $roleInformation += New-Object psobject -Property $attributes
        }

        # Get the tenant information
        $tenantInformation = Get-AzureInformation -Tenant $tenantId

        # Set the extra tenant information
        $tenantInformation |Add-Member -NotePropertyName "companyInformation" -NotePropertyValue $companyInformation
        $tenantInformation |Add-Member -NotePropertyName "SPOInformation"     -NotePropertyValue $sharePointInformation
        $tenantInformation |Add-Member -NotePropertyName "roleInformation"    -NotePropertyValue $roleInformation

        # Print out some relevant information
        Write-Host "Tenant brand:                $($tenantInformation.displayName)"
        Write-Host "Tenant name:                 $($tenantInformation.domains | where isInitial -eq "True" | select -ExpandProperty id)"
        Write-Host "Tenant id:                   $tenantId"
        Write-Host "Azure AD objects:            $($tenantInformation.directorySizeQuota.used)/$($tenantInformation.directorySizeQuota.total)"
        Write-Host "Domains:                     $($tenantInformation.domains.Count) ($(($tenantInformation.domains | where isVerified -eq "True").Count) verified)"
        Write-Host "Non-admin users restricted?  $($tenantInformation.restrictNonAdminUsers)"
        Write-Host "Users can register apps?     $($tenantInformation.usersCanRegisterApps)"
        Write-Host "Directory access restricted? $($tenantInformation.restrictDirectoryAccess)"
        Write-Host "Directory sync enabled?      $($tenantInformation.companyInformation.DirectorySynchronizationEnabled)"
        Write-Host "Global admins                $(($tenantInformation.roleInformation | Where-Object ObjectId -eq "62e90394-69f5-4237-9190-012177145e10" | Select-Object -ExpandProperty Members).Count)" 

        # Return
        return $tenantInformation

    }
}

# Starts crawling the organisation for user names and groups
# Jun 16th 2020
function Invoke-UserEnumerationAsInsider
{
<#
    .SYNOPSIS
    Dumps user names and groups of the tenant.

    .DESCRIPTION
    Dumps user names and groups of the tenant.
    By default, the first 1000 users and groups are returned. 

    Groups:       Include user's groups
    GroupMembers: Include members of user's groups (not recommended)
        
    GroupId:      Id of the group. If this is given, only the members of the group are included. 

    .Example
    $results = Invoke-AADIntUserEnumerationAsInsider -UserName user@company.com

    Tenant brand: Company Ltd
    Tenant name:  company.onmicrosoft.com
    Tenant id:    6e3846ee-e8ca-4609-a3ab-f405cfbd02cd
    Logged in as: live.com#user@outlook.com
    Users:        5
    Groups:       2
    Roles:        0

#>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$False)]
        [int] $MaxResults=1000,
        [switch] $Groups,
        [switch] $GroupMembers,
        [Parameter(Mandatory=$False)]
        [String]$GroupId
    )
    Begin
    {
    }
    Process
    {
        # Get access token from cache
        $AccessToken = Get-AccessTokenFromCache -AccessToken $AccessToken -Resource "https://management.core.windows.net" -ClientId "d3590ed6-52b3-4102-aeff-aad2292ab01c"

         # Create a new AccessToken for graph.microsoft.com
        $refresh_token = $script:refresh_tokens["d3590ed6-52b3-4102-aeff-aad2292ab01c-https://management.core.windows.net"]
        if([string]::IsNullOrEmpty($refresh_token))
        {
            throw "No refresh token found! Use Get-AADIntAccessTokenForAzureCoreManagement with -SaveToCache switch"
        }
        # MSGraph Access Token
        $AccessToken = Get-AccessTokenWithRefreshToken -Resource "https://graph.microsoft.com" -ClientId "d3590ed6-52b3-4102-aeff-aad2292ab01c" -TenantId (Read-Accesstoken $AccessToken).tid -RefreshToken $refresh_token -SaveToCache $true

        # Get the users and some relevant information
        if([String]::IsNullOrEmpty($GroupId))
        {
            $users = Call-MSGraphAPI -MaxResults $MaxResults -AccessToken $AccessToken -API "users" -ApiVersion "v1.0" -QueryString "`$select=id,displayName,userPrincipalName,onPremisesImmutableId,onPremisesLastSyncDateTime,onPremisesSamAccountName,onPremisesSecurityIdentifier,refreshTokensValidFromDateTime,signInSessionsValidFromDateTime,proxyAddresses,businessPhones,identities"
        }

        # Get the groups
        if($Groups -or $GroupMembers -or $GroupId)
        {
            $groupsAPI="groups"
            $groupQS = ""
            if($GroupMembers -or $GroupId)
            {
                $groupQS="`$expand=members"
            }
            if($GroupId)
            {
                $groupsAPI="groups/$GroupId/"
            }
            $groupResults = Call-MSGraphAPI -MaxResults $MaxResults -AccessToken $AccessToken -API $groupsAPI -ApiVersion "v1.0" -QueryString $groupQS
        }
        $attributes=@{
            "Users" =  $users
            "Groups" = $groupResults
        }

        # Print out some relevant information
        Write-Host "Users:        $($Users.count)"
        Write-Host "Groups:       $(if($GroupId -and $groupResults -ne $null){1}else{$groupResults.count})"

        # Return
        New-Object psobject -Property $attributes
    }
}
