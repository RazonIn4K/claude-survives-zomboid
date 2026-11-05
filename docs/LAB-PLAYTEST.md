# Bounded multiplayer body check — 2026-11-04

Tested body source: `b5dd86f1fcb3a2ec73c09f5db60a5c6739a477f6`.
Official Build 42.21.0 (`4a0e9546ec`), loopback dedicated server, one admin client,
fresh no-zombie lab world, `bodyRevision=supplies-1`. Only ClaudeSurvivor was enabled.

Four explicitly armed scripted runs issued five total actions, without model
inference or spawned fixture items:

1. LOOT near containers with no eligible items in the client's current lists:
   inventory stayed 16, receipt `no_effect`, error reported no useful supplies.
2. MOVE north three tiles: observed position changed from 10912,10037 to 10912,10034.
   Fresh nearby client lists then exposed three eligible food items.
3. LOOT followed by EAT: inventory 16→19 and food 0→3; the loot receipt recorded
   three new inventory IDs. Eating removed one item, left two food items and
   reduced hunger by 0.049292 using unrounded stats. Both receipts were
   `observed_effect` with no action error.
4. DRINK with no water in inventory: receipt `no_effect`, error `drink: no water`.
   This verifies the no-water diagnostic, not successful drinking.

All four runs ended with a fresh disarm receipt, queue 0, `stopFailed=false` and
health 100. The world was explicitly saved through the server console afterward.
These establish engine effects for the scripted commands, not autonomous model
selection, combat ability, shared NPC replication or long-term survival. The
earlier real-model test observed looting and screwdriver equip; this body check
used zero additional gameplay model requests.

Official B42 `ISInventoryPage` requests unexplored multiplayer containers and
marks them explored immediately, before the request necessarily returns. The
body currently reads existing client lists without requesting every container.
Empty counts therefore cannot prove actual empty stock. Prompt guidance now
states that limitation and asks for a short approach plus fresh observation.
Explicit unknown/synchronization handling and water acquisition are next gaps.
