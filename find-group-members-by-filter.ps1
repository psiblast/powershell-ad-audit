# ==============================================================
#  find-group-members-by-filter.ps1
#  Finds AD groups whose name matches a wildcard filter and lists
#  all direct members (users, groups, computers) for each match.
#
#  The filter uses standard PowerShell wildcards. You only need
#  to supply the inner pattern — leading and trailing * are added
#  automatically so "_SRV_" will match "SR_SRV_server",
#  "APP_SRV_web", etc.
#
#  Usage - interactive:
#    .\find-group-members-by-filter.ps1
#
#  Usage - with a filter:
#    .\find-group-members-by-filter.ps1 -Filter "_SRV_"
#
#  Usage - with a specific OU subtree:
#    .\find-group-members-by-filter.ps1 -Filter "_SRV_" -SearchBase "OU=Servers,DC=domain,DC=local"
#
#  Usage - with custom output path:
#    .\find-group-members-by-filter.ps1 -Filter "_SRV_" -OutputPath "C:\Audit\srv_groups.csv"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [string]$Filter,

    [Parameter(Mandatory = $false)]
    [string]$SearchBase,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# --- Prompt if no filter supplied -----------------------------
if (-not $Filter) {
    $Filter = Read-Host "Enter a group name filter (wildcards added automatically, e.g. _SRV_)"
}

if ([string]::IsNullOrWhiteSpace($Filter)) {
    Write-Error "Filter cannot be empty."
    exit 1
}

# Wrap the input in wildcards so a partial name always matches
$wildcardFilter = "*$Filter*"

Write-Host ""
Write-Host "Filter      : $wildcardFilter" -ForegroundColor Cyan

if ($SearchBase) {
    Write-Host "Search base : $SearchBase" -ForegroundColor Cyan
}
else {
    Write-Host "Search base : entire domain" -ForegroundColor Cyan
}

Write-Host "Fetching matching groups..." -ForegroundColor Cyan

# --- Find matching groups -------------------------------------
$adProperties = "Name", "SamAccountName", "DistinguishedName", "Description",
                "GroupScope", "GroupCategory", "Members", "MemberOf"

try {
    $getGroupParams = @{
        Filter      = "Name -like '$wildcardFilter'"
        Properties  = $adProperties
        ErrorAction = "Stop"
    }

    if ($SearchBase) {
        $getGroupParams["SearchBase"]  = $SearchBase
        $getGroupParams["SearchScope"] = "Subtree"
    }

    $matchedGroups = @(Get-ADGroup @getGroupParams)
}
catch {
    Write-Error "Failed to query Active Directory. $_"
    exit 1
}

if ($matchedGroups.Count -eq 0) {
    Write-Host "No groups found matching '$wildcardFilter'." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($matchedGroups.Count) group(s). Resolving members..." -ForegroundColor Cyan
Write-Host ""

# --- Process each group ---------------------------------------
$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($group in ($matchedGroups | Sort-Object Name)) {

    $memberDNs = if ($group.Members) { @($group.Members) } else { @() }

    Write-Host "  $($group.Name) ($($memberDNs.Count) direct member(s))" -ForegroundColor Gray

    if ($memberDNs.Count -eq 0) {
        # Still emit one row so the group appears in the CSV even when empty
        $allRows.Add([PSCustomObject]@{
            GroupName        = $group.Name
            GroupSamAccount  = $group.SamAccountName
            GroupDN          = $group.DistinguishedName
            GroupScope       = $group.GroupScope.ToString()
            GroupCategory    = $group.GroupCategory.ToString()
            GroupDescription = if ($group.Description) { $group.Description } else { "" }
            MemberName       = "(no members)"
            MemberSamAccount = ""
            MemberType       = ""
            MemberEnabled    = ""
            MemberDN         = ""
        })
        continue
    }

    foreach ($memberDN in $memberDNs) {
        $memberName    = $memberDN   # fallback if lookup fails
        $memberSam     = ""
        $memberType    = "Unknown"
        $memberEnabled = ""

        try {
            # Try user first, then group, then computer
            try {
                $adObj = Get-ADUser -Identity $memberDN `
                    -Properties DisplayName, SamAccountName, Enabled `
                    -ErrorAction Stop
                $memberName    = $adObj.DisplayName
                $memberSam     = $adObj.SamAccountName
                $memberType    = "User"
                $memberEnabled = $adObj.Enabled.ToString()
            }
            catch {
                try {
                    $adObj = Get-ADGroup -Identity $memberDN `
                        -Properties Name, SamAccountName `
                        -ErrorAction Stop
                    $memberName = $adObj.Name
                    $memberSam  = $adObj.SamAccountName
                    $memberType = "Group"
                }
                catch {
                    try {
                        $adObj = Get-ADComputer -Identity $memberDN `
                            -Properties Name, SamAccountName, Enabled `
                            -ErrorAction Stop
                        $memberName    = $adObj.Name
                        $memberSam     = $adObj.SamAccountName
                        $memberType    = "Computer"
                        $memberEnabled = $adObj.Enabled.ToString()
                    }
                    catch {
                        Write-Warning "Could not resolve member DN: $memberDN"
                    }
                }
            }
        }
        catch {
            Write-Warning "Unexpected error resolving member DN: $memberDN - $_"
        }

        $allRows.Add([PSCustomObject]@{
            GroupName        = $group.Name
            GroupSamAccount  = $group.SamAccountName
            GroupDN          = $group.DistinguishedName
            GroupScope       = $group.GroupScope.ToString()
            GroupCategory    = $group.GroupCategory.ToString()
            GroupDescription = if ($group.Description) { $group.Description } else { "" }
            MemberName       = $memberName
            MemberSamAccount = $memberSam
            MemberType       = $memberType
            MemberEnabled    = $memberEnabled
            MemberDN         = $memberDN
        })
    }
}

Write-Host ""

# --- Console summary ------------------------------------------
$userRows     = $allRows | Where-Object { $_.MemberType -eq "User" }
$groupRows    = $allRows | Where-Object { $_.MemberType -eq "Group" }
$computerRows = $allRows | Where-Object { $_.MemberType -eq "Computer" }
$emptyGroups  = $allRows | Where-Object { $_.MemberName -eq "(no members)" }
$disabledRows = $userRows | Where-Object { $_.MemberEnabled -eq "False" }

Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  Filter             : $wildcardFilter"
Write-Host "  Groups matched     : $($matchedGroups.Count)"
Write-Host "  Empty groups       : $($emptyGroups.Count)" -ForegroundColor $(if ($emptyGroups.Count -gt 0) { "Yellow" } else { "White" })
Write-Host ""
Write-Host "  Direct members:"
Write-Host ("    {0,-20} {1}" -f "Users:",       $userRows.Count)
Write-Host ("    {0,-20} {1}" -f "  - Disabled:", $disabledRows.Count) -ForegroundColor $(if ($disabledRows.Count -gt 0) { "Red" } else { "White" })
Write-Host ("    {0,-20} {1}" -f "Groups:",      $groupRows.Count)
Write-Host ("    {0,-20} {1}" -f "Computers:",   $computerRows.Count)

# Per-group breakdown
Write-Host ""
Write-Host "  Per-group member counts:" -ForegroundColor White

foreach ($group in ($matchedGroups | Sort-Object Name)) {
    $groupRows2 = $allRows | Where-Object { $_.GroupDN -eq $group.DistinguishedName }
    $isEmpty    = ($groupRows2 | Where-Object { $_.MemberName -eq "(no members)" }).Count -gt 0
    $uCount     = ($groupRows2 | Where-Object { $_.MemberType -eq "User" }).Count
    $gCount     = ($groupRows2 | Where-Object { $_.MemberType -eq "Group" }).Count
    $cCount     = ($groupRows2 | Where-Object { $_.MemberType -eq "Computer" }).Count
    $color      = if ($isEmpty) { "Yellow" } else { "White" }
    $detail     = if ($isEmpty) { "(empty)" } else { "$uCount user(s), $gCount group(s), $cCount computer(s)" }

    Write-Host ("    {0,-45} {1}" -f $group.Name, $detail) -ForegroundColor $color
}

# --- Build output path ----------------------------------------
if (-not $OutputPath) {
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeName   = $Filter -replace "[^a-zA-Z0-9_-]", "_"
    $OutputPath = ".\GroupMembersByFilter_$($safeName)_$timestamp.csv"
}

# --- Export ---------------------------------------------------
$allRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host "  Total rows  : $($allRows.Count)"
Write-Host "  Output file : $((Resolve-Path $OutputPath).Path)"