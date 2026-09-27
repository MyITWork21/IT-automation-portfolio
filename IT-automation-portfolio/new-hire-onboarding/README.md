# New Hire Onboarding Automation

Two Azure Automation runbooks that take care of the coordination around every new hire, so IT, managers, and accounting all get what they need without a chain of back-and-forth emails.

| Runbook | Schedule | Who it serves |
|---|---|---|
| [`Send-NewHireWelcome.ps1`](./Send-NewHireWelcome.ps1) | Weekly | New hires, their managers, and IT |
| [`Send-AccountingNewHireAlert.ps1`](./Send-AccountingNewHireAlert.ps1) | Weekly | Accounting (expense app setup through an Azure Logic App) |

## Problem

Every new hire kicked off the same manual loop: IT emailing a getting-started guide, chasing managers to confirm what access the person needed, and accounting setting up expense accounts under the right legal entity. During busy hiring weeks, things got missed or set up wrong.

## Welcome and access checklist

Finds Microsoft 365 accounts created in the last few days (skipping admin, shared, and service accounts), looks up each person's manager through Graph, and works out their state from `officeLocation`. It then sends three kinds of emails:

- **New hire:** a welcome email with the IT Getting Started Guide attached as a PDF, pulled from Azure Blob Storage
- **Manager:** one email per manager listing their new team members, asking them to reply with the access each person needs. Replies go straight to IT Support.
- **IT Support:** a weekly digest of every new hire, with title, department, state, and manager

**Test mode:** setting `$TestMode = $true` sends every email to one test address instead of real employees, so changes can be tested safely.

## Accounting / expense app alert

Pulls new hires from ADP for the past week, including title, hire date, business unit, and manager, and sends accounting a single email with a row for each person.

Each row has **one-click buttons, one per legal entity**. Clicking a button calls an **Azure Logic App** over HTTP with the employee's details, and the Logic App sends that person the expense app invite for the correct entity. Accounting never has to copy details or look up invite links.

```
Runbook ──► Accounting email (one button per entity)
                     │ click
                     ▼
              Azure Logic App ──► expense app invite to the new hire
```

## Design choices

- **Secrets stay out of the code.** Expense app invite links, the Logic App trigger URL, and the storage link to the PDF are all read from Azure Automation variables at run time.
- **Each flow starts from the right system.** The welcome flow starts from Microsoft 365 account creation, because that's when the new hire can actually sign in. The accounting flow starts from ADP, because that's where hire date and legal entity live.
- **Safe to change.** Report-only and test modes mean nothing reaches real people until the output has been checked.

## Built with

PowerShell 7 · Azure Automation · Azure Logic Apps · Azure Blob Storage · Microsoft Graph API · ADP Workforce Now API
