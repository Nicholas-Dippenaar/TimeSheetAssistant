# Timesheet skill

Writes a draft timesheet as a Markdown file using Claude Code. You choose whether you get one each weekday or one each week. It works out what you did from:

- your git commits
- your pull requests (GitHub or Azure DevOps)
- the prompts you typed into Claude Code
- notes files you edited
- your Outlook calendar

Untracked time is folded into the next ticket, and lunch is booked as unbilled. Anything it's unsure about goes in a **Check before you submit** list at the end. It's a draft: review it before you log your time.

## Requirements

- Windows with [PowerShell 7](https://aka.ms/powershell) (`pwsh`)
- [Claude Code](https://claude.com/claude-code), logged in with your claude.ai account
- `git`
- Optional, for pull request titles:
  - GitHub: [`gh`](https://cli.github.com), logged in with `gh auth login`
  - Azure DevOps: [`az`](https://aka.ms/azcli) with the DevOps extension (`az extension add --name azure-devops`), logged in with `az login`
- Optional, for meetings: the Microsoft 365 connector enabled for Claude in claude.ai settings

## Setup

1. Copy this folder to `%USERPROFILE%\.claude\skills\timesheet`.
2. Run `pwsh -File "$env:USERPROFILE\.claude\skills\timesheet\Install-Timesheet.ps1"` and answer the questions. Press Enter to accept the value in [brackets]. It asks for:
   - where to save your timesheets
   - **daily** or **weekly** reports
   - your working hours and lunch
   - when the report should run
   - your repo folders and git names
   - notes folders, calendar, notifications and how many weeks of reports to keep

   It then saves your answers to `config.json` and schedules the task. The last lines show where your timesheets will be saved.
3. Test it now: `pwsh -File "$env:USERPROFILE\.claude\skills\timesheet\Invoke-Timesheet.ps1"`. You get a Windows notification when it's done; click it to open the timesheet.

To change any setting later, run the installer again.

## Where to find your timesheets

In the folder you chose during setup (`outputRoot`), in a sub-folder for the month, e.g. `Documents\Timesheets\October\`. The run logs in `%LOCALAPPDATA%\ClaudeTimesheet\logs` are only for troubleshooting.

## config.json

| Setting | Meaning |
| :--- | :--- |
| `outputRoot` | Folder for timesheets. Reports go in a sub-folder named after the month of that week's Friday, e.g. `October`. A week that spans two months goes in the later month's folder, and so do its daily reports. |
| `frequency` | `daily` or `weekly`. The installer sets this from your answer. |
| `retentionWeeks` | How many weeks of reports to keep (default `3`). Older reports are deleted on each run. Only files named `Timesheet ….md` are touched. `0` keeps everything. |
| `workday.start`, `workday.end` | Your normal hours, e.g. `08:00` and `17:00`. |
| `workday.lunchMinutes` | Unbilled lunch length. |
| `workday.lunchWindowStart`, `lunchWindowEnd` | When you usually take lunch. A gap in this window is booked as lunch. |
| `schedule.time` | When the task runs. For daily reports, pick a time near the end of your day. |
| `schedule.day` | Weekly only: which day it runs. Use Friday or later, because it always writes the most recent Mon–Fri week. |
| `git.repoRoots` | Folders holding your repos. Repos up to two levels deep are found. |
| `git.authors` | Names or emails your commits use. If empty, it uses your global git `user.name` and `user.email`. |
| `git.pullRequests` | `true` to look up PR titles, used for ticket descriptions. GitHub or Azure DevOps is detected from each repo's remote. |
| `git.azureDevOpsCreator` | Your Azure DevOps sign-in email. If empty, it uses the account from `az login`. |
| `notesRoots` | Optional notes folders. Files you edited are used as evidence. |
| `calendar` | `true` to use your Outlook calendar for meetings and leave. |
| `notifications` | `true` to show a Windows notification when a report is ready (click it to open the report) or a run fails (click it to open the log). |

The installer writes this file for you. If you edit it by hand, run `Install-Timesheet.ps1 -NonInteractive` afterwards to check it and update the schedule.

`config.json` is personal: don't share it or commit it.

## How it behaves

- **File names:**
  - Daily: `Timesheet 2026-10-30.md`
  - Weekly: `Timesheet 2026-10-26 to 2026-10-30.md`
- **Late runs:** if your PC is off at the scheduled time, it runs at the next chance and still writes the right day or week. A daily run the next morning writes the previous weekday.
- **No overwriting:** it never overwrites an existing report. To regenerate one, run `Invoke-Timesheet.ps1 -Force`. Add `-Date 2026-10-28` for a past day or week.
- **Limited access:** Claude can only read files and search your calendar, and it can only write into the month folder.
- **Notifications:** a Windows popup tells you when a report is ready or a run failed, so failures don't go unnoticed.
- **Logs:** saved in `%LOCALAPPDATA%\ClaudeTimesheet\logs` and kept for 60 days.
- **Raw data:** the collected activity includes excerpts of your Claude prompts, so it's deleted after each successful run.
- **On demand:** you can also ask Claude Code for "my timesheet" at any time.
- **Uninstall:** `Install-Timesheet.ps1 -Uninstall`.
