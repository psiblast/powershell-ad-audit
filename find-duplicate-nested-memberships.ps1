# ==============================================================
#  find-duplicate-nested-memberships.ps1
#  Resolves all nested group memberships for a user or for every
#  user in a group, and identifies cases where the same group is
#  reached via more than one direct membership source.
#
#  This helps surface redundant or conflicting access paths,
#  e.g. a user who is in both "Team-A" and "Team-B" and both
#  groups are nested inside "App-Access", giving the user two
#  separate routes to the same effective permission.
#
#  Usage - interactive:
#    .\find-duplicate-nested-memberships.ps1
#
#  Usage - target a single user:
#    .\find-duplicate-nested-memberships.ps1 -Identity "jsmith" -Type User
#
#  Usage - target a group (runs for all members):
#    .\find-duplicate-nested-memberships.ps1 -Identity "Helpdesk" -Type Group
#
#  Usage - with custom output path:
#    .\find-duplicate-nested-memberships.ps1 -Identity "Helpdesk" -Type Group -OutputPath "C:\Audit\duplicates.csv"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [string]$Identity,

    [Parameter(Mandatory = $false)]
    [ValidateSet("User", "Group")]
    [string]$Type,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# --- Helper: Get all ancestor groups of a given group ---------
#     Returns a flat list of every group that this group belongs
#     to, directly or transitively.
function Get-AncestorGroups {
    param (
        [string]$GroupDN,
        [System.Collections.Generic.HashSet[string]]$Visited
    )

    $ancestors = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADGroup]]::new()

    try {
        $group = Get-ADGroup -Identity $GroupDN -Properties MemberOf -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not retrieve group DN: $GroupDN - $_"
        return $ancestors
    }

    foreach ($parentDN in $group.MemberOf) {
        if ($Visited.Contains($parentDN)) { continue }
        [void]$Visited.Add($parentDN)

        try {
            $parent = Get-ADGroup -Identity $parentDN -ErrorAction Stop
            $ancestors.Add($parent)

            $higher = Get-AncestorGroups -GroupDN $parentDN -Visited $Visited
            $ancestors.AddRange($higher)
        }
        catch {
            Write-Warning "Could not retrieve parent group DN: $parentDN - $_"
        }
    }

    return $ancestors
}

# --- Helper: Find duplicate membership paths for one user -----
#     For each direct group the user belongs to, resolves all
#     ancestor groups. If any ancestor group is reachable from
#     more than one direct membership, that is a duplicate path.
function Get-DuplicatePaths {
    param (
        [Microsoft.ActiveDirectory.Management.ADUser]$ADUser
    )

    # Map: ancestor group DN -> list of direct source group names
    $ancestorSources = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($directDN in $ADUser.MemberOf) {
        try {
            $directGroup = Get-ADGroup -Identity $directDN -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not retrieve direct group DN: $directDN - $_"
            continue
        }

        # The direct group itself counts as an ancestor (it is a direct membership)
        if (-not $ancestorSources.ContainsKey($directDN)) {
            $ancestorSources[$directDN] = [PSCustomObject]@{
                GroupName = $directGroup.Name
                DN        = $directDN
                Sources   = [System.Collections.Generic.List[string]]::new()
            }
        }
        $ancestorSources[$directDN].Sources.Add("(direct) $($directGroup.Name)")

        # Walk up the tree from this direct group
        $visited   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $ancestors = Get-AncestorGroups -GroupDN $directDN -Visited $visited

        foreach ($anc in $ancestors) {
            if (-not $ancestorSources.ContainsKey($anc.DistinguishedName)) {
                $ancestorSources[$anc.DistinguishedName] = [PSCustomObject]@{
                    GroupName = $anc.Name
                    DN        = $anc.DistinguishedName
                    Sources   = [System.Collections.Generic.List[string]]::new()
                }
            }
            $ancestorSources[$anc.DistinguishedName].Sources.Add($directGroup.Name)
        }
    }

    # Return only entries with more than one source (the duplicates)
    return $ancestorSources.Values |
        Where-Object { $_.Sources.Count -gt 1 } |
        Sort-Object { $_.Sources.Count } -Descending
}

# --- Helper: Process and display results for one user ---------
function Invoke-UserAudit {
    param (
        [Microsoft.ActiveDirectory.Management.ADUser]$ADUser,
        [System.Collections.Generic.List[PSCustomObject]]$Rows,
        [switch]$Verbose
    )

    Write-Host ("  Processing : {0} ({1})..." -f $ADUser.SamAccountName, $ADUser.DisplayName) -ForegroundColor Gray

    $duplicates = Get-DuplicatePaths -ADUser $ADUser

    if ($duplicates.Count -eq 0) {
        if ($Verbose) {
            Write-Host ("    {0,-25} no duplicate paths found" -f $ADUser.SamAccountName) -ForegroundColor Gray
        }
        return
    }

    foreach ($dup in $duplicates) {
        $color = if ($dup.Sources.Count -ge 4) { "Red" } else { "Yellow" }
        $flag  = if ($dup.Sources.Count -ge 4) { " <-- investigate" } else { "" }

        Write-Host ("    {0,-25} reaches '{1}' via {2} sources: {3}{4}" -f `
            $ADUser.SamAccountName, `
            $dup.GroupName, `
            $dup.Sources.Count, `
            (($dup.Sources | Sort-Object -Unique) -join ", "), `
            $flag) -ForegroundColor $color

        $Rows.Add([PSCustomObject]@{
            Username       = $ADUser.SamAccountName
            DisplayName    = $ADUser.DisplayName
            UPN            = $ADUser.UserPrincipalName
            DuplicateGroup = $dup.GroupName
            SourceCount    = $dup.Sources.Count
            Sources        = (($dup.Sources | Sort-Object -Unique) -join " | ")
        })
    }
}

# --- Prompt if no parameters supplied -------------------------
if (-not $Identity) {
    $Identity = Read-Host "Enter a username or group name"
}

if (-not $Type) {
    $raw  = Read-Host "Is this a [U]ser or [G]roup?"
    $Type = switch ($raw.Trim().ToUpper()) {
        "U"     { "User"  }
        "USER"  { "User"  }
        "G"     { "Group" }
        "GROUP" { "Group" }
        default {
            Write-Error "Invalid input. Please enter U or G."
            exit 1
        }
    }
}

Write-Host ""

# --- Resolve the target and collect users to process ----------
$usersToProcess = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADUser]]::new()

if ($Type -eq "User") {
    try {
        $adUser = Get-ADUser -Identity $Identity `
            -Properties DisplayName, UserPrincipalName, EmailAddress, MemberOf `
            -ErrorAction Stop
        $usersToProcess.Add($adUser)
        Write-Host "Found user  : $($adUser.SamAccountName) ($($adUser.DisplayName))" -ForegroundColor Cyan
    }
    catch {
        Write-Error "User '$Identity' not found in Active Directory. $_"
        exit 1
    }
}
elseif ($Type -eq "Group") {
    try {
        $adGroup = Get-ADGroup -Identity $Identity -ErrorAction Stop
        Write-Host "Found group : $($adGroup.Name)" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Group '$Identity' not found in Active Directory. $_"
        exit 1
    }

    Write-Host "Fetching members..." -ForegroundColor Cyan
    $members = Get-ADGroupMember -Identity $adGroup -Recursive |
        Where-Object { $_.objectClass -eq "user" }

    if (-not $members) {
        Write-Host "No user members found in group '$Identity'." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "  Found $($members.Count) user(s). Resolving memberships..." -ForegroundColor Gray

    foreach ($m in $members) {
        try {
            $adUser = Get-ADUser -Identity $m.distinguishedName `
                -Properties DisplayName, UserPrincipalName, EmailAddress, MemberOf `
                -ErrorAction Stop
            $usersToProcess.Add($adUser)
        }
        catch {
            Write-Warning "Could not retrieve user: $($m.SamAccountName) - $_"
        }
    }
}

# --- Run audit ------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  DUPLICATE NESTED MEMBERSHIP AUDIT" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  Target       : $Identity ($Type)"
Write-Host "  Users checked: $($usersToProcess.Count)"
Write-Host ""

$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($u in $usersToProcess) {
    Invoke-UserAudit -ADUser $u -Rows $allRows -Verbose:($usersToProcess.Count -eq 1)
}

$affectedUsers = ($allRows | Select-Object -ExpandProperty Username -Unique).Count

Write-Host ""
Write-Host "  Affected users        : $affectedUsers of $($usersToProcess.Count)"
Write-Host "  Duplicate paths found : $($allRows.Count)"

if ($allRows.Count -eq 0) {
    Write-Host ""
    Write-Host "  No duplicate nested membership paths found." -ForegroundColor Green
}

# --- Export CSV -----------------------------------------------
if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeName  = $Identity -replace "[^a-zA-Z0-9_-]", "_"
    $OutputPath = ".\DuplicateMemberships_$($safeName)_$timestamp.csv"
}

$allRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host "  Total rows  : $($allRows.Count)"
Write-Host "  Output file : $((Resolve-Path $OutputPath).Path)"