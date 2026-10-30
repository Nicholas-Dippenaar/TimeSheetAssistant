<#
.SYNOPSIS
  Guided setup: asks for your timesheet settings, saves config.json and schedules the timesheet task.

.DESCRIPTION
  Each question shows the current value in [brackets]; press Enter to keep it. First-time defaults
  come from config.example.json and your git settings. Safe to re-run any time to change settings:
  the task is replaced.

  -NonInteractive skips the questions and uses config.json as it is (with -Frequency to override).
  -NoSchedule saves the settings without touching the scheduled task.
  -Uninstall removes the scheduled task.
#>
param(
  [ValidateSet('daily', 'weekly')] [string] $Frequency,
  [switch] $NonInteractive,
  [switch] $NoSchedule,
  [switch] $Uninstall,
  [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture
$taskName = 'Claude Timesheet'

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  Write-Output "Removed scheduled task '$taskName'."
  return
}

# --- Prompt helpers --------------------------------------------------------------------------
function Read-Value([string] $question, [string] $current) {
  $answer = Read-Host "$question [$current]"
  if ([string]::IsNullOrWhiteSpace($answer)) { $current } else { $answer.Trim() }
}

function Read-Time([string] $question, [string] $current) {
  while ($true) {
    $answer = Read-Value $question $current
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($answer, 'HH:mm', $inv, 'None', [ref]$parsed)) { return $answer }
    Write-Host '  Please use 24-hour HH:mm, e.g. 08:00 or 17:30.'
  }
}

function Read-Choice([string] $question, [string] $current, [string[]] $options) {
  while ($true) {
    $answer = (Read-Value "$question ($($options -join '/'))" $current).ToLowerInvariant()
    $match = $options | Where-Object { $_.ToLowerInvariant() -eq $answer }
    if ($match) { return $match }
    Write-Host "  Please answer one of: $($options -join ', ')."
  }
}

function Read-Number([string] $question, [int] $current) {
  while ($true) {
    $answer = Read-Value $question $current
    $parsed = 0
    if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    Write-Host '  Please enter a whole number (0 or more).'
  }
}

function Read-YesNo([string] $question, [bool] $current) {
  (Read-Choice $question $(if ($current) { 'y' } else { 'n' }) 'y', 'n') -eq 'y'
}

function Read-List([string] $question, [object[]] $current) {
  $shown = if ($current) { $current -join '; ' } else { 'none' }
  $answer = Read-Host "$question - separate with ';', '-' for none [$shown]"
  if ([string]::IsNullOrWhiteSpace($answer)) { return $current }
  if ($answer.Trim() -eq '-') { return }
  $answer -split ';' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }
}

# --- Prerequisites ---------------------------------------------------------------------------
foreach ($tool in 'pwsh', 'claude', 'git') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' was not found on PATH - install it first (see README.md)." }
}
foreach ($tool in 'gh', 'az') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    Write-Warning "'$tool' not found - pull requests from $(if ($tool -eq 'gh') { 'GitHub' } else { 'Azure DevOps' }) repos will be skipped."
  }
}

# --- Settings --------------------------------------------------------------------------------
$isNew = -not (Test-Path -LiteralPath $ConfigPath)
$config = Get-Content -LiteralPath $(if ($isNew) { Join-Path $PSScriptRoot 'config.example.json' } else { $ConfigPath }) -Raw | ConvertFrom-Json
foreach ($field in @{ frequency = 'weekly'; retentionWeeks = 3; notifications = $true; calendar = $true }.GetEnumerator()) {
  if ($null -eq $config.($field.Key)) { $config | Add-Member -NotePropertyName $field.Key -NotePropertyValue $field.Value }
}
if ($isNew) {
  $config.outputRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Timesheets'
  $config.git.authors = @((git config --global user.name), (git config --global user.email) | Where-Object { $_ })
}

if ($NonInteractive) {
  if ($isNew) { throw "No config.json yet - run without -NonInteractive to set it up." }
}
else {
  Write-Host ''
  Write-Host 'Timesheet setup - press Enter to keep the value in [brackets].'
  Write-Host ''
  $config.outputRoot = Read-Value 'Folder to save timesheets in' $config.outputRoot
  $config.frequency = Read-Choice 'How often do you want a timesheet report?' $config.frequency 'daily', 'weekly'
  $config.workday.start = Read-Time 'Workday start' $config.workday.start
  $config.workday.end = Read-Time 'Workday end' $config.workday.end
  $config.workday.lunchMinutes = Read-Number 'Unbilled lunch, in minutes (0 for none)' $config.workday.lunchMinutes
  if ($config.workday.lunchMinutes -gt 0) {
    $config.workday.lunchWindowStart = Read-Time 'Lunch is usually taken from' $config.workday.lunchWindowStart
    $config.workday.lunchWindowEnd = Read-Time '...until' $config.workday.lunchWindowEnd
  }
  if ($config.frequency -eq 'weekly') {
    $config.schedule.day = Read-Choice 'Which day should the weekly report run? (Friday or later)' $config.schedule.day 'Friday', 'Saturday', 'Sunday', 'Monday'
    $config.schedule.time = Read-Time 'At what time?' $config.schedule.time
  }
  else {
    $config.schedule.time = Read-Time 'What time should the daily report run? (near the end of your day)' $config.schedule.time
  }
  # @() keeps single answers as JSON arrays.
  $config.git.repoRoots = @(Read-List 'Folders that hold your git repos' $config.git.repoRoots)
  $config.git.authors = @(Read-List 'Names/emails your commits use' $config.git.authors)
  $config.git.pullRequests = Read-YesNo 'Look up pull request titles (GitHub / Azure DevOps)?' $config.git.pullRequests
  $config.notesRoots = @(Read-List 'Notes folders to use as evidence (optional)' $config.notesRoots)
  $config.calendar = Read-YesNo 'Use your Outlook calendar for meetings and leave?' $config.calendar
  $config.notifications = Read-YesNo 'Show a Windows notification when a report is ready or fails?' $config.notifications
  $config.retentionWeeks = Read-Number 'Weeks of reports to keep (0 keeps everything)' $config.retentionWeeks
}
if ($Frequency) { $config.frequency = $Frequency }

# --- Validate and save -----------------------------------------------------------------------
if ($config.outputRoot -like '*<you>*') { throw 'outputRoot in config.json still has the <you> placeholder.' }
foreach ($field in 'start', 'end', 'lunchWindowStart', 'lunchWindowEnd') {
  [void][timespan]::Parse($config.workday.$field, $inv)
}
if ([timespan]::Parse($config.workday.end, $inv) -le [timespan]::Parse($config.workday.start, $inv)) {
  throw 'Workday end must be after workday start.'
}
foreach ($root in $config.git.repoRoots) {
  if (-not (Test-Path -LiteralPath $root)) { Write-Warning "Repo folder not found: $root" }
}
New-Item -ItemType Directory -Force $config.outputRoot | Out-Null
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
Write-Output "Settings saved to $ConfigPath."

if ($NoSchedule) { return }

# --- Schedule --------------------------------------------------------------------------------
$time = [datetime]::ParseExact($config.schedule.time, 'HH:mm', $inv)
$trigger = if ($config.frequency -eq 'daily') {
  New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $time
}
else {
  New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([DayOfWeek]$config.schedule.day) -At $time
}

$pwsh = (Get-Command pwsh).Source
$script = Join-Path $PSScriptRoot 'Invoke-Timesheet.ps1'
$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Description "Writes a $($config.frequency) timesheet draft via the Claude Code timesheet skill." `
  -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

$when = if ($config.frequency -eq 'daily') { 'every weekday' } else { "every $($config.schedule.day)" }
$next = (Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo).NextRunTime
Write-Output ''
Write-Output "Scheduled '$taskName' ($($config.frequency)) for $when at $($config.schedule.time). Next run: $($next.ToString('yyyy-MM-dd HH:mm', $inv))."
Write-Output "Your timesheets will be saved in: $($config.outputRoot)\<Month>"
if ($config.retentionWeeks -gt 0) { Write-Output "Reports older than $($config.retentionWeeks) weeks are deleted on each run." }
Write-Output "Test it now with: pwsh -File `"$script`""
