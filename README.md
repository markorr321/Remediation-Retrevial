# Intune Remediation Scripts – Export & Push Toolkit

A set of PowerShell tools for backing up and deploying **Intune remediation scripts**
(a.k.a. *proactive remediations* / *device health scripts*) via the Microsoft Graph API.

- **`Export-IntuneRemediations.ps1`** — pulls every remediation script out of Intune and
  saves it to disk as an organized, source-control-friendly folder structure, plus CSV reports.
- **`Push-RemdiationsToIntune.ps1`** — takes those exported folders and creates or updates
  the corresponding remediation scripts back in Intune.
- **`Start-RemediationToolkit.ps1`** — an interactive text-based menu (TUI) that drives
  both scripts so you don't have to remember switches.

Together they give you a round-trip workflow: **export → edit / version in Git → push**.

> **Author:** Mark Orr

---

## Repository Layout

```
Remediation-Retrevial/
├─ Export-IntuneRemediations.ps1     # Download all remediations from Intune
├─ Push-RemdiationsToIntune.ps1      # Create/update remediations in Intune
├─ Start-RemediationToolkit.ps1      # Interactive menu (TUI) front-end
└─ RemediationScripts/               # Exported scripts (one folder per remediation)
   └─ <ScriptName>/
      ├─ detection.ps1               # Detection script
      ├─ remediation.ps1            # Remediation script (optional)
      └─ metadata.json              # Script settings + Intune Id (+ optional Assignment)
```

Each remediation lives in its own folder. `metadata.json` carries the settings and the
Intune `Id` that links the local copy back to the object in the tenant:

```json
{
  "DisplayName": "DeviceType-Inventory",
  "Description": "",
  "Publisher": "Mark Orr",
  "Version": "2",
  "RunAsAccount": "system",
  "EnforceSignatureCheck": false,
  "RunAs32Bit": false,
  "Id": "ab467d3f-1976-4774-8c2d-45d6bb7f2550",
  "CreatedDateTime": "2025-12-15T11:33:54.849834Z",
  "LastModifiedDateTime": "2025-12-15T11:37:31.298696Z",
  "RoleScopeTagIds": "0"
}
```

---

## Prerequisites

- **PowerShell 7+** (Windows). The push script's folder-picker uses Windows Forms, so run it on Windows.
- **Microsoft Graph PowerShell SDK modules:**
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser
  ```
- A Microsoft Entra account with the delegated Graph permissions listed below, and rights
  in Intune to manage remediations (e.g. the **Intune Administrator** role, or a custom
  role with the equivalent Device Health Script permissions).

---

## Required Permissions

Both scripts authenticate with **delegated** Microsoft Graph permissions via
`Connect-MgGraph`. You'll be prompted to consent on first run (or an admin can pre-consent).

### `Export-IntuneRemediations.ps1`

| Graph scope | Why it's needed |
|-------------|-----------------|
| `DeviceManagementConfiguration.Read.All` | Read remediation scripts, their content, and assignments |
| `Group.Read.All` | Resolve assignment target **group IDs** to display names |
| `User.Read.All` | Look up **publisher email addresses** for the contact-list CSV |

*Read-only.* This script never modifies the tenant.

### `Push-RemdiationsToIntune.ps1`

| Graph scope | Why it's needed |
|-------------|-----------------|
| `DeviceManagementConfiguration.ReadWrite.All` | Create and update remediation (device health) scripts |

> **Approval workflow:** If your tenant has **multiple administrative approval** enabled
> for remediation scripts, `POST`/`PATCH` calls return `412 Precondition Failed` (or `409`
> if a request is already pending). The script detects this and reports it as
> **"Approval Required"** with the approval code — it is **not** a failure. Approve the
> change in **Intune Portal → Endpoint Security → Remediations → Approvals**.

---

## Usage

### Export remediations from Intune

```powershell
# Export all remediations to .\RemediationScripts
.\Export-IntuneRemediations.ps1

# Export to a custom location
.\Export-IntuneRemediations.ps1 -OutputPath "C:\Backup\Remediations"
```

Outputs, per run:
- One folder per remediation (`detection.ps1`, `remediation.ps1`, `metadata.json`).
- `remediation-scripts-summary.csv` — full details: deployment status, signature
  enforcement, run schedule, assignments, publisher, version, dates, IDs.
- `publishers-contact-list.csv` — unique publishers and their resolved emails.

### Push remediations to Intune

```powershell
# Create new remediations from every folder in the current directory
.\Push-RemdiationsToIntune.ps1

# Pick a folder graphically (single remediation folder or a parent of many)
.\Push-RemdiationsToIntune.ps1 -BrowseFolder

# Update existing remediations (matched by the Id in metadata.json)
.\Push-RemdiationsToIntune.ps1 -BrowseFolder -UpdateExisting

# Push a specific folder and update it, with an approval justification
.\Push-RemdiationsToIntune.ps1 -FolderName "DeviceType-Inventory" -UpdateExisting `
    -ApprovalJustification "Security compliance update"

# Preview what would be pushed without contacting Intune
.\Push-RemdiationsToIntune.ps1 -UpdateExisting -WhatIf
```

**Create vs. update:** With `-UpdateExisting` **and** an `Id` present in `metadata.json`,
the script `PATCH`es the existing object; otherwise it creates a new one and writes the
returned `Id` back into `metadata.json` so future pushes update in place.

---

## Interactive Mode (menu / guided prompts)

Prefer menus over switches? Launch the TUI:

```powershell
.\Start-RemediationToolkit.ps1              # full menu: Export + Push
.\Push-RemdiationsToIntune.ps1 -Menu        # jump straight to the Push menu
```

Navigate with **↑/↓ arrows or number keys**, **Enter** to select, **Esc** to go back.
The Create and Update actions run the push script with `-Interactive`, which you can also
use directly:

- **Guided update** (`-UpdateExisting -Interactive`): connects to Intune, shows the
  **current live settings** for the script, and asks whether to keep them as-is or modify
  each one. Choosing *keep* updates only the detection/remediation script content; the
  existing settings are preserved exactly.

- **Guided create** (`-Create -Interactive`): prompts for every setting (Display Name,
  Description, Publisher, Run-as account, 32-bit, Enforce signature, Scope tags) plus an
  optional **assignment** (All devices / All users / a group by object Id) and a
  **run schedule** (Daily / Hourly / Once). On success it creates the script **and** its
  assignment in one step.

---

## Assignment block (optional in `metadata.json`)

Guided create writes an `Assignment` object into the folder's `metadata.json` so the
deployment is reproducible. You can also add it by hand for a non-interactive
create — when present, `-Create` will assign the script after creating it:

```json
{
  "DisplayName": "DeviceType-Inventory",
  "RunAsAccount": "system",
  "RunAs32Bit": false,
  "EnforceSignatureCheck": false,
  "RoleScopeTagIds": "0",
  "Assignment": {
    "Target": "Group",
    "GroupId": "11111111-2222-3333-4444-555555555555",
    "GroupName": "Intune-Users",
    "ScheduleType": "Daily",
    "Interval": 1,
    "StartTime": "01:00",
    "RunRemediation": true,
    "UseUtc": false
  }
}
```

| Field | Values | Notes |
|-------|--------|-------|
| `Target` | `AllDevices` / `AllUsers` / `Group` | Who the remediation is assigned to |
| `GroupId` | GUID | Required when `Target` is `Group` |
| `GroupName` | string | Optional, for reference only |
| `ScheduleType` | `Daily` / `Hourly` / `Once` | Run cadence |
| `Interval` | integer | Every N days (Daily) or N hours (Hourly) |
| `StartTime` | `HH:mm` | Daily/Once; sent to Graph as `HH:mm:ss` |
| `StartDate` | `YYYY-MM-DD` | Once only |
| `RunRemediation` | `true` / `false` | Run the remediation script (not just detection) |
| `UseUtc` | `true` / `false` | Interpret the time as UTC |

---

## Getting Help

Both scripts include full comment-based help:

```powershell
Get-Help .\Export-IntuneRemediations.ps1 -Full
Get-Help .\Push-RemdiationsToIntune.ps1 -Full
```

---

## Notes

- All Graph endpoints used are on the **`/beta`** profile for device health scripts, which
  is where the remediation (proactive remediation) APIs currently live.
- Scripts are stored/encoded as UTF-8 and base64-encoded when sent to Graph.
- The push script prompts **once** for an approval justification and reuses it for the
  whole batch.
