## Overview
Their dictation accuracy dropped badly after last week's update, and they are threatening to pause the rollout to their remaining four sites.

## Key points
- They want an answer before their board call on Friday.
- We tell them we have identified a likely cause, we will confirm it within twenty-four hours, and we will ship a fix or a rollback by Friday.
- We can switch their tenant back today if they want.
- Let's offer the rollback immediately as the safe option.
- I contact Northwind today and other affected customers after that.

## Decisions
- We offer Northwind an immediate rollback to the old vocabulary loader for their tenant, and we fix the length limit properly for everyone.
- Let's not decide the credit today.
- Credit is postponed to next week.
- We roll back Northwind today, fix the limit with a warning and a test by Thursday, review Thursday, ship Friday.

## Action items
- Aisha: talk to finance and we decide (due next week)
- Kenji: query all tenants for entries over thirty-two characters and send the list to Daniel (due tomorrow)
- Kenji: switch the Northwind tenant to the old loader, right after this call (due today)
- Kenji: have the fix with the new limit and the warning ready for review (due Thursday)
- Aisha: review it so it can ship Friday morning (due Thursday afternoon)
- Daniel: email Northwind with the explanation and the rollback offer, and I'll join their Friday call if they want us there (due today)
- Aisha: write the incident report (due Monday)
