# IT Automation Portfolio

Automations I built to solve real problems across Microsoft 365, Azure, and the business systems that teams across the company depend on: work that was manual, easy to get wrong, or depended on someone remembering to follow up.

Each one started the same way. I noticed something eating up time or creating risk, worked out how it *should* work, and then built it.

## How I build

My background is IT systems, not software development, so I approach automation from the systems side. I know where the data lives, how work moves between teams, what tends to break, and what a safe change looks like in production. I use AI and other tools to turn that into working code.

- **I design the solution.** I map out the process first: which system is the source of truth, who needs what, and what can go wrong.
- **AI speeds up the build.** I use AI assistants to draft the PowerShell and Python, work through API documentation, and debug errors.
- **I own the result.** I test against real data in report-only and test modes before anything goes live, handle the edge cases, run it in production, and understand every script well enough to explain and change it.

A few decisions from these projects:

- A new business unit should only alert IT once, not every day, so the runbook keeps a stored list of units that have already been flagged.
- Some accounts should never be disabled automatically, so the termination sync has an exception list.
- The syncs only act on accounts that exist in the source system, so admin and service accounts are never affected.
- Every runbook has a report-only mode, and the onboarding emails have a test mode that sends everything to one address. Nothing reaches real people until the output has been checked.

## Projects

| Project | What it does | Built with |
|---|---|---|
| [ADP → Microsoft 365 Sync](./adp-microsoft365-sync) | Three daily runbooks that keep user profiles in Microsoft 365 matched to ADP, and automatically remove access for terminated employees | PowerShell 7, Azure Automation, ADP API, Microsoft Graph |
| [New Hire Onboarding](./new-hire-onboarding) | Automated welcome emails with an IT guide, access requests, a weekly new hire digest, and one-click expense app setup | PowerShell 7, Azure Automation, Logic Apps, Blob Storage, Microsoft Graph |
| [Dynamic Distribution Lists](./dynamic-distribution-lists) | Builds a full set of distribution lists with rule-based membership, so they stay current on their own | PowerShell, Exchange Online |
| [Device Inventory Report](./device-inventory-report) | Turns a raw device inventory into a prioritized, color-coded to-do list: devices to recover, reuse, or follow up on | Python, openpyxl |

## How it fits together

    ADP (system of record)
       │  daily sync runbooks (Azure Automation)
       ▼
    Microsoft 365 / Entra ID  ── user profiles and account status
       │
       ├──► Dynamic distribution lists and access
       ├──► Onboarding notifications and setup
       └──► Offboarding: disable, revoke sessions, remove licenses and groups

A change at the source flows through to profiles, email lists, and access automatically, with no hand-offs between teams.

## Other work (not in this repo)

Some of my projects were configuration rather than code, so there's nothing to publish here:

- **Azure virtual machines for contractors:** secure, company-controlled workstations with access limited by role
- **Role-based access review:** used real app-assignment data from Entra ID to build an access standard for each role, which now drives onboarding
- **Compliance and intranet SharePoint site:** a central, permission-controlled home for policies that grew into the company intranet
- **Device and asset management:** connected Intune and Kandji to a single asset tracking platform

## About this repo

These are cleaned-up versions of scripts I run in production. Company names, domains, emails, locations, and IDs have been replaced with placeholders such as `contoso.com`. No credentials or secrets live in any script. The runbooks read them at run time from Azure Automation's encrypted credential, certificate, and variable stores.
