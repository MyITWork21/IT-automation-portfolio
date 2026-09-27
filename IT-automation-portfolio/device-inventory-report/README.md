# Device Inventory Report

## Problem

The raw device inventory showed every device the company owned, but not which ones needed action. Laptops belonging to employees who had left, spares sitting unassigned, and devices nobody had used in weeks were all mixed in with everything else, so hardware went unrecovered and new devices got bought when spares were already on the shelf.

## What it does

A Python script that reads the inventory tab of the new hire tracker and produces a clean, prioritized report:

1. **Recalculates idle time** for each device from its last check-in date, so the numbers are always current
2. **Sorts by action priority:**
   1. **Recover – Leaver** (device still out with a departed employee)
   2. **Spare – Unassigned** (available to hand to a new hire)
   3. **Idle 30d+** (assigned but not used in over a month)
   4. **Unknown User** (needs investigation)
   5. **Assigned** (no action needed)
3. **Builds a Summary sheet** with the device count for each status and a total
4. **Builds a formatted Inventory sheet** with color-coded status, frozen headers, filters, and consistent date and column formatting

## Why it matters

The report turns an inventory list into a to-do list. Recovering leaver devices and reusing spares first cut down on unnecessary hardware purchases for new hires.

## Built with

Python 3 · openpyxl · Microsoft Intune and Kandji data (via the inventory tracker)
