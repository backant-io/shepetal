## Overview
In the last update we replaced the custom vocabulary loader, and the new one silently ignores entries longer than thirty-two characters.

## Key points
- We tell them we have identified a likely cause, we will confirm it within twenty-four hours, and we will ship a fix or a rollback by Friday.
- We can switch their tenant back today if they want.
- For the proper fix, I'd raise the limit to two hundred fifty-six characters and log a warning instead of dropping entries silently.
- Okay, so to recap: likely cause is the new vocabulary loader dropping entries over thirty-two characters.
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
