# ADP → Microsoft 365 Sync

Three Azure Automation runbooks that keep Microsoft 365 matched to ADP, the HR system of record. HR makes a change in ADP, and Microsoft 365 follows automatically.

| Runbook | Schedule | What it keeps in sync |
|---|---|---|
| [`Sync-ADPJobTitleDepartment.ps1`](./Sync-ADPJobTitleDepartment.ps1) | Daily | Job title and department |
| [`Sync-ADPBusinessUnit.ps1`](./Sync-ADPBusinessUnit.ps1) | Daily | Business unit (`officeLocation`), plus alerts for new business units |
| [`Invoke-TerminationSync.ps1`](./Invoke-TerminationSync.ps1) | Daily | Account access for employees terminated in ADP |

## Problem

Employee data lived in ADP, but Microsoft 365 is what drives distribution lists, access, and state-based policies. Keeping the two matched by hand meant constant manual updates, stale titles and departments, people landing in the wrong lists, and a real risk of a departed employee keeping access if HR and IT missed a handoff.

## How it works

All three runbooks share the same foundation:

- **Connect to ADP** with certificate-based OAuth 2.0 and page through every worker record
- **Connect to Microsoft Graph** with app-only credentials and pull all Microsoft 365 users
- **Match people by work email**, then compare ADP against Microsoft 365
- **Email a report** after every run, with what changed and anything that needs a person to look at it

### Job title and department sync
- Cleans up ADP's raw values (removing code prefixes from titles and departments) before comparing
- Updates any mismatched title or department through Graph
- Flags edge cases for manual review, such as duplicate emails in ADP, or someone active in ADP with no Microsoft account

### Business unit sync
- Reads each employee's active business unit from ADP and updates `officeLocation` in Microsoft 365, which drives [dynamic distribution list](../dynamic-distribution-lists) membership and state-based access
- **Detects new business units.** The first time one appears in ADP, IT gets a single alert listing what to set up (distribution list, Teams channel, SharePoint site). Known units are stored in an Azure Automation variable, so the same alert never repeats.

### Termination sync
Looks at terminations in ADP from the last 30 days and, for anyone whose Microsoft account is still enabled:
1. Disables the account
2. Revokes all active sign-in sessions
3. Removes assigned Microsoft 365 licenses so they can be reassigned
4. Removes the user from all groups
5. Emails IT and HR a report of every action taken, including anything that failed

It acts as a **backup to the manual offboarding process**: if a termination slips through, access is still removed within a day. An exception list protects accounts that should never be processed automatically.

## Design choices

- **Report-only mode.** Setting `$LiveMode = $false` runs the full comparison and report without changing anything, so every change can be checked against real data before it goes live.
- **No stored secrets.** Credentials, the tenant ID, and the ADP certificate come from Azure Automation's encrypted assets, never from the scripts.
- **Only touch what ADP knows about.** Runbooks only act on accounts that exist in ADP, so service and admin accounts are never affected.
- **Fail loud, not silent.** Every failed update lands in the report's manual-review section instead of being skipped quietly.

## Sample output

See [`sample-output.txt`](./sample-output.txt) for a business unit sync run. It uses made-up data.

## Built with

PowerShell 7 · Azure Automation · ADP Workforce Now API · Microsoft Graph API · Entra ID · OAuth 2.0
