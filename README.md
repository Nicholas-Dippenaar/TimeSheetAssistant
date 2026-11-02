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
- [Claude Code](https://claude.com/claude-code), logged in with your claude.ai account. Using the Claude desktop app instead? See [Using the Claude desktop app instead of the CLI](#using-the-claude-desktop-app-instead-of-the-cli).
- `git`
- Optional, for pull request titles:
  - GitHub: [`gh`](https://cli.github.com), logged in with `gh auth login`
  - Azure DevOps: [`az`](https://aka.ms/azcli) with the DevOps extension (`az extension add --name azure-devops`), logged in with `az login`
- Optional, for meetings: the Microsoft 365 connector enabled for Claude in claude.ai settings

## Setup

1. Clone the repo into your Claude Code skills folder. The folder must be named `timesheet`:
   ```powershell
   git clone https://github.com/Nicholas-Dippenaar/TimeSheetAssistant.git "$env:USERPROFILE\.claude\skills\timesheet"
   ```
   The repo is private, so ask for access if the clone fails.
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

## Using the Claude desktop app instead of the CLI

The skill runs in the **Code** tab of the Claude desktop app, which reads skills from the same `%USERPROFILE%\.claude\skills` folder as the CLI. A normal chat in the app or on claude.ai can't use it, because it can't reach your git repos or local files.

The scheduled report needs the `claude` command, which the app doesn't install. The installer stops if `claude` isn't found. You have two options.

### Option A: install the CLI as well (recommended)

This gives you the automatic daily or weekly report.

1. Install the CLI:
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```
2. Open a new terminal, run `claude` once and log in with the same claude.ai account you use in the app. Then type `/exit`.
3. Follow [Setup](#setup) above.

You can keep using the app day to day. The scheduled task uses the CLI in the background.

### Option B: app only, on demand

With this option there's no schedule and no notifications. You ask for a timesheet when you want one.

1. Clone the repo as in step 1 of [Setup](#setup). `git` and PowerShell 7 are still required.
2. Create your settings by copying the example:
   ```powershell
   Copy-Item "$env:USERPROFILE\.claude\skills\timesheet\config.example.json" "$env:USERPROFILE\.claude\skills\timesheet\config.json"
   ```
   Open `config.json` and fill it in (see [config.json](#configjson) below). At a minimum, replace `<you>` in `outputRoot` and set `git.repoRoots`. The `schedule` and `notifications` settings aren't used.
3. Restart the app so it picks up the new skill.
4. In the **Code** tab, open any folder and ask for "my timesheet for this week" (or "for today"). Claude will ask permission to run `Get-TimesheetData.ps1` and to save the file. Allow both.

For meetings, enable the Microsoft 365 connector in claude.ai settings, as with the CLI.

If you later install the CLI, run `Install-Timesheet.ps1` to add the schedule. It keeps your existing `config.json`.

## Updating

```powershell
git -C "$env:USERPROFILE\.claude\skills\timesheet" pull
```

Your `config.json` is ignored by git, so updates never overwrite your settings. If an update adds new settings, run `Install-Timesheet.ps1` again to set them.

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

`config.json` is personal. It's listed in `.gitignore`, so don't force-add it or share it.

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
