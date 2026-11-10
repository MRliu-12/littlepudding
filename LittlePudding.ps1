<#
  小布丁 LittlePudding - Windows 变更哨兵
  作用：快照关键系统位置 -> 周期性比对 -> 报告变化 -> 等你显式批准。
  默认只提醒，不修改任何东西；-Enforce 仅在自启动项上尝试回滚。

  Actions: init | check | approve | install | uninstall | status
#>
param(
  [ValidateSet('init', 'check', 'approve', 'install', 'uninstall', 'status')]
  [string]$Action = 'check',
  [string]$Id = '',
  [switch]$Enforce,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateDir = Join-Path $Root 'state'
$ReportDir = Join-Path $Root 'reports'
$BaselinePath = Join-Path $StateDir 'baseline.json'
$AllowPath = Join-Path $StateDir 'allowlist.json'
$JournalPath = Join-Path $StateDir 'journal.jsonl'
$LastChangesPath = Join-Path $StateDir 'last-changes.json'
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$TaskName = 'LittlePudding'

foreach ($d in @($Root, $StateDir, $ReportDir)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Say([string]$msg) {
  if (-not $Quiet) { Write-Host $msg }
}

function Now-Text { return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

function Write-Journal($entry) {
  $entry | Add-Member -NotePropertyName at -NotePropertyValue (Now-Text) -Force
  ($entry | ConvertTo-Json -Compress -Depth 6) | Add-Content -Path $JournalPath -Encoding UTF8
}

function Read-JsonFile([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  $raw = Get-Content -Path $path -Raw -Encoding UTF8
  if (-not $raw) { return $null }
  return ($raw | ConvertFrom-Json)
}

function Save-JsonFile([string]$path, $obj) {
  $json = $obj | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function To-Hash($obj) {
  $ht = @{}
  if ($null -eq $obj) { return $ht }
  if ($obj -is [System.Collections.IDictionary]) {
    foreach ($k in $obj.Keys) { $ht[[string]$k] = [string]$obj[$k] }
    return $ht
  }
  foreach ($p in $obj.PSObject.Properties) {
    if ($p.Name -in @('ts')) { continue }
    $ht[[string]$p.Name] = [string]$p.Value
  }
  return $ht
}

function Get-RunValues([string]$regPath) {
  $out = @{}
  if (-not (Test-Path $regPath)) { return $out }
  $item = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
  if (-not $item) { return $out }
  foreach ($p in $item.PSObject.Properties) {
    if ($p.Name -match '^PS') { continue }
    $out[$p.Name] = [string]$p.Value
  }
  return $out
}

function Get-Snapshot {
  $snap = @{ ts = (Now-Text) }

  # ---- 自启动（Run / RunOnce）----
  $run = @{}
  $runPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
  )
  foreach ($rp in $runPaths) {
    $vals = Get-RunValues $rp
    foreach ($k in $vals.Keys) { $run[($rp + '|' + $k)] = $vals[$k] }
  }
  $snap['run'] = $run

  # ---- Winlogon 登录钩子 ----
  $winl = @{}
  $wl = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
  if ($wl) {
    foreach ($k in @('Userinit', 'Shell')) {
      $v = $wl.$k
      if ($null -ne $v) { $winl[$k] = [string]$v }
    }
  }
  $snap['winlogon'] = $winl

  # ---- 服务 ----
  $svc = @{}
  try {
    $services = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop
    foreach ($s in $services) { $svc[$s.Name] = ([string]$s.PathName + '|' + [string]$s.StartMode) }
  } catch {}
  $snap['services'] = $svc

  # ---- 计划任务 ----
  $tasks = @{}
  try {
    $ts = Get-ScheduledTask -ErrorAction Stop
    foreach ($t in $ts) {
      $acts = @()
      foreach ($a in $t.Actions) {
        $line = [string]$a.Execute
        if ($a.Arguments) { $line = $line + ' ' + [string]$a.Arguments }
        $acts += $line
      }
      $tasks[([string]$t.TaskPath + [string]$t.TaskName)] = ([string]$t.Author + '|' + ($acts -join '; '))
    }
  } catch {}
  $snap['tasks'] = $tasks

  # ---- 启动文件夹 ----
  $startup = @{}
  $startDirs = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
  )
  foreach ($sd in $startDirs) {
    if (Test-Path $sd) {
      foreach ($f in (Get-ChildItem -Path $sd -Force -ErrorAction SilentlyContinue)) {
        $startup[($sd + '|' + $f.Name)] = '1'
      }
    }
  }
  $snap['startup'] = $startup

  # ---- 常见扩展名默认关联 ----
  $assoc = @{}
  $exts = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.tif', '.tiff', '.heic', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pps', '.ppsx', '.pdf', '.txt', '.zip', '.7z', '.rar', '.mp3', '.mp4', '.mkv', '.avi', '.html', '.htm', '.exe', '.bat', '.ps1')
  foreach ($e in $exts) {
    $prog = ''
    $uc = Join-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts' ($e + '\UserChoice')
    $u = (Get-ItemProperty -Path $uc -ErrorAction SilentlyContinue).ProgId
    if ($u) { $prog = [string]$u }
    else {
      $h = (Get-ItemProperty -Path ('Registry::HKEY_CLASSES_ROOT\' + $e) -ErrorAction SilentlyContinue).'(default)'
      if ($h) { $prog = [string]$h }
    }
    $assoc[$e] = $prog
  }
  $snap['assoc'] = $assoc

  # ---- hosts ----
  $hosts = @{ hash = ''; lines = '0' }
  if (Test-Path $HostsPath) {
    $bytes = [System.IO.File]::ReadAllBytes($HostsPath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLower()
    $lineCount = ([System.IO.File]::ReadAllLines($HostsPath)).Count
    $hosts = @{ hash = $hash; lines = [string]$lineCount }
  }
  $snap['hosts'] = $hosts

  # ---- Defender 排除项 ----
  $def = @{}
  try {
    $mp = Get-MpPreference -ErrorAction Stop
    if ($mp.ExclusionPath) { foreach ($p in $mp.ExclusionPath) { $def[[string]$p] = '1' } }
  } catch {}
  $snap['defender'] = $def

  return $snap
}

function Get-AllowList {
  $obj = Read-JsonFile $AllowPath
  if ($null -eq $obj) { return @() }
  return @($obj.items)
}

function Save-AllowList($items) {
  Save-JsonFile $AllowPath @{ items = @($items) }
}

function Get-ChangeId([string]$section, [string]$key, [string]$after) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($section + '|' + $key + '|' + $after)
  $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLower()
  return $hash.Substring(0, 12)
}

function Compare-Snapshots($old, $new) {
  $changes = @()
  $sections = @('run', 'winlogon', 'services', 'tasks', 'startup', 'assoc', 'hosts', 'defender')
  $riskMap = @{
    run = '高'; winlogon = '高'; services = '高'; tasks = '高'; startup = '高'; hosts = '高'; defender = '高'; assoc = '中'
  }
  foreach ($sec in $sections) {
    $o = @{}
    $n = @{}
    if ($old) { $o = To-Hash $old.$sec }
    $n = To-Hash $new.$sec
    $keys = @($o.Keys) + @($n.Keys) | Sort-Object -Unique
    foreach ($k in $keys) {
      $before = ''
      $after = ''
      if ($o.ContainsKey($k)) { $before = [string]$o[$k] }
      if ($n.ContainsKey($k)) { $after = [string]$n[$k] }
      if ($before -ceq $after) { continue }
      $kind = '修改'
      if (-not $o.ContainsKey($k)) { $kind = '新增' }
      elseif (-not $n.ContainsKey($k)) { $kind = '删除' }
      $id = Get-ChangeId $sec $k $after
      $changes += [pscustomobject]@{
        id = $id
        section = $sec
        kind = $kind
        key = $k
        before = $before
        after = $after
        risk = $riskMap[$sec]
        time = (Now-Text)
      }
    }
  }
  return @($changes)
}

function Save-LastChanges($changes) {
  Save-JsonFile $LastChangesPath @{ ts = (Now-Text); items = @($changes) }
}

function Get-LastChanges {
  $obj = Read-JsonFile $LastChangesPath
  if ($null -eq $obj) { return @() }
  return @($obj.items)
}

function Do-Init {
  $snap = Get-Snapshot
  Save-JsonFile $BaselinePath $snap
  if (-not (Test-Path $AllowPath)) { Save-AllowList @() }
  Write-Journal ([pscustomobject]@{ action = 'init'; baseline = $snap.ts })
  $counts = @()
  foreach ($sec in @('run', 'winlogon', 'services', 'tasks', 'startup', 'assoc', 'defender')) {
    $counts += ($sec + '=' + @($snap[$sec].Keys).Count)
  }
  Say ('基线已建立：' + ($counts -join '  '))
  Say ('基线文件：' + $BaselinePath)
}

function Do-Check {
  $base = Read-JsonFile $BaselinePath
  if ($null -eq $base) {
    Say '还没有基线，请先运行：LittlePudding.ps1 -Action init'
    return
  }
  $snap = Get-Snapshot
  $changes = Compare-Snapshots $base $snap
  $allow = Get-AllowList
  $allowIds = @{}
  foreach ($a in $allow) { if ($a.id) { $allowIds[[string]$a.id] = $true } }
  $pending = @()
  foreach ($c in $changes) {
    if ($allowIds.ContainsKey($c.id)) { continue }
    $pending += $c
  }
  Save-LastChanges $pending
  Write-Journal ([pscustomobject]@{ action = 'check'; changes = @($changes).Count; pending = @($pending).Count })

  if (-not $pending.Count) {
    Say ('检查完成：无未批准的变化（' + (Now-Text) + '）')
    return
  }

  # ---- 回滚（可选，只处理自启动项）----
  $reverted = @()
  if ($Enforce) {
    $runBase = To-Hash $base.run
    foreach ($c in $pending) {
      if ($c.section -ne 'run') { continue }
      # 键格式：<注册表路径>|<值名>（注册表路径本身不含 |）
      $parts = @(([string]$c.key).Split('|'))
      if ($parts.Count -lt 2) { continue }
      $regRoot = [string]$parts[0]
      $valueName = [string]$parts[$parts.Count - 1]
      if (-not $regRoot -or -not $valueName) { continue }
      try {
        if ($c.kind -eq '新增') {
          Remove-ItemProperty -Path $regRoot -Name $valueName -ErrorAction Stop
          $reverted += ($c.key + ' -> 已删除')
        } elseif ($c.kind -eq '修改' -and $runBase.ContainsKey($c.key)) {
          Set-ItemProperty -Path $regRoot -Name $valueName -Value ([string]$runBase[$c.key]) -ErrorAction Stop
          $reverted += ($c.key + ' -> 已恢复')
        }
      } catch {
        $reverted += ($c.key + ' -> 回滚失败：' + $_.Exception.Message)
      }
    }
    if ($reverted.Count) { Write-Journal ([pscustomobject]@{ action = 'enforce'; items = @($reverted) }) }
  }

  # ---- 报告 ----
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $reportPath = Join-Path $ReportDir ('report-' + $stamp + '.md')
  $lines = @()
  $lines += '# 小布丁检查报告'
  $lines += ''
  $lines += ('- 时间：' + (Now-Text))
  $lines += ('- 基线时间：' + [string]$base.ts)
  $lines += ('- 未批准变化：' + $pending.Count + ' 条')
  $lines += ''
  $lines += '| ID | 类别 | 变化 | 键 | 之前 | 现在 | 风险 |'
  $lines += '|---|---|---|---|---|---|---|'
  foreach ($c in $pending) {
    $b = ([string]$c.before).Replace('|', '/')
    $a = ([string]$c.after).Replace('|', '/')
    $k = ([string]$c.key).Replace('|', '/')
    if ($b.Length -gt 60) { $b = $b.Substring(0, 60) + '...' }
    if ($a.Length -gt 60) { $a = $a.Substring(0, 60) + '...' }
    if ($k.Length -gt 70) { $k = $k.Substring(0, 70) + '...' }
    $lines += ('| ' + $c.id + ' | ' + $c.section + ' | ' + $c.kind + ' | ' + $k + ' | ' + $b + ' | ' + $a + ' | ' + $c.risk + ' |')
  }
  $lines += ''
  $lines += '## 如何处理'
  $lines += ''
  $lines += '1. 如果你确实允许这次改动，运行：'
  $lines += ''
  $lines += '```powershell'
  $lines += ('powershell -ExecutionPolicy Bypass -File "' + (Join-Path $Root 'LittlePudding.ps1') + '" -Action approve -Id <ID>')
  $lines += '```'
  $lines += ''
  $lines += '2. 如果你不允许：按报告里的键自行检查/删除；或重跑 init 重新建基线（不推荐）。'
  $lines += ''
  if ($reverted.Count) {
    $lines += '## 回滚记录（-Enforce）'
    $lines += ''
    foreach ($r in $reverted) { $lines += ('- ' + $r) }
    $lines += ''
  }
  [System.IO.File]::WriteAllText($reportPath, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

  Say ('发现 ' + $pending.Count + ' 条未批准变化，报告：' + $reportPath)
  foreach ($c in $pending) {
    Say ('  [' + $c.id + '] ' + $c.risk + '风险 ' + $c.section + ' ' + $c.kind + '：' + $c.key)
  }
}

function Do-Approve {
  if (-not $Id) { Say '用法：-Action approve -Id <变化ID>（ID 见报告）'; return }
  $last = Get-LastChanges
  $hit = $last | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $hit) { Say ('找不到 ID：' + $Id + '（先跑一次 check，或用报告里的最新 ID）'); return }
  $allow = @(Get-AllowList)
  $allow += [pscustomobject]@{
    id = $hit.id
    section = $hit.section
    key = $hit.key
    after = $hit.after
    approvedAt = (Now-Text)
    note = 'user-approved'
  }
  Save-AllowList $allow
  Write-Journal ([pscustomobject]@{ action = 'approve'; id = $hit.id; section = $hit.section; key = $hit.key })
  Say ('已批准：[' + $hit.id + '] ' + $hit.section + ' ' + $hit.kind + '：' + $hit.key)
}

function Do-Install {
  $scriptPath = Join-Path $Root 'LittlePudding.ps1'
  $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '" -Action check -Quiet'
  $schArgs = @('/Create', '/TN', $TaskName, '/TR', $cmd, '/SC', 'MINUTE', '/MO', '30', '/F')
  $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList $schArgs -Wait -PassThru -WindowStyle Hidden
  if ($p.ExitCode -eq 0) {
    Write-Journal ([pscustomobject]@{ action = 'install'; task = $TaskName })
    Say ('已安装计划任务：' + $TaskName + '（每 30 分钟检查一次）')
    Say '提示：想更频繁可自行改 /MO；想停用运行 -Action uninstall。'
  } else {
    Say ('安装计划任务失败，退出码：' + $p.ExitCode)
  }
}

function Do-Uninstall {
  $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $TaskName, '/F') -Wait -PassThru -WindowStyle Hidden
  Write-Journal ([pscustomobject]@{ action = 'uninstall'; exit = $p.ExitCode })
  Say ('已卸载计划任务：' + $TaskName)
}

function Do-Status {
  $base = Read-JsonFile $BaselinePath
  if ($null -eq $base) { Say '状态：尚未建立基线'; return }
  Say ('基线时间：' + [string]$base.ts)
  foreach ($sec in @('run', 'winlogon', 'services', 'tasks', 'startup', 'assoc', 'defender')) {
    Say ('  ' + $sec + '：' + @((To-Hash $base.$sec).Keys).Count + ' 项')
  }
  Say ('已批准条目：' + @(Get-AllowList).Count)
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) { Say '计划任务：已安装' } else { Say '计划任务：未安装' }
}

switch ($Action) {
  'init' { Do-Init }
  'check' { Do-Check }
  'approve' { Do-Approve }
  'install' { Do-Install }
  'uninstall' { Do-Uninstall }
  'status' { Do-Status }
}
