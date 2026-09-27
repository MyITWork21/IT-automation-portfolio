# Dynamic Distribution List Provisioning

## Problem

The company's email lists were built by hand. Every new hire, role change, or departure meant someone had to remember to update several lists, and every new state meant building a new set from scratch. Lists drifted out of date, and people missed messages meant for them.

## What it does

A PowerShell script that builds the entire distribution list structure in Exchange Online in one run. Every list uses rule-based membership (dynamic distribution lists), so nobody ever has to add or remove members by hand.

| List type | Membership rule | Example |
|---|---|---|
| **State team** | Everyone in that state's office | `NY Team` |
| **State department** | That state's office + department (Operations, Customer Success, Sales) | `NY Operations` |
| **Company-wide department** | Department, active accounts only | `US Finance` |
| **Company-wide team** | Every active US employee with a department | `US Team` |
| **Custom: Revenue Operations** | Department **plus** specific contractor accounts pinned by email | `US Revenue Operations` |

## Design choices

- **Driven by Entra ID attributes.** Membership is based on `Office` and `Department`, which the [ADP sync](../adp-microsoft365-sync) keeps accurate every day, so lists update on their own as HR data changes.
- **Safe to re-run.** The `New-DDL` helper checks whether each list exists before creating it. Running the script again only adds what's missing, which makes adding a new state a one-line config change.
- **Config at the top.** States and departments are defined once in hashtables and arrays, and every list is generated from them.
- **Handles messy data.** `US Product` matches both `Product` and `Product & Engineering`, because both values existed in HR data. The Revenue Operations list combines a department rule with pinned contractor emails to cover mixed-department membership.
- **Excludes disabled accounts** from company-wide lists, so departed employees never receive mail.

## Related work (not in this script)

- Set up moderation, with state managers approving state lists and department heads approving company-wide lists. I also fixed a `BypassModerationFromSendersOrMembers` setting that let members skip approval by default.
- Configured shared mailboxes for every state's admin team, fixing SendAs, FullAccess, and sent-items issues.

## Built with

PowerShell 7 · Exchange Online Management module · Entra ID
