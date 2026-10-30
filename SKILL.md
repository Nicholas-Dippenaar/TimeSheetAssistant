---
name: timesheet
description: Compile the user's daily or weekly timesheet (working hours and unbilled lunch from config.json) from git commits, pull requests (GitHub or Azure DevOps), Claude Code sessions, notes, memory files and the Outlook calendar, and save it as a .md file. Use when asked for a timesheet, to fill in hours, or when the weekly scheduled run invokes it.
---

# Timesheet

Produces a **draft** timesheet the user checks before submitting. Never invent tickets: every ticket must be backed by a source. Untracked time between activities is folded into the neighbouring ticket (see step 3), not listed as a gap.

## Configuration

Settings live in `config.json` next to this file (template: `config.example.json`; setup: `README.md`):

- `outputRoot` — timesheet root folder
- `frequency` — `daily` (one report per weekday) or `weekly` (one report per Mon–Fri week)
- `retentionWeeks` — reports older than this are deleted by the scheduled script (not by you)
- `workday.start` / `workday.end` — e.g. `07:00`–`16:00`
- `workday.lunchMinutes`, `workday.lunchWindowStart` / `lunchWindowEnd` — unbilled lunch and when it's usually taken
- `calendar` — whether to search the Outlook calendar

Billable hours per day = (end − start) − lunch. When the scheduled run invokes this skill, the prompt states the hours, raw data file and exact output path — use them as given. When run interactively, read `config.json` yourself.

## Where the file goes

- Sub-folder of `outputRoot`: the full English month name of the week's **Friday** (e.g. `October`). A week that starts in one month and ends in the next goes in the *later* month's folder, so there's one predictable place to look. Create the folder if it doesn't exist.
  Daily reports use the same rule (the Friday of that day's week), so a week's daily reports always sit together.
- File name: weekly `Timesheet <Monday yyyy-MM-dd> to <Friday yyyy-MM-dd>.md`; daily `Timesheet <yyyy-MM-dd>.md`
- If the file already exists, don't overwrite it unless the user asks.

## Step 1 — Raw data

If no raw data file was provided, collect it (takes about a minute). `-End` is exclusive:

```powershell
# Weekly: Saturday before through Friday
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\timesheet\Get-TimesheetData.ps1" -Start <Saturday> -End <Friday + 1 day> -OutFile "$env:LOCALAPPDATA\ClaudeTimesheet\work\raw-<Friday>.md"
# Daily: one day
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\timesheet\Get-TimesheetData.ps1" -Start <day> -End <day + 1> -OutFile "$env:LOCALAPPDATA\ClaudeTimesheet\work\raw-<day>.md"
```

The file covers the requested range: git commits, pull requests, typed Claude prompts (local time, truncated), notes and memory files modified in range. Read all of it. In an interactive run, delete it once the timesheet is written; in a scheduled run the wrapper script deletes it.

## Step 2 — Calendar

If `calendar` is enabled, search the Outlook calendar (`outlook_calendar_search`) for the report's days. Use it for meetings, standups, leave, public holidays and out-of-office blocks. Recurring meetings don't always show — don't assume them. Skip events marked cancelled or postponed. If the tool isn't available, carry on and say so under **Check before you submit**.

## Step 3 — Build the days

For each weekday, cover the configured working day (start to end), which includes the unbilled lunch:

- **Lunch first:** before folding gaps, look for a gap inside the lunch window. Book the first `lunchMinutes` of it as `Lunch (unbilled)` (e.g. window 12:00–14:00, gap from 12:30 → lunch 12:30–13:30). Anything left of that gap is then folded like any other gap.
  - If no gap in the window is long enough, use the biggest gap in the window, or else the start of the window, and add it to **Check before you submit**.
  - Lunch is shown as its own row with its hours, but is excluded from day and week totals.
- Group activity into blocks. A block runs from its first evidence (prompt, commit, note edit, meeting) until the next block starts. Start a new block when the ticket changes.
- Ticket: take it from the branch name, PR title, prompt text or notes file name (e.g. `ABC-123`). Use PR titles for the ticket's description. If you can't tell, use ❓.
- Work: one short line describing what was done (e.g. "Addressed PR comments", "Planning doc"). Summarise at ticket level.
- Hours to the nearest 0.25.
- **Fold gaps into work, don't list them.** Untracked time is usually investigation before a commit or PR exists, so:
  - A gap goes to the **next** ticket block (e.g. a 30 min gap before 2 h on ABC-123 → 2.5 h on ABC-123, with the block starting where the gap started).
  - If nothing follows the gap that day, or the next block is a meeting, it goes to the **previous** ticket block instead. Meetings keep their calendar times.
  - A ticket block that absorbed more than 2 h of gap gets a line under **Check before you submit** so the user can sanity-check it.
- ❓ rows only remain for:
  - A weekday with no activity at all (possibly leave — don't guess).
  - Blocks where the work happened but the ticket genuinely can't be identified.
  - On the day of a scheduled run, the time after the run time ("after export").
- Weekly: include Saturday/Sunday only if there's activity.

## Step 4 — Write the file

**Daily report:** title `# Timesheet — <Weekday d Month yyyy>`, then the generated-draft line, the single day's table with its **Day total (billable)**, **Check before you submit** and **Sources**. No totals-by-ticket section.

**Weekly report:** use this layout (the numbers are illustrative — use the configured hours):

```markdown
# Timesheet — week ending Friday 30 October 2026

_Draft generated <yyyy-MM-dd HH:mm> from git, Claude sessions, notes and calendar. Check before submitting._

## Totals by ticket

| Ticket | Description | Hrs |
| :--- | :--- | ---: |
| ABC-123 | Short description from the PR title | 6.5 |
| Meetings | | 2.0 |
| **Total (billable)** | | **40.0** |

## Monday 26 October

| Time | Ticket | Work | Hrs |
| :--- | :--- | :--- | ---: |
| 07:00–09:30 | ABC-123 | Investigation + addressed PR review comments | 2.5 |
| 09:30–10:00 | Meeting | Standup | 0.5 |
| 12:00–13:00 | — | Lunch (unbilled) | 1.0 |

**Day total (billable):** 8.0

... one section per day ...

## Check before you submit

- Big gap merges, guesses, low-confidence ticket assignments, anything the calendar couldn't confirm.

## Sources

- One line per source: what was found (e.g. "Git: 6 commits in 2 repos"), or that it was unavailable.
```

## Rules

- No personal information: no names of colleagues, clients or meeting attendees, ID numbers, emails, phone numbers or bank details. Don't copy prompt text into the timesheet.
- Don't create, edit or delete anything other than the timesheet file (and the raw data file in step 1).
- Don't log time anywhere else (Jira, Azure DevOps etc.) — the user does that.
