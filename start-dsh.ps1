# ==============================================================================
# DeepSeek Harness (DSH) 一键启动与更新脚本
# ==============================================================================
# 核心功能:
#   1. 本地代理智能检测与自动配置 (支持 Clash/Mihomo/v2rayN/SS 等本地代理)
#   2. 前置环境与依赖检测 (git, node, pnpm)
#   3. 自动检测官方仓库更新、自动暂存本地修改并合并
#   4. 自动依赖安装 (仓库 + web profile) 与全量构建校验 (零报错门禁)
#   5. 精准检测并释放服务监听端口 (仅匹配 Listening 状态，排除浏览器客户端连接)
#   6. 启动 DeepSeek Harness Web GUI
#
# 使用方法:
#   powershell -ExecutionPolicy Bypass -File .\start-dsh.ps1
# 可选参数:
#   -Proxy <url/port>  手动指定代理地址 (如: http://127.0.0.1:7890 或 7890)
#   -NoProxy           禁用代理检测与配置
#   -Dev               在独立窗口中启动 dev:web 客户端 HMR 监听器
#   -Port N            指定 Web 服务端口 (默认 3080)
#   -SkipUpdate        跳过检查官方仓库更新
#   -ForceBuild        强制重新执行 pnpm run build
# ==============================================================================

param(
  [string]$Proxy,
  [switch]$NoProxy,
  [switch]$Dev,
  [int]$Port = 3080,
  [switch]$SkipUpdate,
  [switch]$ForceBuild
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# --- 1. 本地网络代理检测与配置 (Proxy Setup) ----------------------------------
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

# --- 2. 前置依赖检测 (Prerequisites Check) ------------------------------------
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

# --- 3. 精准端口监听检测与释放函数 (Port Killer Helper) -------------------------
function Clear-WebPort([int]$TargetPort) {
  $targetPids = @()

  # 方法 1: 使用 Get-NetTCPConnection (精确筛选 State = Listen)
  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
      $conns = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue
      if ($conns) {
        $targetPids += ($conns | Select-Object -ExpandProperty OwningProcess -Unique)
      }
    } catch { }
  }

  # 方法 2: 使用 netstat -ano 兜底匹配 (仅匹配本地地址为 :$TargetPort 且状态为 LISTENING 的服务行)
  try {
    $netstatOutput = netstat -ano 2>$null | Select-String "^\s*TCP\s+[\d\.\[\]:]+:$TargetPort\s+.*?LISTENING\s+(\d+)"
    foreach ($matchLine in $netstatOutput) {
      if ($matchLine.Matches.Count -gt 0 -and $matchLine.Matches[0].Groups.Count -gt 1) {
        $pidVal = 0
        if ([int]::TryParse($matchLine.Matches[0].Groups[1].Value, [ref]$pidVal) -and $pidVal -gt 0) {
          $targetPids += $pidVal
        }
      }
    }
  } catch { }

  $targetPids = $targetPids | Where-Object { $_ -and $_ -gt 0 } | Select-Object -Unique

  if (-not $targetPids -or $targetPids.Count -eq 0) {
    return
  }

  foreach ($pidToKill in $targetPids) {
    $proc = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
    if (-not $proc) { continue }

    if ($proc.ProcessName -ne 'node') {
      Write-Host "[start] 错误: 端口 $TargetPort 正在被非 Node 服务监听 ('$($proc.ProcessName)', PID $pidToKill)。" -ForegroundColor Red
      Write-Host "[start] 请手动关闭该程序，或指定其他端口启动: .\start-dsh.ps1 -Port <N>" -ForegroundColor Red
      exit 1
    }

    Write-Host "[start] 端口 $TargetPort 正在被已有的 dsh 实例监听 (PID $pidToKill)，正在关闭旧实例..." -ForegroundColor Yellow
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
    $stillOccupied = $false
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
      $c = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue
      if ($c) { $stillOccupied = $true }
    }
    if (-not $stillOccupied) {
      $ns = netstat -ano 2>$null | Select-String "^\s*TCP\s+[\d\.\[\]:]+:$TargetPort\s+.*?LISTENING"
      if ($ns) { $stillOccupied = $true }
    }
    if (-not $stillOccupied) {
      Write-Host "[start] 端口 $TargetPort 已成功释放。" -ForegroundColor Green
      return
    }
    Start-Sleep -Milliseconds 300
  }
}

# --- 4. 检测官方仓库更新并合并 (Check & Pull Remote Updates) -------------------
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

    $fetchSuccess = $false
    try {
      & git @gitProxyArgs fetch origin $currentBranch --prune 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) {
        $fetchSuccess = $true
      } else {
        Write-Host '[start] 提示: 检查远端更新失败 (可能处于离线状态或网络受限)，跳过更新检测。' -ForegroundColor Yellow
      }
    } catch {
      Write-Host '[start] 提示: 检查远端更新失败 (离线)，跳过更新检测。' -ForegroundColor Yellow
    }

    if ($fetchSuccess) {
      $localRev = (git rev-parse HEAD 2>$null)
      if ($localRev) { $localRev = $localRev.Trim() }
      $remoteRev = (git rev-parse "origin/$currentBranch" 2>$null)
      if ($remoteRev) { $remoteRev = $remoteRev.Trim() }

      if ($remoteRev -and ($localRev -ne $remoteRev)) {
        $behindCountRaw = (git rev-list --count "HEAD..origin/$currentBranch" 2>$null)
        $behindCount = if ($behindCountRaw) { [int]$behindCountRaw.Trim() } else { 0 }

        if ($behindCount -gt 0) {
          Write-Host "[start] 检测到官方仓库有 $behindCount 个新提交，开始拉取并合并更新..." -ForegroundColor Green

          # 检查是否有未提交的修改
          $status = (git status --porcelain 2>$null)
          $hasLocalChanges = [bool]($status -and $status.Trim().Length -gt 0)
          $stashed = $false

          if ($hasLocalChanges) {
            Write-Host '[start] 检测到本地存在修改，正在暂存本地改动...' -ForegroundColor Cyan
            git stash push -u -m "dsh-auto-stash-before-update" 2>&1 | Out-Null
            $stashed = $true
          }

          Write-Host "[start] 正在拉取远端 origin/$currentBranch 更新..." -ForegroundColor Cyan
          & git @gitProxyArgs pull --rebase origin $currentBranch
          if ($LASTEXITCODE -ne 0) {
            Write-Host '[start] 错误: git pull 更新合并失败，请手动解决冲突后再启动。' -ForegroundColor Red
            if ($stashed) {
              Write-Host '[start] 提示: 之前暂存的本地修改保留在 git stash 中。' -ForegroundColor Yellow
            }
            exit 1
          }

          if ($stashed) {
            Write-Host '[start] 正在恢复本地暂存的修改...' -ForegroundColor Cyan
            git stash pop 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
              Write-Host '[start] 警告: 恢复本地修改时存在冲突，请检查工作区。' -ForegroundColor Yellow
              Write-Host '[start] 提示: 未跟踪文件可能仍在 stash 中，可运行 git stash list 查看、git stash pop 手动恢复。' -ForegroundColor Yellow
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

# --- 5. 依赖安装 (Install Dependencies) ---------------------------------------
# 无条件执行 pnpm install：由 pnpm 的 up-to-date 校验权威判定“所有 node_modules
# 均已正确安装”，并在依赖被清空/部分缺失时自愈重建——node_modules 目录存在
# 不代表安装完整（曾出现仅剩 .cache 的空壳目录导致启动失败）。
if ($isGitRepo) {
  # 修复 Git dormant config.worktree 导致 postinstall lefthook 报错的问题
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

# --- 6. 构建与检测无报错 (Build & Zero-Error Check) ---------------------------
$webDist = Join-Path $PSScriptRoot 'apps\web\dist'
$cliDist = Join-Path $PSScriptRoot 'apps\cli\lib\bin.js'
# 步骤 7 的 profile 预检依赖 dsh-app-boot 构建产物，一并纳入构建门禁：
# 半清理的构建输出（bin.js 在而 app-boot lib 缺失）必须触发重建，而非让预检崩溃。
$bootLib = Join-Path $PSScriptRoot 'packages\boot\app-boot\lib\index.js'

if ($needsBuild -or (-not (Test-Path $webDist)) -or (-not (Test-Path $cliDist)) -or (-not (Test-Path $bootLib))) {
  Write-Host '[start] 正在构建项目并进行校验 (pnpm run build)...' -ForegroundColor Cyan
  pnpm run build
  if ($LASTEXITCODE -ne 0) {
    Write-Host '[start] 错误: 项目构建校验失败，发现错误，终止启动。请先修复上述报错。' -ForegroundColor Red
    exit 1
  }
  Write-Host '[start] 项目构建与校验成功，无报错。' -ForegroundColor Green
}

# --- 7. Web Profile 依赖完整性校验 (Profile Dependency Integrity) -------------
# 启动的 web profile 位于 $DSH_HOME/profiles/web，其第三方插件依赖安装在
# profile 自己的 node_modules 中，仓库 pnpm install 覆盖不到。校验与启动路径
# 完全同构：先逐一解析 package.json 声明的全部依赖，再调用 dsh-app-boot 自身
# 的 healProfilesModuleFallback + loadProfile（userLayer:false 恢复诊断模式）
# 预检 dsh.profile.bundles 的每一个 bundle（含 in-box 包与共享回退目录）。
# 任何一项不可解析时用官方 `dsh plugin --profile web install` 修复并复检，
# 修复失败则按零报错门禁终止。
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
try { boot.loadProfile('dsh', profile, anchor, undefined, { userLayer: false }) }
catch (e) { console.error('[start] web profile bundles 预检失败: ' + e.message); process.exit(1) }
'@
function Test-WebProfileDeps {
  if (-not (Test-Path (Join-Path $webProfileDir 'package.json'))) { return $true }
  & node --input-type=module -e $profileCheckScript $PSScriptRoot 'web' $webProfileDir
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
    Write-Host '[start] 错误: web profile 依赖修复后仍存在不可解析项，终止启动。' -ForegroundColor Red
    exit 1
  }
  Write-Host '[start] web profile 依赖已修复。' -ForegroundColor Green
}

# --- 8. 可选 HMR Watcher (Dev Mode) -------------------------------------------
if ($Dev) {
  Write-Host '[start] 正在新窗口中启动 dev:web 监听器...' -ForegroundColor Cyan
  $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
  Start-Process $psExe -ArgumentList @(
    '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command',
    "Set-Location -LiteralPath '$PSScriptRoot'; pnpm run dev:web"
  )
}

# --- 9. 清理端口占用 (Free Web Port) ------------------------------------------
Clear-WebPort $Port

# --- 10. 启动 Web GUI (Launch) ------------------------------------------------
Write-Host "[start] 正在启动 DeepSeek Harness Web 服务: http://127.0.0.1:$Port/" -ForegroundColor Green
$env:DNO_COLOR = '1'

# 启用 V8 编译缓存 (Node 22+) 加速启动
$cacheDir = Join-Path $PSScriptRoot 'node_modules\.cache\node-compile-cache'
if (-not (Test-Path $cacheDir)) {
  New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction SilentlyContinue | Out-Null
}
$env:NODE_COMPILE_CACHE = $cacheDir

$cliBin = Join-Path $PSScriptRoot 'apps\cli\lib\bin.js'
if (Test-Path $cliBin) {
  node $cliBin web --port $Port
} else {
  pnpm dsh web --port $Port
}
