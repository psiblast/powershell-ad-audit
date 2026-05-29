# 🛠️ PowerShell Scripts

A collection of utility PowerShell scripts for Active Directory administration and IT operations.

> [!WARNING]
> **Disclaimer:** These scripts are provided as-is. Use them at your own risk. The author takes no responsibility for any damage, data loss, or unintended changes resulting from running these scripts. Always test in a non-production environment first and ensure you understand what a script does before executing it.

---

## 📋 Requirements

- PowerShell 5.1 or later
- **RSAT Active Directory module** (`ActiveDirectory`) — required by AD scripts
  - Install via: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
- Appropriate permissions to query Active Directory

---

## 📁 Scripts

| Script | Description |
|---|---|
| [`compare-adgroup-members.ps1`](#compare-adgroup-membersps1) | Compare membership of two AD groups side by side, identifying shared and unique members |
| [`compare-aduser-group-memberships.ps1`](#compare-aduser-group-membershipsps1) | Compare group memberships across all members of an AD group to surface outliers |
| [`find-duplicate-nested-memberships.ps1`](#find-duplicate-nested-membershipsps1) | Find users who reach the same group via more than one nested membership path |
| [`find-group-members-by-filter.ps1`](#find-group-members-by-filterps1) | Find AD groups matching a name filter and list all their direct members |
| [`find-groups-with-no-nesting-purpose.ps1`](#find-groups-with-no-nesting-purposeps1) | Identify AD groups that play no role in any group nesting structure |
| [`get-ad-ou-delegation-audit.ps1`](#get-ad-ou-delegation-auditps1) | Export custom/non-default OU delegations across an entire domain or OU subtree |
| [`get-group-nesting-audit.ps1`](#get-group-nesting-auditps1) | Audit the full nesting tree of one or more AD groups |
| [`get-nested-groups-of-user-or-group.ps1`](#get-nested-groups-of-user-or-groupps1) | Export all group memberships (direct & nested) for a user or group |

---

### `compare-adgroup-members.ps1`

Compares the membership of two AD groups side by side, showing which users appear in both, which are unique to each group, and a full breakdown in both the console and a CSV export.

**Features**
- Resolves both groups recursively so nested members are included
- Colour-coded console output: yellow (only in group 1), magenta (only in group 2), green (in both)
- Status column in CSV makes it easy to filter in Excel
- Includes UPN and email address alongside display name for easier identification

**Usage**

```powershell
# Interactive mode (prompts for both group names)
.\compare-adgroup-members.ps1

# With parameters
.\compare-adgroup-members.ps1 -Group1 "Sales-Team" -Group2 "Marketing-Team"

# With a custom output path
.\compare-adgroup-members.ps1 -Group1 "Sales-Team" -Group2 "Marketing-Team" -OutputPath "C:\Audit\comparison.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `Username` | SamAccountName of the user |
| `DisplayName` | Display name of the user |
| `UPN` | User Principal Name |
| `Email` | Email address from AD |
| `Status` | `In Both`, `Only in <Group1>`, or `Only in <Group2>` |

Output is saved as a CSV in the current directory, e.g.:
- `GroupComparison_Sales-Team_vs_Marketing-Team_20250515_143022.csv`

---

### `compare-aduser-group-memberships.ps1`

Compares group memberships across all members of an AD group, identifying which memberships are common to everyone (the baseline) and which are unique to individual users (the outliers worth investigating). Useful for spotting privilege creep or misconfigured accounts within a peer group.

**Features**
- Resolves full recursive group memberships for every user in the target group
- Classifies each membership as `Common` (shared by all) or `Unique to this user`
- Console summary ranked by unique membership count — largest outliers flagged in red
- Colour-coded output: grey (0 unique), white (1–10), yellow (11–30), red (31+, flagged for investigation)

**Usage**

```powershell
# Interactive mode (prompts for group name)
.\compare-aduser-group-memberships.ps1

# With a group name
.\compare-aduser-group-memberships.ps1 -GroupName "Helpdesk"

# With a custom output path
.\compare-aduser-group-memberships.ps1 -GroupName "Helpdesk" -OutputPath "C:\Audit\helpdesk.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `Username` | SamAccountName of the user |
| `DisplayName` | Display name of the user |
| `Status` | `Common` (all users share this) or `Unique to this user` |
| `GroupName` | Name of the AD group |
| `MembershipType` | `Direct` or `Nested` |
| `InheritedFrom` | The group that granted nested membership |
| `Description` | Group description from AD |

Output is saved as a CSV in the current directory, e.g.:
- `PeerComparison_Helpdesk_20250515_143022.csv`

---

### `find-duplicate-nested-memberships.ps1`

Identifies users who reach the same group via more than one direct membership source — for example, a user in both `Team-A` and `Team-B` where both groups are nested inside `App-Access`, giving them two separate routes to the same effective permission. Useful for cleaning up redundant access paths and simplifying group structures.

**Features**
- Works against a single user or all users within a group
- For each user, walks every direct membership upward recursively and maps which ancestor groups are reachable from multiple sources
- Console output sorted by source count — entries with 4 or more sources flagged in red for investigation
- Verbose mode (single user) shows all findings per user; group mode summarises only affected users

**Usage**

```powershell
# Interactive mode (prompts for identity and type)
.\find-duplicate-nested-memberships.ps1

# Single user
.\find-duplicate-nested-memberships.ps1 -Identity "jsmith" -Type User

# All members of a group
.\find-duplicate-nested-memberships.ps1 -Identity "Helpdesk" -Type Group

# With a custom output path
.\find-duplicate-nested-memberships.ps1 -Identity "Helpdesk" -Type Group -OutputPath "C:\Audit\duplicates.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `Username` | SamAccountName of the user |
| `DisplayName` | Display name of the user |
| `UPN` | User Principal Name |
| `DuplicateGroup` | The group reachable via multiple paths |
| `SourceCount` | Number of distinct direct memberships leading to that group |
| `Sources` | Pipe-separated list of the direct groups that each provide a route |

Output is saved as a CSV in the current directory, e.g.:
- `DuplicateMemberships_jsmith_20250515_143022.csv`
- `DuplicateMemberships_Helpdesk_20250515_143022.csv`

---

### `find-group-members-by-filter.ps1`

Finds AD groups whose name matches a wildcard filter and lists all direct members (users, groups, and computers) for each match. Useful for quickly auditing a family of related groups without knowing their exact names.

**Features**
- Leading and trailing wildcards are added automatically, so a filter like `_SRV_` will match any group name containing that string
- Resolves each member as a user, group, or computer and reports type, enabled status, and SamAccountName
- Empty groups are still included in the CSV so they don't go unnoticed
- Can be scoped to a specific OU subtree via `-SearchBase`
- Console summary shows a per-group member breakdown and highlights empty groups in yellow

**Usage**

```powershell
# Interactive mode (prompts for filter)
.\find-group-members-by-filter.ps1

# With a filter
.\find-group-members-by-filter.ps1 -Filter "_SRV_"

# Scoped to a specific OU subtree
.\find-group-members-by-filter.ps1 -Filter "_SRV_" -SearchBase "OU=Servers,DC=domain,DC=local"

# With a custom output path
.\find-group-members-by-filter.ps1 -Filter "_SRV_" -OutputPath "C:\Audit\srv_groups.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `GroupName` | Display name of the matched group |
| `GroupSamAccount` | SamAccountName of the group |
| `GroupDN` | Full Distinguished Name of the group |
| `GroupScope` | `DomainLocal`, `Global`, or `Universal` |
| `GroupCategory` | `Security` or `Distribution` |
| `GroupDescription` | Group description from AD |
| `MemberName` | Display name of the member (or `(no members)` if empty) |
| `MemberSamAccount` | SamAccountName of the member |
| `MemberType` | `User`, `Group`, or `Computer` |
| `MemberEnabled` | `True` / `False` for users and computers (blank for groups) |
| `MemberDN` | Full Distinguished Name of the member |

Output is saved as a CSV in the current directory, e.g.:
- `GroupMembersByFilter__SRV__20250515_143022.csv`

---

### `find-groups-with-no-nesting-purpose.ps1`

Identifies AD groups that play no role in any group nesting structure, classifying them into four categories so you can quickly decide what to investigate or clean up. Designed to handle large domains efficiently — all group and user data is loaded into memory up front, so the processing loop makes no individual AD calls per group.

**Features**
- Classifies every group as `Empty`, `EmptyNested`, `UsersOnly`, or `TopLevelContainer` (see below)
- Excludes built-in and well-known default AD groups by default — use `-IncludeBuiltin` to include them
- Accepts a specific OU subtree or runs against the entire domain
- Colour-coded console output: red (Empty), yellow (EmptyNested), white (UsersOnly), grey (TopLevelContainer)
- Summary on completion: counts per classification and total groups inspected

**Classifications**

| Classification | Meaning |
|---|---|
| `Empty` | Not nested anywhere and has no members — almost certainly safe to delete |
| `EmptyNested` | Nested inside other group(s) but has no members — occupies a slot in the structure but contributes nothing |
| `UsersOnly` | Not nested anywhere and only has user members — may be used for direct resource access (e.g. file shares) but plays no role in the AD nesting hierarchy |
| `TopLevelContainer` | Not nested anywhere but contains sub-groups — this is the root of a nesting tree, which is often intentional |

> **Note:** `UsersOnly` groups cannot be verified as unused by this script alone. A group with no nesting role may still be assigned to file share ACLs, GPO filtering, Exchange distribution, or other systems outside AD group objects. Always verify before deleting.

**Usage**

```powershell
# Interactive mode (prompts for scope)
.\find-groups-with-no-nesting-purpose.ps1

# Entire domain
.\find-groups-with-no-nesting-purpose.ps1 -Scope Domain

# Specific OU and all child OUs
.\find-groups-with-no-nesting-purpose.ps1 -Scope OU -OUName "Helpdesk"

# Include built-in and default system groups in results
.\find-groups-with-no-nesting-purpose.ps1 -Scope Domain -IncludeBuiltin

# With a custom output path
.\find-groups-with-no-nesting-purpose.ps1 -Scope Domain -OutputPath "C:\Audit\orphaned_groups.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `GroupName` | Display name of the group |
| `SamAccountName` | SamAccountName of the group |
| `DistinguishedName` | Full DN of the group |
| `Description` | Group description from AD |
| `GroupScope` | `DomainLocal`, `Global`, or `Universal` |
| `GroupCategory` | `Security` or `Distribution` |
| `Classification` | One of the four classifications above |
| `UserMembers` | Number of direct user members |
| `GroupMembers` | Number of direct group members |
| `OtherMembers` | Number of direct members that are neither users nor groups (e.g. computers) |
| `TotalMembers` | Total direct member count |
| `NestedInCount` | Number of groups this group is nested inside |
| `NestedIn` | Pipe-separated list of parent group names |

Output is saved as a CSV in the current directory, e.g.:
- `NoNestingPurpose_FullDomain_20250515_143022.csv`
- `NoNestingPurpose_Helpdesk_20250515_143022.csv`

---

### `get-ad-ou-delegation-audit.ps1`

Exports custom, non-default ACE delegations on AD Organisational Units — filtering out inherited ACEs and well-known built-in identities so you only see what was deliberately delegated. Covers either the entire domain or a specific OU subtree. Resolves ObjectType GUIDs to human-readable names using the AD schema and Extended Rights.

**Features**
- Skips inherited ACEs and a comprehensive built-in identity exclusion list (SYSTEM, Administrators, Domain Admins, Enterprise Admins, etc.)
- Translates raw ObjectType and InheritedObjectType GUIDs to friendly names (e.g. `Reset Password`, `User`, `Group`)
- Accepts an OU by name or full Distinguished Name
- Progress output every 50 OUs for large domains
- Summary on completion: OUs scanned, OUs with custom ACEs, total ACEs, and unique delegated identities

**Usage**

```powershell
# Interactive mode (prompts for scope)
.\get-ad-ou-delegation-audit.ps1

# Entire domain
.\get-ad-ou-delegation-audit.ps1 -Scope Domain

# Specific OU and all child OUs (by name)
.\get-ad-ou-delegation-audit.ps1 -Scope OU -OUName "Helpdesk"

# Specific OU by Distinguished Name
.\get-ad-ou-delegation-audit.ps1 -Scope OU -OUName "OU=Helpdesk,DC=domain,DC=local"

# With a custom output path
.\get-ad-ou-delegation-audit.ps1 -Scope Domain -OutputPath "C:\Audit\ou_delegation.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `OUName` | Display name of the OU |
| `OUDistinguishedName` | Full DN of the OU |
| `IdentityReference` | The account or group the ACE applies to |
| `AccessControlType` | `Allow` or `Deny` |
| `ActiveDirectoryRights` | The AD rights granted (e.g. `WriteProperty`, `GenericAll`) |
| `InheritanceType` | How the ACE propagates to child objects |
| `ObjectType` | The object or property the right applies to (e.g. `Reset Password`, `All`) |
| `InheritedObjectType` | The child object type the ACE applies to (e.g. `User`, `All`) |

Output is saved as a CSV in the current directory, e.g.:
- `OUDelegationAudit_FullDomain_20250515_143022.csv`
- `OUDelegationAudit_Helpdesk_20250515_143022.csv`

---

### `get-group-nesting-audit.ps1`

Displays the full nesting tree of one or more AD groups — showing every nested group and user, the path through which they have access, and the nesting depth. Produces both a colour-coded console tree view and a timestamped CSV export.

**Features**
- Interactive console tree with colour-coded users (white = enabled, dark red = disabled) and circular-reference detection
- Flattens the tree into CSV rows with a full access path per user/group (e.g. `Domain Admins > HelpDesk > jdoe`)
- Accepts a plain-text file of group names to audit multiple groups in one run
- Summary on completion: nested group count, total/disabled users, and max nesting depth

**Usage**

```powershell
# Interactive mode (prompts for group name)
.\get-group-nesting-audit.ps1

# Single group
.\get-group-nesting-audit.ps1 -GroupName "Domain Admins"

# Multiple groups from a text file (one group name per line)
.\get-group-nesting-audit.ps1 -GroupListFile "C:\temp\groups.txt"

# Specify a custom output path for the CSV
.\get-group-nesting-audit.ps1 -GroupName "Domain Admins" -OutputPath "C:\reports\audit.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `TopLevelGroup` | The group name passed in as the starting point |
| `Type` | `User` or `Group` |
| `Name` | SamAccountName (users) or group name (groups) |
| `DisplayName` | Display name of the user (blank for groups) |
| `Enabled` | `True` / `False` for users (blank for groups) |
| `AccessPath` | Full path showing how access is inherited, e.g. `Domain Admins > HelpDesk > jdoe` |
| `NestingDepth` | How many levels deep this entry sits |
| `Description` | Group description from AD (blank for users) |

Output is saved as a CSV in the current directory, e.g.:
- `GroupNestingAudit_Domain_Admins_20250515_143022.csv`
- `GroupNestingAudit_MultiGroup_20250515_143022.csv`

---

### `get-nested-groups-of-user-or-group.ps1`

Exports all group memberships — including nested/recursive groups — for a given AD user, or for all users within a given AD group. Results are written to a timestamped CSV file.

**Features**
- Looks up a single user's full group membership chain (direct and nested)
- Or resolves all users in a group and reports each user's full membership chain
- Deduplicates group traversal to avoid infinite loops
- Outputs a clean CSV with username, group name, membership type, and inheritance path

**Usage**

```powershell
# Interactive mode (prompts for user or group)
.\get-nested-groups-of-user-or-group.ps1

# Single user
.\get-nested-groups-of-user-or-group.ps1 -Username jdoe

# All users in a group
.\get-nested-groups-of-user-or-group.ps1 -GroupName "HelpDesk"
```

**Output columns**

| Column | Description |
|---|---|
| `Username` | SamAccountName of the user |
| `GroupName` | Name of the AD group |
| `MembershipType` | `Direct` or `Nested` |
| `InheritedFrom` | The group that granted nested membership |
| `Description` | Group description from AD |

Output is saved as a CSV in the current directory, e.g.:
- `jdoe_GroupMemberships_20250515_143022.csv`
- `Group_HelpDesk_Members_GroupMemberships_20250515_143022.csv`
