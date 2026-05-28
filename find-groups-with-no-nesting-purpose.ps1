# ==============================================================
#  find-groups-with-no-nesting-purpose.ps1
#  Identifies AD groups that play no role in any group nesting
#  structure. Groups are classified into four categories:
#
#    Empty             - Not nested anywhere and has no members.
#                        Almost certainly safe to delete.
#
#    EmptyNested       - Nested inside other group(s) but contains
#                        no members. Occupies a slot in the nesting
#                        tree but contributes nothing.
#
#    UsersOnly         - Not nested anywhere and contains only user
#                        members. May be used for direct resource
#                        access (e.g. file shares) but plays no role
#                        in the AD nesting hierarchy.
#
#    TopLevelContainer - Not nested anywhere but contains sub-groups.
#                        This is the root of a nesting tree, which
#                        is often intentional - included for visibility.
#
#  Built-in system groups (CN=Builtin, CN=Users at the domain root,
#  and well-known default groups) are excluded by default.
#
#  Usage - interactive:
#    .\find-groups-with-no-nesting-purpose.ps1
#
#  Usage - entire domain:
#    .\find-groups-with-no-nesting-purpose.ps1 -Scope Domain
#
#  Usage - specific OU and its children:
#    .\find-groups-with-no-nesting-purpose.ps1 -Scope OU -OUName "Helpdesk"
#
#  Usage - include built-in/default groups in results:
#    .\find-groups-with-no-nesting-purpose.ps1 -Scope Domain -IncludeBuiltin
#
#  Usage - with custom output path:
#    .\find-groups-with-no-nesting-purpose.ps1 -Scope Domain -OutputPath "C:\Audit\orphaned_groups.csv"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("Domain", "OU")]
    [string]$Scope,

    [Parameter(Mandatory = $false)]
    [string]$OUName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeBuiltin
)

# --- Well-known default group names to exclude ----------------
$builtinGroupNames = @(
    "Domain Computers",
    "Domain Controllers",
    "Schema Admins",
    "Enterprise Admins",
    "Cert Publishers",
    "Domain Admins",
    "Domain Users",
    "Domain Guests",
    "Group Policy Creator Owners",
    "RAS and IAS Servers",
    "Allowed RODC Password Replication Group",
    "Denied RODC Password Replication Group",
    "Read-only Domain Controllers",
    "Enterprise Read-only Domain Controllers",
    "Cloneable Domain Controllers",
    "Protected Users",
    "Key Admins",
    "Enterprise Key Admins",
    "DnsAdmins",
    "DnsUpdateProxy",
    "WinRMRemoteWMIUsers__"
)

function Is-BuiltinGroup {
    param (
        [Microsoft.ActiveDirectory.Management.ADGroup]$Group,
        [string]$BuiltinContainerDN,
        [string]$UsersContainerDN
    )

    if ($Group.DistinguishedName -like "*,$BuiltinContainerDN" -or
        $Group.DistinguishedName -like "*,$UsersContainerDN") {
        return $true
    }

    foreach ($name in $builtinGroupNames) {
        if ($Group.Name -ieq $name) { return $true }
    }

    return $false
}

# --- Helper: Resolve parent group names from lookup table -----
# No AD calls - uses the pre-built hashtable
function Resolve-ParentGroupNames {
    param ([string[]]$MemberOfDNs)

    $names = foreach ($dn in $MemberOfDNs) {
        if ($groupLookup.ContainsKey($dn)) { $groupLookup[$dn] } else { $dn }
    }

    return ($names | Sort-Object) -join " | "
}

# --- Helper: Process a single group ---------------------------
# No AD calls inside this function - all data comes from pre-built lookups
function Get-GroupAuditRow {
    param (
        [Microsoft.ActiveDirectory.Management.ADGroup]$Group,
        [string]$BuiltinContainerDN,
        [string]$UsersContainerDN
    )

    if (-not $IncludeBuiltin -and (Is-BuiltinGroup -Group $Group -BuiltinContainerDN $BuiltinContainerDN -UsersContainerDN $UsersContainerDN)) {
        return $null
    }

    $memberOf = if ($Group.MemberOf) { @($Group.MemberOf) } else { @() }
    $isNested = $memberOf.Count -gt 0

    # Count members using pre-built lookups - no AD calls
    $memberDNs        = if ($Group.Members) { @($Group.Members) } else { @() }
    $groupMemberCount = 0
    $userMemberCount  = 0
    $otherMemberCount = 0

    foreach ($dn in $memberDNs) {
        if     ($groupLookup.ContainsKey($dn)) { $groupMemberCount++ }
        elseif ($userDNs.Contains($dn))        { $userMemberCount++  }
        else                                   { $otherMemberCount++ }
    }

    # Classify inline - avoids [bool] parameter binding quirks
    $total          = $groupMemberCount + $userMemberCount + $otherMemberCount
    $classification = $null

    if     (-not $isNested -and $total            -eq 0) { $classification = "Empty" }
    elseif ($isNested      -and $total            -eq 0) { $classification = "EmptyNested" }
    elseif (-not $isNested -and $groupMemberCount -eq 0) { $classification = "UsersOnly" }
    elseif (-not $isNested -and $groupMemberCount -gt 0) { $classification = "TopLevelContainer" }

    if ($null -eq $classification) { return $null }

    $nestedIn = if ($isNested) { Resolve-ParentGroupNames -MemberOfDNs $memberOf } else { "" }

    return [PSCustomObject]@{
        GroupName         = $Group.Name
        SamAccountName    = $Group.SamAccountName
        DistinguishedName = $Group.DistinguishedName
        Description       = if ($Group.Description) { $Group.Description } else { "" }
        GroupScope        = $Group.GroupScope.ToString()
        GroupCategory     = $Group.GroupCategory.ToString()
        Classification    = $classification
        UserMembers       = $userMemberCount
        GroupMembers      = $groupMemberCount
        OtherMembers      = $otherMemberCount
        TotalMembers      = $total
        NestedInCount     = $memberOf.Count
        NestedIn          = $nestedIn
    }
}

# --- Prompt if no scope supplied ------------------------------
if (-not $Scope) {
    $choice = Read-Host "Audit the entire [D]omain or a specific [O]U? (D/O)"
    if ($choice -match "^[Oo]") {
        $Scope = "OU"
    }
    else {
        $Scope = "Domain"
    }
}

if ($Scope -eq "OU" -and -not $OUName) {
    $OUName = Read-Host "Enter the OU name or Distinguished Name (e.g. 'Helpdesk' or 'OU=Helpdesk,DC=domain,DC=local')"
}

Write-Host ""

# --- Resolve built-in container DNs --------------------------
$rootDSE            = Get-ADRootDSE
$domainDN           = $rootDSE.defaultNamingContext
$builtinContainerDN = "CN=Builtin,$domainDN"
$usersContainerDN   = "CN=Users,$domainDN"

# --- Build the list of groups to inspect ---------------------
# Members property fetched here so we never need Get-ADGroupMember in the loop
$groupList    = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADGroup]]::new()
$adProperties = "Name", "SamAccountName", "DistinguishedName", "Description",
                "GroupScope", "GroupCategory", "MemberOf", "Members"

if ($Scope -eq "Domain") {
    Write-Host "Scope: Entire domain" -ForegroundColor Cyan
    Write-Host "Fetching all groups..." -ForegroundColor Cyan

    $allGroups = Get-ADGroup -Filter * -Properties $adProperties
    foreach ($g in $allGroups) { $groupList.Add($g) }
}
else {
    Write-Host "Scope: OU subtree - $OUName" -ForegroundColor Cyan
    Write-Host "Fetching groups..." -ForegroundColor Cyan

    try {
        $searchBase = if ($OUName -match "^OU=") {
            $OUName
        }
        else {
            $ou = Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'" -ErrorAction Stop |
                  Select-Object -First 1
            if (-not $ou) {
                Write-Error "OU '$OUName' not found in Active Directory."
                exit 1
            }
            $ou.DistinguishedName
        }

        $allGroups = Get-ADGroup -Filter * -SearchBase $searchBase -SearchScope Subtree -Properties $adProperties
        foreach ($g in $allGroups) { $groupList.Add($g) }
    }
    catch {
        Write-Error "Could not resolve OU '$OUName'. $_"
        exit 1
    }
}

Write-Host "Found $($groupList.Count) group(s) to inspect." -ForegroundColor Cyan
if (-not $IncludeBuiltin) {
    Write-Host "(Built-in and default system groups will be excluded. Use -IncludeBuiltin to include them.)" -ForegroundColor DarkGray
}
Write-Host ""

# --- Build group DN -> name lookup table ---------------------
Write-Host "Building group lookup table..." -ForegroundColor Cyan
$groupLookup = @{}
foreach ($g in $groupList) {
    $groupLookup[$g.DistinguishedName] = $g.Name
}
Write-Host "  Done. ($($groupLookup.Count) entries)" -ForegroundColor Gray

# --- Build user DN lookup set --------------------------------
# One bulk query so the processing loop needs no per-group AD calls
Write-Host "Building user lookup set..." -ForegroundColor Cyan
$userDNs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
Get-ADUser -Filter * -Properties DistinguishedName | ForEach-Object {
    [void]$userDNs.Add($_.DistinguishedName)
}
Write-Host "  Done. ($($userDNs.Count) users)" -ForegroundColor Gray
Write-Host ""

# --- Process each group ---------------------------------------
$allRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$processed = 0

foreach ($group in $groupList) {
    $processed++
    if ($processed % 50 -eq 0) {
        Write-Host "  Processed $processed / $($groupList.Count) groups..." -ForegroundColor Gray
    }

    $row = Get-GroupAuditRow `
        -Group              $group `
        -BuiltinContainerDN $builtinContainerDN `
        -UsersContainerDN   $usersContainerDN

    if ($row) { $allRows.Add($row) }
}

if ($allRows.Count -eq 0) {
    Write-Host "No groups without a nesting purpose found." -ForegroundColor Green
    exit 0
}

# --- Console summary ------------------------------------------
$byClass = $allRows | Group-Object Classification

Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  GROUPS WITH NO NESTING PURPOSE" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host ""

$displayOrder = @(
    @{ Name = "Empty";             Color = "Red";    Note = "no members, not nested anywhere - safe to delete" }
    @{ Name = "EmptyNested";       Color = "Yellow"; Note = "nested inside other group(s) but has no members" }
    @{ Name = "UsersOnly";         Color = "White";  Note = "not nested anywhere, only has user members" }
    @{ Name = "TopLevelContainer"; Color = "Gray";   Note = "root of a nesting tree, not nested itself - likely intentional" }
)

foreach ($entry in $displayOrder) {
    $group = $byClass | Where-Object { $_.Name -eq $entry.Name }
    if (-not $group) { continue }

    $count = $group.Count
    Write-Host ("  {0,-22} ({1}) - {2}" -f $entry.Name, $count, $entry.Note) -ForegroundColor $entry.Color

    foreach ($row in ($group.Group | Sort-Object GroupName)) {
        $detail = switch ($entry.Name) {
            "EmptyNested"       { "nested in: $($row.NestedIn)" }
            "UsersOnly"         { "$($row.UserMembers) user(s)" }
            "TopLevelContainer" { "$($row.GroupMembers) sub-group(s), $($row.UserMembers) user(s)" }
            default             { "" }
        }
        $suffix = if ($detail) { "  [$detail]" } else { "" }
        Write-Host ("    {0,-40} {1}" -f $row.GroupName, $suffix) -ForegroundColor $entry.Color
    }

    Write-Host ""
}

# --- Build output path ----------------------------------------
if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if ($Scope -eq "Domain") {
        $OutputPath = ".\NoNestingPurpose_FullDomain_$timestamp.csv"
    }
    else {
        $safeName   = $OUName -replace "[^a-zA-Z0-9_-]", "_"
        $OutputPath = ".\NoNestingPurpose_$($safeName)_$timestamp.csv"
    }
}

# --- Export CSV -----------------------------------------------
$allRows |
    Sort-Object Classification, GroupName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

# --- Final summary --------------------------------------------
$countEmpty     = ($allRows | Where-Object { $_.Classification -eq "Empty"            }).Count
$countEmptyNest = ($allRows | Where-Object { $_.Classification -eq "EmptyNested"      }).Count
$countUsers     = ($allRows | Where-Object { $_.Classification -eq "UsersOnly"        }).Count
$countTopLevel  = ($allRows | Where-Object { $_.Classification -eq "TopLevelContainer"}).Count

Write-Host "Done!" -ForegroundColor Green
Write-Host "  Groups inspected      : $($groupList.Count)"
Write-Host "  Empty                 : $countEmpty"     -ForegroundColor $(if ($countEmpty     -gt 0) { "Red"    } else { "White" })
Write-Host "  Empty but nested      : $countEmptyNest" -ForegroundColor $(if ($countEmptyNest -gt 0) { "Yellow" } else { "White" })
Write-Host "  Users only (flat)     : $countUsers"
Write-Host "  Top-level containers  : $countTopLevel"  -ForegroundColor Gray
Write-Host "  Output file           : $((Resolve-Path $OutputPath).Path)"