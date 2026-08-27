# ==============================================================================
# DeepSeek Harness (DSH) 服务管理与一键启动脚本
# ==============================================================================
# 支持操作:
#   启动 (Start)   - 启动 DSH Web 服务 (含自动环境检测、构建校验、依赖自愈)
#   重启 (Restart) - 停止当前运行的实例并重新启动
#   停止 (Stop)    - 精准检测并安全停止当前运行的 DSH Web 服务进程
#   状态 (Status)  - 查看 DSH Web 服务当前的运行状态与端口占用
#   菜单 (Menu)    - 打开交互式服务管理控制台
#   退出 (Exit)    - 退出脚本
#
# 使用方法:
#   powershell -ExecutionPolicy Bypass -File .\start-dsh.ps1 [Action] [Options]
#
# 常用命令示例:
#   .\start-dsh.ps1               # 默认前台启动服务
#   .\start-dsh.ps1 start         # 前台启动服务
#   .\start-dsh.ps1 start -b      # 后台启动服务
#   .\start-dsh.ps1 restart       # 重启服务
#   .\start-dsh.ps1 stop          # 停止服务
#   .\start-dsh.ps1 status        # 查看服务运行状态
#   .\start-dsh.ps1 menu          # 打开交互式服务管理控制台
#
# 可选参数:
#   -Port <N>          指定 Web 服务端口 (默认 3080)
#   -Background (-b)   在后台启动服务 (不阻塞当前控制台)
#   -Proxy <url/port>  手动指定代理地址 (如: http://127.0.0.1:7890 或 7890)
#   -NoProxy           禁用代理检测与配置
#   -NoOpen            启动后不自动在默认浏览器中打开页面
#   -Dev               在独立窗口中启动 dev:web 客户端 HMR 监听器
#   -SkipUpdate        跳过检查官方仓库更新
#   -ForceBuild        强制重新执行 pnpm run build
# ==============================================================================

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
  [Parameter(Position = 0, ParameterSetName = 'Default')]
  [ValidateSet('start', 'restart', 'stop', 'status', 'menu', 'exit', 'quit', '启动', '重启', '停止', '状态', '菜单', '退出', IgnoreCase = $true)]
  [string]$Action = 'start',

  [Alias('s')]
  [switch]$Start,

  [Alias('r')]
  [switch]$Restart,

  [switch]$Stop,

  [switch]$Status,

  [Alias('m')]
  [switch]$Menu,

  [Alias('q')]
  [switch]$Exit,

  [Alias('b')]
  [switch]$Background,

  [string]$Proxy,
  [switch]$NoProxy,
  [switch]$NoOpen,
  [switch]$Dev,
  [ValidateRange(1, 65535)]
  [int]$Port = 3080,
  [switch]$SkipUpdate,
  [switch]$ForceBuild
)

$ErrorActionPreference = 'Stop'
if ($PSScriptRoot) {
  Set-Location -LiteralPath $PSScriptRoot
}

try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# 解析动作别名
$actionSwitchCount = @($Start, $Restart, $Stop, $Status, $Menu, $Exit | Where-Object { $_ }).Count
if ($actionSwitchCount -gt 1) {
  Write-Host '[start] 错误: Start、Restart、Stop、Status、Menu、Exit 操作开关只能指定一个。' -ForegroundColor Red
  exit 1
}
if ($Stop)    { $Action = 'stop' }
if ($Restart) { $Action = 'restart' }
if ($Start)   { $Action = 'start' }
if ($Status)  { $Action = 'status' }
if ($Menu)    { $Action = 'menu' }
if ($Exit)    { $Action = 'exit' }

# 标准化动作名称
switch ($Action.ToLower()) {
  '启动' { $Action = 'start' }
  '重启' { $Action = 'restart' }
  '停止' { $Action = 'stop' }
  '状态' { $Action = 'status' }
  '菜单' { $Action = 'menu' }
  '退出' { $Action = 'exit' }
  'quit' { $Action = 'exit' }
}

# --- 工具函数: 获取监听指定端口的进程 PID --------------------------------------
function Get-WebPortOwnerPids([int]$TargetPort) {
  $targetPids = @()

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
      $conns = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue
      if ($conns) {
        $targetPids += ($conns | Select-Object -ExpandProperty OwningProcess -Unique)
      }
    } catch { }
  }

  try {
    $netstatOutput = netstat -ano 2>$null | Select-String ("^\s*TCP\s+[\d\.\[\]:]+:" + $TargetPort + "\s+.*?LISTENING\s+(\d+)")
    foreach ($matchLine in $netstatOutput) {
      if ($matchLine.Matches.Count -gt 0 -and $matchLine.Matches[0].Groups.Count -gt 1) {
        $pidVal = 0
        if ([int]::TryParse($matchLine.Matches[0].Groups[1].Value, [ref]$pidVal) -and $pidVal -gt 0) {
          $targetPids += $pidVal
        }
      }
    }
  } catch { }

  return ($targetPids | Where-Object { $_ -and $_ -gt 0 } | Select-Object -Unique)
}

# --- 工具函数: 确认监听指定端口的 DSH Web 进程 PID ------------------------------
function Get-WebPortPids([int]$TargetPort) {
  $portOwnerPids = @(Get-WebPortOwnerPids $TargetPort)
  if ($portOwnerPids.Count -eq 0) { return @() }

  try {
    $dshProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ($portOwnerPids -contains $_.ProcessId) -and (
        $_.CommandLine -match "apps[\\/]cli[\\/]lib[\\/]bin\.js\s+web" -or $_.CommandLine -match "dsh\s+web"
      )
    }
    if ($dshProcs) {
      return @($dshProcs | Select-Object -ExpandProperty ProcessId -Unique)
    }
  } catch { }

  return @()
}

# --- 工具函数: 查询服务运行状态 ----------------------------------------------
function Get-DshServiceStatus([int]$TargetPort) {
  $pids = Get-WebPortPids $TargetPort
  if (-not $pids -or $pids.Count -eq 0) {
    return [PSCustomObject]@{
      IsRunning = $false
      Port      = $TargetPort
      Pids      = @()
      Processes = @()
    }
  }

  $procs = @()
  foreach ($p in $pids) {
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    if ($proc) { $procs += $proc }
  }

  return [PSCustomObject]@{
    IsRunning = [bool]($procs.Count -gt 0)
    Port      = $TargetPort
    Pids      = ($procs | Select-Object -ExpandProperty Id -Unique)
    Processes = $procs
  }
}

# --- 操作 1: 打印服务运行状态 (Status) ----------------------------------------
function Show-DshStatus([int]$TargetPort) {
  Write-Host '====================================================' -ForegroundColor Cyan
  Write-Host ' DeepSeek Harness (DSH) 服务状态检查' -ForegroundColor Cyan
  Write-Host '====================================================' -ForegroundColor Cyan

  $status = Get-DshServiceStatus $TargetPort
  if ($status.IsRunning) {
    Write-Host "[status] 服务状态: " -NoNewline
    Write-Host "● 正在运行 (Running)" -ForegroundColor Green
    Write-Host "[status] 监听端口: $TargetPort" -ForegroundColor Cyan
    Write-Host "[status] 访问地址: http://127.0.0.1:$TargetPort/" -ForegroundColor Green

    foreach ($proc in $status.Processes) {
      $memMB = [math]::Round($proc.WorkingSet64 / 1MB, 2)
      $startTime = try { $proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { '未知' }
      Write-Host "[status] 进程详情: PID $($proc.Id) | 名称: $($proc.ProcessName) | 内存: $memMB MB | 启动时间: $startTime" -ForegroundColor Gray
    }

    $dshHome = if ($env:DSH_HOME -and $env:DSH_HOME.Trim()) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
    $stdoutLog = Join-Path $dshHome 'logs\web-out.log'
    if (Test-Path $stdoutLog) {
      Write-Host "[status] 日志路径: $stdoutLog" -ForegroundColor DarkGray
    }
  } else {
    Write-Host "[status] 服务状态: " -NoNewline
    Write-Host "○ 未运行 (Stopped)" -ForegroundColor Yellow
    Write-Host "[status] 端口 $TargetPort 上未检测到 DSH Web 服务。" -ForegroundColor Gray
  }
  Write-Host '====================================================' -ForegroundColor Cyan
}

# --- 操作 2: 停止服务 (Stop) --------------------------------------------------
function Stop-DshService([int]$TargetPort, [switch]$Silent) {
  $pids = Get-WebPortPids $TargetPort
  if (-not $pids -or $pids.Count -eq 0) {
    if (-not $Silent) {
      Write-Host "[stop] 端口 $TargetPort 上未检测到正在运行的 DSH Web 服务。" -ForegroundColor Yellow
    }
    return $true
  }

  Write-Host "[stop] 检测到端口 $TargetPort 上的服务实例 (PID: $($pids -join ', '))，正在停止..." -ForegroundColor Yellow

  foreach ($pidToKill in $pids) {
    $proc = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
    if (-not $proc) { continue }

    try {
      Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue
    } catch { }
    try {
      taskkill /F /T /PID $pidToKill 2>&1 | Out-Null
    } catch { }
  }

  # 等待端口完全释放
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline) {
    $remainingPids = Get-WebPortOwnerPids $TargetPort
    if (-not $remainingPids -or $remainingPids.Count -eq 0) {
      if (-not $Silent) {
        Write-Host "[stop] DSH Web 服务已成功停止，端口 $TargetPort 已释放。" -ForegroundColor Green
      }
      return $true
    }
    Start-Sleep -Milliseconds 300
  }

  Write-Host "[stop] 警告: 等待端口 $TargetPort 释放超时，请检查系统后台进程。" -ForegroundColor Yellow
  return $false
}

# --- 操作 3: 启动服务 (Start) --------------------------------------------------
function Start-DshService([switch]$RunInBackground) {
  # 1. 本地网络代理检测与配置
  $configuredProxy = $null
  if (-not $NoProxy) {
    if ($Proxy) {
      if ($Proxy -match '^\d+$') {
        $configuredProxy = "http://127.0.0.1:$Proxy"
      } elseif ($Proxy -notmatch '^https?://') {
        $configuredProxy = "http://$Proxy"
      } else {
        $configuredProxy = $Proxy
      }
    } elseif ($env:HTTP_PROXY) {
      $configuredProxy = $env:HTTP_PROXY
    } elseif ($env:HTTPS_PROXY) {
      $configuredProxy = $env:HTTPS_PROXY
    } elseif ($env:ALL_PROXY) {
      $configuredProxy = $env:ALL_PROXY
    } else {
      # 自动探测常见本地代理端口 (Clash/Mihomo: 7890, Clash Verge: 7897, v2rayN: 10808/10809, SS: 1080, 8080)
      $candidatePorts = @(7890, 7897, 10808, 10809, 1080, 8080)
      foreach ($candidatePort in $candidatePorts) {
        $isPortOpen = $false
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
          $c = Get-NetTCPConnection -LocalPort $candidatePort -State Listen -ErrorAction SilentlyContinue
          if ($c) { $isPortOpen = $true }
        }
        if (-not $isPortOpen) {
          $ns = netstat -ano 2>$null | Select-String "^\s*TCP\s+[\d\.\[\]:]+:$candidatePort\s+.*?LISTENING"
          if ($ns) { $isPortOpen = $true }
        }
        if ($isPortOpen) {
          $configuredProxy = "http://127.0.0.1:$candidatePort"
          break
        }
      }
    }

    if ($configuredProxy) {
      Write-Host "[start] 已检测并启用本地代理: $configuredProxy" -ForegroundColor Cyan
      $env:HTTP_PROXY  = $configuredProxy
      $env:HTTPS_PROXY = $configuredProxy
      $env:ALL_PROXY   = $configuredProxy
      $env:http_proxy  = $configuredProxy
      $env:https_proxy = $configuredProxy
      $env:all_proxy   = $configuredProxy
      $env:NO_PROXY    = 'localhost,127.0.0.1,::1'
      $env:no_proxy    = 'localhost,127.0.0.1,::1'
    }
  } else {
    Write-Host '[start] 已显式禁用代理。' -ForegroundColor Yellow
    $env:HTTP_PROXY  = $null
    $env:HTTPS_PROXY = $null
    $env:ALL_PROXY   = $null
    $env:http_proxy  = $null
    $env:https_proxy = $null
    $env:all_proxy   = $null
  }

  # 2. 前置依赖检测
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '[start] 错误: 未在 PATH 中检测到 git，请先安装 Git。' -ForegroundColor Red
    exit 1
  }

  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host '[start] 错误: 未在 PATH 中检测到 node (需要 Node.js ^22.19 || >=24)。' -ForegroundColor Red
    exit 1
  }

  if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host '[start] 未检测到 pnpm，正在通过 corepack 启用...' -ForegroundColor Yellow
    corepack enable
    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
      Write-Host '[start] 错误: 启用 pnpm 失败，请先手动安装 pnpm。' -ForegroundColor Red
      exit 1
    }
  }

  # 3. 检测官方仓库更新并合并
  $needsBuild = $ForceBuild
  $isGitRepo = (git rev-parse --is-inside-work-tree 2>$null) -eq 'true'

  if (-not $SkipUpdate) {
    if ($isGitRepo) {
      Write-Host '[start] 正在检查官方仓库是否有更新...' -ForegroundColor Cyan
      $currentBranch = (git branch --show-current 2>$null)
      if ($currentBranch) { $currentBranch = $currentBranch.Trim() }
      if (-not $currentBranch) { $currentBranch = 'master' }

      $gitProxyArgs = @()
      if ($configuredProxy) {
        $gitProxyArgs += @('-c', "http.proxy=$configuredProxy", '-c', "https.proxy=$configuredProxy")
      }

      # 智能探测目标远端：优先匹配当前分支 tracking remote 或 upstream (官方仓库)，缺省回退到 origin
      $targetRemote = 'origin'
      $trackingRemote = (git config --get "branch.$currentBranch.remote" 2>$null)
      if ($trackingRemote) { $trackingRemote = $trackingRemote.Trim() }
      $remotes = (git remote 2>$null)
      if ($trackingRemote -and ($remotes -contains $trackingRemote)) {
        $targetRemote = $trackingRemote
      } elseif ($remotes -contains 'upstream') {
        $targetRemote = 'upstream'
      }

      $fetchSuccess = $false
      try {
        & git @gitProxyArgs fetch $targetRemote $currentBranch --prune 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          $fetchSuccess = $true
        } else {
          Write-Host "[start] 提示: 检查远端 ($targetRemote) 更新失败 (可能处于离线状态或网络受限)，跳过更新检测。" -ForegroundColor Yellow
        }
      } catch {
        Write-Host "[start] 提示: 检查远端 ($targetRemote) 更新失败 (离线)，跳过更新检测。" -ForegroundColor Yellow
      }

      if ($fetchSuccess) {
        $localRev = (git rev-parse HEAD 2>$null)
        if ($localRev) { $localRev = $localRev.Trim() }
        $remoteRev = (git rev-parse "$targetRemote/$currentBranch" 2>$null)
        if ($remoteRev) { $remoteRev = $remoteRev.Trim() }

        if ($remoteRev -and ($localRev -ne $remoteRev)) {
          $behindCountRaw = (git rev-list --count "HEAD..$targetRemote/$currentBranch" 2>$null)
          $behindCount = if ($behindCountRaw) { [int]$behindCountRaw.Trim() } else { 0 }

          if ($behindCount -gt 0) {
            Write-Host "[start] 检测到官方仓库 ($targetRemote) 有 $behindCount 个新提交，开始拉取并合并更新..." -ForegroundColor Green

            # 检查是否有未提交的修改
            $status = (git status --porcelain 2>$null)
            $hasLocalChanges = [bool]($status -and $status.Trim().Length -gt 0)
            $stashed = $false

            if ($hasLocalChanges) {
              Write-Host '[start] 检测到本地存在修改，正在暂存本地改动...' -ForegroundColor Cyan
              git stash push -u -m "dsh-auto-stash-before-update" 2>&1 | Out-Null
              $stashed = $true
            }

            Write-Host "[start] 正在拉取远端 $targetRemote/$currentBranch 更新..." -ForegroundColor Cyan
            & git @gitProxyArgs pull --rebase $targetRemote $currentBranch
            if ($LASTEXITCODE -ne 0) {
              git rebase --abort 2>$null | Out-Null
              Write-Host '[start] 错误: git pull 更新合并失败，已尝试中止 rebase；请确认工作区状态后再启动。' -ForegroundColor Red
              if ($stashed) {
                Write-Host '[start] 提示: 之前暂存的本地修改保留在 git stash 中。' -ForegroundColor Yellow
              }
              exit 1
            }

            if ($stashed) {
              Write-Host '[start] 正在恢复本地暂存的修改...' -ForegroundColor Cyan
              git stash pop 2>&1 | Out-Null
              if ($LASTEXITCODE -ne 0) {
                Write-Host '[start] 错误: 恢复本地修改时存在冲突，已停止启动；请先解决工作区冲突。' -ForegroundColor Red
                Write-Host '[start] 提示: 未跟踪文件可能仍在 stash 中，可运行 git stash list 查看。' -ForegroundColor Yellow
                exit 1
              }
            }

            Write-Host '[start] 代码更新与合并完成。' -ForegroundColor Green
            $needsBuild = $true
          } else {
            Write-Host '[start] 当前代码已是最新版本。' -ForegroundColor Green
          }
        } else {
          Write-Host '[start] 当前代码已是最新版本。' -ForegroundColor Green
        }
      }
    }
  }

  # 4. 依赖安装 (pnpm install)
  if ($isGitRepo) {
    try {
      $gitDir = (git rev-parse --git-dir 2>$null)
      if ($gitDir) {
        $gitDir = $gitDir.Trim()
        $wtConfigFile = Join-Path $gitDir 'config.worktree'
        $wtExt = (git config --get extensions.worktreeConfig 2>$null)
        if ((Test-Path $wtConfigFile) -and ($wtExt -ne 'true')) {
          git config core.repositoryFormatVersion 1 2>&1 | Out-Null
          git config extensions.worktreeConfig true 2>&1 | Out-Null
        }
      }
    } catch { }
  }

  Write-Host '[start] 正在校验并安装项目依赖 (pnpm install)...' -ForegroundColor Cyan
  pnpm install
  if ($LASTEXITCODE -ne 0) {
    Write-Host '[start] 错误: 依赖安装失败 (pnpm install 出错)，请检查网络与环境。' -ForegroundColor Red
    exit 1
  }

  # 5. 构建与检测无报错 (Build & Zero-Error Check)
  $repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
  $webDist = Join-Path $repoRoot 'apps\web\dist'
  $cliDist = Join-Path $repoRoot 'apps\cli\lib\bin.js'
  $bootLib = Join-Path $repoRoot 'packages\boot\app-boot\lib\index.js'

  if ($needsBuild -or (-not (Test-Path $webDist)) -or (-not (Test-Path $cliDist)) -or (-not (Test-Path $bootLib))) {
    Write-Host '[start] 正在构建项目并进行校验 (pnpm run build)...' -ForegroundColor Cyan
    pnpm run build
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[start] 错误: 项目构建校验失败，发现错误，终止启动。请先修复上述报错。' -ForegroundColor Red
      exit 1
    }
    Write-Host '[start] 项目构建与校验成功，无报错。' -ForegroundColor Green
  }

  # 6. Web Profile 依赖完整性与 Loader 条目唯一性校验
  $dshHome = if ($env:DSH_HOME -and $env:DSH_HOME.Trim()) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $webProfileDir = Join-Path $dshHome 'profiles\web'
  $profileCheckScript = @'
const { createRequire } = await import('node:module')
const { pathToFileURL } = await import('node:url')
const { readFileSync } = await import('node:fs')
const repoRoot = process.argv[1]
const profile = process.argv[2]
const profileDir = process.argv[3]
const anchor = repoRoot + '/apps/cli/package.json'
const pkgPath = profileDir + '/package.json'
const deps = Object.keys(JSON.parse(readFileSync(pkgPath, 'utf8')).dependencies || {})
const rq = createRequire(pkgPath)
const missing = deps.filter(d => { try { rq.resolve(d); return false } catch { return true } })
if (missing.length) { console.error('[start] web profile 依赖未正确安装: ' + missing.join(', ')); process.exit(1) }
const boot = await import(pathToFileURL(repoRoot + '/packages/boot/app-boot/lib/index.js').href)
boot.healProfilesModuleFallback(anchor)
try {
  const loaded = boot.loadProfile('dsh', profile, anchor)
  const seenEntries = new Map()
  for (const layer of loaded.layers) {
    for (const patch of layer.patches) {
      if (patch.insert) {
        for (const item of patch.insert) {
          if (item && item.id) {
            if (seenEntries.has(item.id)) {
              console.error('[start] 错误: 发现重复的插件条目 ID: ' + item.id + ', 冲突来源: ' + seenEntries.get(item.id) + ' 与 ' + layer.packageName)
              console.error('[start] 请通过 node apps/cli/lib/bin.js plugin --profile web remove <package> 移除冲突插件')
              process.exit(1)
            }
            seenEntries.set(item.id, layer.packageName)
          }
        }
      }
    }
  }
  boot.composeEntries([...loaded.layers.map(l => l.patches), loaded.patches])
}
catch (e) { console.error('[start] web profile bundles 预检失败: ' + e.message); process.exit(1) }
'@
  function Test-WebProfileDeps {
    if (-not (Test-Path (Join-Path $webProfileDir 'package.json'))) { return $true }
    & node --input-type=module -e $profileCheckScript $repoRoot 'web' $webProfileDir
    return ($LASTEXITCODE -eq 0)
  }

  if (-not (Test-WebProfileDeps)) {
    Write-Host '[start] 检测到 web profile 插件依赖缺失，正在通过 dsh plugin install 修复...' -ForegroundColor Yellow
    if (Test-Path $cliDist) {
      & node $cliDist plugin --profile web install
    } else {
      & pnpm dsh plugin --profile web install
    }
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[start] 错误: web profile 依赖修复失败 (dsh plugin install 出错)，终止启动。' -ForegroundColor Red
      exit 1
    }
    if (-not (Test-WebProfileDeps)) {
      Write-Host '[start] 错误: web profile 依赖校验仍未通过，终止启动。' -ForegroundColor Red
      exit 1
    }
    Write-Host '[start] web profile 依赖已修复。' -ForegroundColor Green
  }

  # 7. 可选 HMR Watcher (Dev Mode)
  if ($Dev) {
    Write-Host '[start] 正在新窗口中启动 dev:web 监听器...' -ForegroundColor Cyan
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    Start-Process $psExe -ArgumentList @(
      '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command',
      "Set-Location -LiteralPath '$repoRoot'; pnpm run dev:web"
    )
  }

  # 8. 清理旧实例端口占用
  [void](Stop-DshService -TargetPort $Port -Silent)
  $remainingPortOwners = @(Get-WebPortOwnerPids $Port)
  if ($remainingPortOwners.Count -gt 0) {
    Write-Host "[start] 错误: 端口 $Port 正在被其他进程占用 (PID: $($remainingPortOwners -join ', '))。" -ForegroundColor Red
    Write-Host "[start] 请手动关闭占用进程，或通过 -Port 指定其他端口。" -ForegroundColor Red
    exit 1
  }

  # 9. 启动 Web GUI 服务
  $env:DNO_COLOR = '1'
  $cacheDir = Join-Path $repoRoot 'node_modules\.cache\node-compile-cache'
  if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction SilentlyContinue | Out-Null
  }
  $env:NODE_COMPILE_CACHE = $cacheDir

  $cliBin = Join-Path $repoRoot 'apps\cli\lib\bin.js'
  $appArgs = @('web', '--port', "$Port")
  if ($NoOpen -or $RunInBackground) {
    $appArgs += '--no-open'
  }

  if ($RunInBackground) {
    # 后台守护进程模式
    $logDir = Join-Path $dshHome 'logs'
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
    $stdoutLog = Join-Path $logDir 'web-out.log'
    $stderrLog = Join-Path $logDir 'web-err.log'

    Write-Host "[start] 正在后台启动 DeepSeek Harness Web 服务..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath 'node' -ArgumentList (@($cliBin) + $appArgs) -WorkingDirectory $repoRoot -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -WindowStyle Hidden -PassThru

    # 等待服务端口就绪
    Write-Host "[start] 正在等待服务监听端口 $Port 就绪..." -NoNewline
    $deadline = (Get-Date).AddSeconds(15)
    $isReady = $false
    while ((Get-Date) -lt $deadline) {
      $status = Get-DshServiceStatus $Port
      if ($proc.HasExited) { break }
      if ($status.IsRunning -and ($status.Pids -contains $proc.Id)) {
        $isReady = $true
        break
      }
      Write-Host '.' -NoNewline
      Start-Sleep -Milliseconds 400
    }
    Write-Host ''

    if ($isReady) {
      Write-Host "[start] DeepSeek Harness Web 服务已在后台成功启动!" -ForegroundColor Green
      Write-Host "[start] 监听端口: $Port | 进程 PID: $($status.Pids -join ', ')" -ForegroundColor Cyan
      Write-Host "[start] 访问地址: http://127.0.0.1:$Port/" -ForegroundColor Green
      Write-Host "[start] 运行日志: $stdoutLog" -ForegroundColor DarkGray

      if (-not $NoOpen) {
        try { Start-Process "http://127.0.0.1:$Port/" } catch { }
      }
    } else {
      $failureReason = if ($proc.HasExited) { "后台进程已提前退出 (exit $($proc.ExitCode))" } else { '等待服务监听超时' }
      if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        try { taskkill /F /T /PID $proc.Id 2>&1 | Out-Null } catch { }
        $proc.WaitForExit(5000) | Out-Null
      }
      Write-Host "[start] 错误: $failureReason；已停止后台进程，请检查日志: $stderrLog" -ForegroundColor Red
      exit 1
    }
  } else {
    # 前台交互运行模式
    Write-Host "[start] 正在前台启动 DeepSeek Harness Web 服务: http://127.0.0.1:$Port/" -ForegroundColor Green
    if (Test-Path $cliBin) {
      & node $cliBin @appArgs
    } else {
      & pnpm dsh @appArgs
    }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}

# --- 操作 4: 重启服务 (Restart) ------------------------------------------------
function Restart-DshService([switch]$RunInBackground) {
  Write-Host "====================================================" -ForegroundColor Cyan
  Write-Host " 正在重启 DeepSeek Harness (DSH) Web 服务..." -ForegroundColor Cyan
  Write-Host "====================================================" -ForegroundColor Cyan

  if (-not (Stop-DshService -TargetPort $Port)) { exit 1 }
  Start-Sleep -Milliseconds 500
  Start-DshService -RunInBackground:$RunInBackground
}

# --- 操作 5: 交互式控制台菜单 (Menu) -------------------------------------------
function Show-InteractiveMenu {
  while ($true) {
    Clear-Host
    $status = Get-DshServiceStatus $Port
    $statusText = if ($status.IsRunning) { "● 正在运行 (PID: $($status.Pids -join ', ') | 端口: $Port)" } else { "○ 未运行 (已停止)" }
    $statusColor = if ($status.IsRunning) { "Green" } else { "Yellow" }

    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '     DeepSeek Harness (DSH) 服务管理控制台' -ForegroundColor Cyan
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host ' 服务端口: ' -NoNewline
    Write-Host "$Port" -ForegroundColor White
    Write-Host ' 当前状态: ' -NoNewline
    Write-Host "$statusText" -ForegroundColor $statusColor
    if ($status.IsRunning) {
      Write-Host " 访问地址: " -NoNewline
      Write-Host "http://127.0.0.1:$Port/" -ForegroundColor Green
    }
    Write-Host '----------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ' 1. 后台启动服务 (Start in Background)' -ForegroundColor White
    Write-Host ' 2. 前台启动服务 (Start in Foreground)' -ForegroundColor White
    Write-Host ' 3. 重启服务 (Restart)' -ForegroundColor White
    Write-Host ' 4. 停止服务 (Stop)' -ForegroundColor White
    Write-Host ' 5. 查看详细状态 (Status)' -ForegroundColor White
    Write-Host ' 0. 退出控制台 (Exit)' -ForegroundColor White
    Write-Host '====================================================' -ForegroundColor Cyan

    $choice = Read-Host '请输入选项编号 [0-5]'
    Write-Host ''

    switch ($choice.Trim()) {
      '1' {
        Start-DshService -RunInBackground
        Write-Host ''
        Read-Host '按回车键返回菜单...'
      }
      '2' {
        Start-DshService
        return
      }
      '3' {
        Restart-DshService -RunInBackground
        Write-Host ''
        Read-Host '按回车键返回菜单...'
      }
      '4' {
        [void](Stop-DshService -TargetPort $Port)
        Write-Host ''
        Read-Host '按回车键返回菜单...'
      }
      '5' {
        Show-DshStatus -TargetPort $Port
        Write-Host ''
        Read-Host '按回车键返回菜单...'
      }
      '0' {
        Write-Host '已退出服务管理。' -ForegroundColor Gray
        return
      }
      'exit' {
        Write-Host '已退出服务管理。' -ForegroundColor Gray
        return
      }
      'q' {
        Write-Host '已退出服务管理。' -ForegroundColor Gray
        return
      }
      default {
        Write-Host '无效的输入，请输入 0-5 之间的数字。' -ForegroundColor Red
        Start-Sleep -Seconds 1
      }
    }
  }
}

# --- 主执行入口 (Main Dispatcher) ---------------------------------------------
switch ($Action) {
  'start'   { Start-DshService -RunInBackground:$Background }
  'restart' { Restart-DshService -RunInBackground:$Background }
  'stop'    { if (-not (Stop-DshService -TargetPort $Port)) { exit 1 } }
  'status'  { Show-DshStatus -TargetPort $Port }
  'menu'    { Show-InteractiveMenu }
  'exit'    {
    Write-Host '已退出。' -ForegroundColor Gray
    exit 0
  }
  default   {
    Write-Host "未知操作: '$Action'。支持的操作: start, restart, stop, status, menu, exit。" -ForegroundColor Red
    exit 1
  }
}
