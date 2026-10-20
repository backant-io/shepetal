## Overview
Escalation call about Northwind Clinics, whose dictation accuracy on medical terms dropped after last week's update.

## Key points
- Word error rate on medical terms rose from about six to eleven percent, mostly on drug names.
- The likely cause is the new custom vocabulary loader, which silently ignores entries longer than thirty-two characters.
- The old loader is still behind a feature flag, so a per-tenant rollback is easy.
- Other customers with long vocabulary entries may be affected without knowing it.
- Northwind's contract renewal is in two months.

## Decisions
- Offer Northwind an immediate rollback to the old vocabulary loader for their tenant.
- Fix the length limit for everyone: raise it to 256 characters, log a warning instead of dropping entries, and add a test.
- The decision on a credit for Northwind is postponed to next week.
- Write an incident report because of the silent data loss.

## Action items
- Kenji: switch the Northwind tenant to the old loader (due today).
- Kenji: query all tenants for entries over thirty-two characters and send the list to Daniel (due tomorrow).
- Kenji: have the fix ready for review (due Thursday).
- Aisha: review the fix so it can ship Friday morning (due Thursday).
- Daniel: email Northwind with the explanation and rollback offer (due today) and contact other affected customers.
- Aisha: talk to finance about the credit (due next week).
- Aisha: write the incident report (due Monday).
