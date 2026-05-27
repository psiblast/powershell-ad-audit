# ==============================================================
#  compare-adgroup-members.ps1
#  Compares the membership of two AD groups side by side.
#  Identifies members unique to each group and members that
#  appear in both, with a summary and optional CSV export.
#
#  Usage - interactive:
#    .\compare-adgroup-members.ps1
#
#  Usage - with parameters:
#    .\compare-adgroup-members.ps1 -Group1 "Sales-Team" -Group2 "Marketing-Team"
#
#  Usage - with custom output path:
#    .\compare-adgroup-members.ps1 -Group1 "Sales-Team" -Group2 "Marketing-Team" -OutputPath "C:\Audit\comparison.csv"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [string]$Group1,

    [Parameter(Mandatory = $false)]
    [string]$Group2,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# --- Helper: Resolve an AD group and return its members -------
function Get-GroupMembers {
    param (
        [string]$GroupName
    )

    try {
        $adGroup = Get-ADGroup -Identity $GroupName -ErrorAction Stop
    }
    catch {
        Write-Error "Group '$GroupName' not found in Active Directory. $_"
        exit 1
    }

    $members = Get-ADGroupMember -Identity $adGroup -Recursive |
        Where-Object { $_.objectClass -eq "user" } |
        ForEach-Object {
            try {
                Get-ADUser -Identity $_.distinguishedName `
                    -Properties DisplayName, UserPrincipalName, EmailAddress `
                    -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not retrieve user: $($_.SamAccountName) - $_"
            }
        }

    return [PSCustomObject]@{
        Group   = $adGroup
        Members = $members
    }
}

# --- Prompt if no parameters supplied -------------------------
if (-not $Group1) {
    $Group1 = Read-Host "Enter the name of the first AD group"
}
if (-not $Group2) {
    $Group2 = Read-Host "Enter the name of the second AD group"
}

# --- Resolve both groups --------------------------------------
Write-Host ""
Write-Host "Resolving groups..." -ForegroundColor Cyan

$result1 = Get-GroupMembers -GroupName $Group1
$result2 = Get-GroupMembers -GroupName $Group2

Write-Host "  Group 1 : $($result1.Group.Name) ($($result1.Members.Count) user(s))" -ForegroundColor Gray
Write-Host "  Group 2 : $($result2.Group.Name) ($($result2.Members.Count) user(s))" -ForegroundColor Gray
Write-Host ""

# --- Index members by SamAccountName -------------------------
$map1 = @{}
$map2 = @{}

foreach ($u in $result1.Members) { if ($u) { $map1[$u.SamAccountName] = $u } }
foreach ($u in $result2.Members) { if ($u) { $map2[$u.SamAccountName] = $u } }

$allSams  = ($map1.Keys + $map2.Keys) | Sort-Object -Unique
$inBoth   = $allSams | Where-Object { $map1.ContainsKey($_) -and $map2.ContainsKey($_) }
$onlyIn1  = $allSams | Where-Object { $map1.ContainsKey($_) -and -not $map2.ContainsKey($_) }
$onlyIn2  = $allSams | Where-Object { $map2.ContainsKey($_) -and -not $map1.ContainsKey($_) }

# --- Build CSV rows -------------------------------------------
$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($sam in $allSams) {
    $user   = if ($map1.ContainsKey($sam)) { $map1[$sam] } else { $map2[$sam] }
    $status = switch ($true) {
        { $map1.ContainsKey($sam) -and $map2.ContainsKey($sam) } { "In Both" }
        { $map1.ContainsKey($sam) }                              { "Only in $($result1.Group.Name)" }
        default                                                   { "Only in $($result2.Group.Name)" }
    }

    $allRows.Add([PSCustomObject]@{
        Username    = $sam
        DisplayName = $user.DisplayName
        UPN         = $user.UserPrincipalName
        Email       = $user.EmailAddress
        Status      = $status
    })
}

# --- Console summary ------------------------------------------
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  COMPARISON SUMMARY" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  Group 1 : $($result1.Group.Name)"
Write-Host "  Group 2 : $($result2.Group.Name)"
Write-Host ""

Write-Host ("  Only in '{0}' ({1}):" -f $result1.Group.Name, $onlyIn1.Count) -ForegroundColor Yellow
foreach ($sam in $onlyIn1) {
    Write-Host ("    {0,-25} {1}" -f $sam, $map1[$sam].DisplayName) -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("  Only in '{0}' ({1}):" -f $result2.Group.Name, $onlyIn2.Count) -ForegroundColor Magenta
foreach ($sam in $onlyIn2) {
    Write-Host ("    {0,-25} {1}" -f $sam, $map2[$sam].DisplayName) -ForegroundColor Magenta
}

Write-Host ""
Write-Host ("  In both groups ({0}):" -f $inBoth.Count) -ForegroundColor Green
foreach ($sam in $inBoth) {
    Write-Host ("    {0,-25} {1}" -f $sam, $map1[$sam].DisplayName) -ForegroundColor Green
}

Write-Host ""
Write-Host "  Totals:" -ForegroundColor White
Write-Host ("    {0,-30} {1}" -f "Members in $($result1.Group.Name):", $result1.Members.Count)
Write-Host ("    {0,-30} {1}" -f "Members in $($result2.Group.Name):", $result2.Members.Count)
Write-Host ("    {0,-30} {1}" -f "Only in $($result1.Group.Name):", $onlyIn1.Count)
Write-Host ("    {0,-30} {1}" -f "Only in $($result2.Group.Name):", $onlyIn2.Count)
Write-Host ("    {0,-30} {1}" -f "In both:", $inBoth.Count)

# --- Export CSV -----------------------------------------------
if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeName1 = $Group1 -replace "[^a-zA-Z0-9_-]", "_"
    $safeName2 = $Group2 -replace "[^a-zA-Z0-9_-]", "_"
    $OutputPath = ".\GroupComparison_$($safeName1)_vs_$($safeName2)_$timestamp.csv"
}

$allRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host "  Total rows  : $($allRows.Count)"
Write-Host "  Output file : $((Resolve-Path $OutputPath).Path)"