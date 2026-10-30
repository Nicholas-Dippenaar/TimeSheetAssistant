<#
.SYNOPSIS
  Collects work activity for a date range into a markdown file for the timesheet skill.

.DESCRIPTION
  Covers -Start (inclusive) to -End (exclusive), both dates. Weekly runs pass Saturday before through
  Friday, so weekend work is never lost between weeks; daily runs pass a single day.
  Sources: git commits under the configured repo roots, pull requests (GitHub via gh, Azure DevOps
  via az, detected from each repo's origin remote), typed Claude Code prompts, and notes and Claude
  memory files modified in range. Prompts are truncated to keep the raw file small and limit
  incidental personal information.
#>
param(
  [Parameter(Mandatory)] [datetime] $Start,
  [Parameter(Mandatory)] [datetime] $End,
  [Parameter(Mandatory)] [string] $OutFile,
  [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$start = $Start.Date
$end = $End.Date
$maxPromptLength = 300
$maxPullRequests = 100
$sb = [System.Text.StringBuilder]::new()
function Add-Line([string] $text = '') { [void]$sb.AppendLine($text) }
function In-Range([datetime] $when) { $when -ge $start -and $when -lt $end }

$authors = @($config.git.authors | Where-Object { $_ })
if ($authors.Count -eq 0) {
  $authors = @((git config --global user.name), (git config --global user.email) | Where-Object { $_ })
}

Add-Line ("# Timesheet raw data: {0} to {1}" -f $start.ToString('ddd yyyy-MM-dd', $inv), $end.AddDays(-1).ToString('ddd yyyy-MM-dd', $inv))
Add-Line ("Collected {0} (local time)." -f (Get-Date).ToString('yyyy-MM-dd HH:mm', $inv))
Add-Line

# --- Git commits ---------------------------------------------------------------------------
Add-Line '## Git commits (committer time | hash | refs | subject, then shortstat)'
$repos = foreach ($root in $config.git.repoRoots) {
  Get-ChildItem $root -Directory -Depth 2 -Filter .git -Force -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Parent.FullName }
}
$authorArgs = $authors | ForEach-Object { "--author=$_" }
$activeRepos = @()
foreach ($repo in $repos) {
  $log = git -C $repo log --all @authorArgs `
    "--since=$($start.ToString('yyyy-MM-dd 00:00', $inv))" "--until=$($end.ToString('yyyy-MM-dd 00:00', $inv))" `
    "--date=format-local:%a %Y-%m-%d %H:%M" "--pretty=format:%cd | %h | %D | %s" --shortstat 2>$null
  $lines = @($log | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  if ($lines.Count -eq 0) { continue }
  $activeRepos += $repo
  Add-Line
  Add-Line "### $repo"
  Add-Line '```'
  $lines | ForEach-Object { Add-Line $_ }
  Add-Line '```'
}
if ($activeRepos.Count -eq 0) { Add-Line; Add-Line '_No commits found._' }
Add-Line

# --- Pull requests -------------------------------------------------------------------------
function Get-GitHubPullRequests([string] $ghRepo) {
  $json = gh pr list -R $ghRepo --author '@me' --state all --limit $maxPullRequests `
    --search "updated:>=$($start.ToString('yyyy-MM-dd', $inv))" --json number,title,headRefName,state 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'gh failed' }
  foreach ($pr in @($json | ConvertFrom-Json)) {
    "- {0} #{1} [{2}] {3} - {4}" -f $ghRepo, $pr.number, $pr.state, $pr.headRefName, $pr.title
  }
}

function Get-AzureDevOpsPullRequests([string] $org, [string] $project, [string] $repoName) {
  $creator = $config.git.azureDevOpsCreator
  if (-not $creator) { $creator = az account show --query user.name -o tsv 2>$null }
  if (-not $creator) { throw 'az not logged in' }
  $json = az repos pr list --organization "https://dev.azure.com/$org" --project $project --repository $repoName `
    --creator $creator --status all --top $maxPullRequests --output json 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'az failed' }
  foreach ($pr in @($json | ConvertFrom-Json)) {
    $created = [datetime]$pr.creationDate
    $closed = if ($pr.closedDate) { [datetime]$pr.closedDate } else { $null }
    if ($created -lt $start -and (-not $closed -or $closed -lt $start) -and $pr.status -ne 'active') { continue }
    "- {0}/{1} !{2} [{3}] {4} - {5}" -f $project, $repoName, $pr.pullRequestId, $pr.status, ($pr.sourceRefName -replace '^refs/heads/', ''), $pr.title
  }
}

Add-Line '## Pull requests updated in range (repos with commits only)'
if ($config.git.pullRequests) {
  foreach ($repo in $activeRepos) {
    $remote = git -C $repo remote get-url origin 2>$null
    try {
      if ($remote -match 'github\.com[:/](.+?)(\.git)?$') {
        Get-GitHubPullRequests $Matches[1] | ForEach-Object { Add-Line $_ }
      }
      elseif ($remote -match 'dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+?)/?$' -or
              $remote -match 'ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/([^/]+?)/?$' -or
              $remote -match '([^/.@]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git/([^/]+?)/?$') {
        $parts = 1..3 | ForEach-Object { [uri]::UnescapeDataString($Matches[$_]) }
        Get-AzureDevOpsPullRequests @parts | ForEach-Object { Add-Line $_ }
      }
    }
    catch {
      Add-Line "- $repo - PR lookup failed ($($_.Exception.Message)); check gh / az is installed and logged in"
    }
  }
}
else {
  Add-Line '_Disabled in config._'
}
Add-Line

# --- Claude Code prompts -------------------------------------------------------------------
Add-Line "## Typed Claude Code prompts (local time | project | branch | prompt, first $maxPromptLength chars)"
$sessionFiles = Get-ChildItem (Join-Path $env:USERPROFILE '.claude\projects\*\*.jsonl') -ErrorAction SilentlyContinue |
  Where-Object LastWriteTime -ge $start
$prompts = foreach ($file in $sessionFiles) {
  foreach ($match in Select-String -LiteralPath $file.FullName -Pattern '"promptSource":"typed"' -SimpleMatch) {
    if ($match.Line -notmatch '"timestamp":"([^"]+)"') { continue }
    $when = [DateTimeOffset]::Parse($Matches[1], $inv).LocalDateTime
    if (-not (In-Range $when)) { continue }
    $entry = $match.Line | ConvertFrom-Json -Depth 50
    if ($entry.type -ne 'user') { continue }
    $content = $entry.message.content
    $text = if ($content -is [string]) { $content } else { ($content | Where-Object type -eq 'text' | ForEach-Object text) -join ' ' }
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt $maxPromptLength) { $text = $text.Substring(0, $maxPromptLength) + '...' }
    [pscustomobject]@{
      When = $when
      Project = if ($entry.cwd) { Split-Path $entry.cwd -Leaf } else { '?' }
      Branch = $entry.gitBranch
      Text = $text
    }
  }
}
$prompts = @($prompts | Sort-Object When)
foreach ($day in ($prompts | Group-Object { $_.When.Date })) {
  Add-Line
  Add-Line ("### {0}" -f ([datetime]$day.Name).ToString('dddd yyyy-MM-dd', $inv))
  foreach ($p in $day.Group) {
    Add-Line ("- {0} [{1} | {2}] {3}" -f $p.When.ToString('HH:mm', $inv), $p.Project, $p.Branch, $p.Text)
  }
}
if ($prompts.Count -eq 0) { Add-Line; Add-Line '_No typed prompts found._' }
Add-Line

# --- Notes and memory ----------------------------------------------------------------------
Add-Line '## Notes files modified in range (excluding the timesheet output folder)'
$outputRoot = $config.outputRoot.TrimEnd('\')
foreach ($notesRoot in $config.notesRoots) {
  $notesRoot = $notesRoot.TrimEnd('\')
  Get-ChildItem $notesRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { (In-Range $_.LastWriteTime) -and -not $_.FullName.StartsWith("$outputRoot\", [StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object LastWriteTime |
    ForEach-Object { Add-Line ("- {0} {1}" -f $_.LastWriteTime.ToString('ddd yyyy-MM-dd HH:mm', $inv), $_.FullName.Substring($notesRoot.Length + 1)) }
}
Add-Line

Add-Line '## Claude memory files modified in range'
Get-ChildItem (Join-Path $env:USERPROFILE '.claude\projects\*\memory\*.md') -ErrorAction SilentlyContinue |
  Where-Object { (In-Range $_.LastWriteTime) -and $_.Name -ne 'MEMORY.md' } |
  Sort-Object LastWriteTime |
  ForEach-Object {
    $description = (Select-String -LiteralPath $_.FullName -Pattern '^description:\s*(.*)$' | Select-Object -First 1).Matches.Groups[1].Value
    Add-Line ("- {0} {1} - {2}" -f $_.LastWriteTime.ToString('ddd yyyy-MM-dd HH:mm', $inv), $_.BaseName, "$description".Trim('"'))
  }

New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
Set-Content -LiteralPath $OutFile -Value $sb.ToString() -Encoding utf8
