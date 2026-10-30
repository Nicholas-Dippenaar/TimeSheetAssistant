<#
.SYNOPSIS
  Scheduled entry point: collects activity and has Claude Code write the daily or weekly timesheet.

.DESCRIPTION
  Run by the "Claude Timesheet" scheduled task (see Install-Timesheet.ps1). The config's frequency
  decides the report:
  - weekly: Mon-Fri of the week ending on the most recent Friday (today if Friday).
  - daily:  today once the scheduled time has passed, otherwise the previous weekday - so a late run
            the next morning still writes the right day.
  -Date overrides the target (any day in the week for weekly). Reports go into the month folder of
  the week's Friday, so a week spanning two months has one predictable folder. An existing report is
  left alone unless -Force is given. Reports older than retentionWeeks are deleted. A Windows
  notification reports success (click to open the report) or failure (click to open the log).
  Logs: %LOCALAPPDATA%\ClaudeTimesheet\logs.
#>
param(
  [Alias('WeekEnding')] [datetime] $Date,
  [switch] $Force,
  [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture
$appDir = Join-Path $env:LOCALAPPDATA 'ClaudeTimesheet'
$workDir = Join-Path $appDir 'work'
$logDir = Join-Path $appDir 'logs'
$logRetentionDays = 60
New-Item -ItemType Directory -Force $workDir, $logDir | Out-Null
Get-ChildItem $logDir -Filter *.log | Where-Object LastWriteTime -lt (Get-Date).AddDays(-$logRetentionDays) | Remove-Item

function Get-Friday([datetime] $day) { $day.Date.AddDays([int][DayOfWeek]::Friday - [int]$day.DayOfWeek) }

function Remove-OldReports([string] $root, [int] $weeks) {
  # Only touches files this skill creates; the report's last date decides its age.
  $cutoff = (Get-Date).Date.AddDays(-7 * $weeks)
  Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'Timesheet *.md' -ErrorAction SilentlyContinue | ForEach-Object {
    $dates = [regex]::Matches($_.BaseName, '\d{4}-\d{2}-\d{2}')
    if ($dates.Count -eq 0) { return }
    $lastDay = [datetime]::ParseExact($dates[$dates.Count - 1].Value, 'yyyy-MM-dd', $inv)
    if ($lastDay -lt $cutoff) {
      Remove-Item -LiteralPath $_.FullName
      Write-Output "Removed old report: $($_.FullName)"
    }
  }
}

function Send-Notification([string] $title, [string] $message, [string] $openPath) {
  # PowerShell 7 can't load the WinRT toast types, so Windows PowerShell 5.1 shows the toast.
  # Clicking it opens $openPath. Never fails the run.
  try {
    $escape = { param($text) [System.Security.SecurityElement]::Escape($text) }
    $launch = & $escape ([uri]::new($openPath).AbsoluteUri)
    $toastXml = "<toast activationType=`"protocol`" launch=`"$launch`"><visual><binding template=`"ToastGeneric`">" +
      "<text>$(& $escape $title)</text><text>$(& $escape $message)</text></binding></visual></toast>"
    $script = @"
`$ProgressPreference = 'SilentlyContinue'
`$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
`$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
`$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$xml.LoadXml(@'
$toastXml
'@)
`$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$appId).Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded *> $null
  }
  catch {
    Write-Output "Notification failed: $($_.Exception.Message)"
  }
}

# Seconds + PID so two runs started together never fight over one log file.
$logFile = Join-Path $logDir ("{0}_{1}.log" -f (Get-Date).ToString('yyyy-MM-dd_HHmmss', $inv), $PID)
$notify = $true
Start-Transcript -Path $logFile | Out-Null
try {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "No config found at $ConfigPath. Run Install-Timesheet.ps1 to create it."
  }
  $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  $notify = $config.notifications -ne $false
  $daily = $config.frequency -eq 'daily'
  $workday = $config.workday
  $billableHours = ([timespan]::Parse($workday.end, $inv) - [timespan]::Parse($workday.start, $inv)).TotalHours - $workday.lunchMinutes / 60

  if (-not $Date) {
    $now = Get-Date
    if ($daily) {
      $Date = if ($now.TimeOfDay -ge [timespan]::Parse($config.schedule.time, $inv)) { $now.Date } else { $now.Date.AddDays(-1) }
      while ($Date.DayOfWeek -in 'Saturday', 'Sunday') { $Date = $Date.AddDays(-1) }
    }
    else {
      $Date = $now.Date.AddDays(-(([int]$now.DayOfWeek - [int][DayOfWeek]::Friday + 7) % 7))
    }
  }
  $Date = $Date.Date

  if ($daily) {
    $start = $Date
    $end = $Date.AddDays(1)
    $friday = Get-Friday $Date
    $fileName = "Timesheet {0}.md" -f $Date.ToString('yyyy-MM-dd', $inv)
    $period = "the single day {0}" -f $Date.ToString('dddd yyyy-MM-dd', $inv)
  }
  else {
    $friday = if ($Date.DayOfWeek -in 'Saturday', 'Sunday') { $Date.AddDays(-(([int]$Date.DayOfWeek - 5 + 7) % 7)) } else { Get-Friday $Date }
    $start = $friday.AddDays(-6)
    $end = $friday.AddDays(1)
    $fileName = "Timesheet {0} to {1}.md" -f $friday.AddDays(-4).ToString('yyyy-MM-dd', $inv), $friday.ToString('yyyy-MM-dd', $inv)
    $period = "the week Monday {0} to Friday {1}" -f $friday.AddDays(-4).ToString('yyyy-MM-dd', $inv), $friday.ToString('yyyy-MM-dd', $inv)
  }
  $monthDir = Join-Path $config.outputRoot $friday.ToString('MMMM', $inv)
  $outFile = Join-Path $monthDir $fileName
  $rawFile = Join-Path $workDir ("raw-{0}.md" -f $Date.ToString('yyyy-MM-dd', $inv))

  if ((Test-Path -LiteralPath $outFile) -and -not $Force) {
    Write-Output "Timesheet already exists, leaving it alone: $outFile"
  }
  else {
    New-Item -ItemType Directory -Force $monthDir | Out-Null
    Write-Output "Collecting activity for $period"
    & (Join-Path $PSScriptRoot 'Get-TimesheetData.ps1') -Start $start -End $end -OutFile $rawFile -ConfigPath $ConfigPath

    $calendarLine = if ($config.calendar) {
      'Use the Outlook calendar if the tool is available; if it is not, say so under "Check before you submit".'
    }
    else {
      'Calendar lookup is disabled in config; do not search the calendar.'
    }

    $prompt = @"
Use the timesheet skill to write my $($config.frequency) timesheet for $period.
My working day: $($workday.start)-$($workday.end), with $($workday.lunchMinutes) minutes unbilled lunch taken between $($workday.lunchWindowStart) and $($workday.lunchWindowEnd), so $billableHours billable hours a day.
The raw activity data is already collected at: $rawFile
Write the finished timesheet to exactly this path: $outFile
$calendarLine
This is an unattended scheduled run started at $((Get-Date).ToString('yyyy-MM-dd HH:mm', $inv)): don't ask questions and don't change any other file.
"@

    $allowedTools = 'Read,Glob,Grep,Skill'
    if ($config.calendar) { $allowedTools += ',mcp__claude_ai_Microsoft_365__outlook_calendar_search' }

    # acceptEdits limits writes to the working directory (the month folder) and the added work dir.
    Push-Location $monthDir
    try {
      & claude -p $prompt --permission-mode acceptEdits --add-dir $workDir --max-turns 40 --allowedTools $allowedTools
    }
    finally {
      Pop-Location
    }

    if (-not (Test-Path -LiteralPath $outFile) -or (Get-Item -LiteralPath $outFile).LastWriteTime -lt (Get-Date).AddMinutes(-30)) {
      throw "Claude finished but no new timesheet was written to $outFile"
    }
    Write-Output "Timesheet written: $outFile"

    # The raw file holds prompt excerpts; don't keep it once the timesheet exists.
    Remove-Item -LiteralPath $rawFile

    if ($notify) { Send-Notification 'Timesheet ready' "$fileName - click to open, then check it before submitting." $outFile }
  }

  if ($config.retentionWeeks -gt 0) {
    Remove-OldReports $config.outputRoot $config.retentionWeeks
  }
}
catch {
  Write-Output "FAILED: $($_.Exception.Message)"
  if ($notify) { Send-Notification 'Timesheet failed' "$($_.Exception.Message) - click to open the log." $logFile }
  throw
}
finally {
  Stop-Transcript | Out-Null
}
