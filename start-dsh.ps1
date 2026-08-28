# ==============================================================================
# DeepSeek Harness (DSH) 服务管理与一键安装启动脚本
# ==============================================================================
# 核心特性:
#   1. 依赖智能自检与多源自动安装 (支持 Git, Node.js ^22.19 || >=24, pnpm >=10)
#   2. 国内/国际高速镜像源智能测速与自动切换 (npmmirror, 腾讯云, 官方源)
#   3. 六阶段全链路启动前健康自检 (环境/工作区/依赖/构建产物/WebProfile/端口)
#   4. 服务生命周期管理 (启动/重启/停止/状态/交互式控制台/后台运行)
#   5. 本地网络代理智能检测与配置 (支持 Clash/Mihomo/v2rayN/SS 等本地代理)
#
# 使用方法:
#   powershell -ExecutionPolicy Bypass -File .\start-dsh.ps1 [Action] [Options]
#
# 常用命令示例:
#   .\start-dsh.ps1               # 默认前台自检并启动服务
#   .\start-dsh.ps1 start -b      # 后台静默启动服务
#   .\start-dsh.ps1 restart       # 重启服务
#   .\start-dsh.ps1 stop          # 停止服务
#   .\start-dsh.ps1 status        # 查看服务运行状态
#   .\start-dsh.ps1 menu          # 打开交互式服务管理控制台
#   .\start-dsh.ps1 check         # 仅执行全链路环境与项目自检 (不启动服务)
#   .\start-dsh.ps1 install-deps  # 仅执行依赖检测与自动安装
#
# 可选参数:
#   -Port <N>          指定 Web 服务端口 (默认 3080)
#   -Background (-b)   在后台启动服务 (不阻塞当前控制台)
#   -Proxy <url/port>  手动指定代理地址 (如: http://127.0.0.1:7890 或 7890)
#   -NoProxy           禁用代理检测与配置
#   -Registry <url>    手动指定 npm/pnpm 镜像源
#   -ChinaMirror       强制使用国内高速镜像源 (npmmirror / 淘宝)
#   -NoOpen            启动后不自动在默认浏览器中打开页面
#   -Dev               在独立窗口中启动 dev:web 客户端 HMR 监听器
#   -SkipUpdate        跳过检查官方仓库更新
#   -ForceBuild        强制重新执行 pnpm run build
#   -AutoInstall       检测到依赖缺失时无需确认直接自动安装 (默认开启)
# ==============================================================================

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
  [Parameter(Position = 0, ParameterSetName = 'Default')]
  [ValidateSet('start', 'restart', 'stop', 'status', 'menu', 'exit', 'quit', 'check', 'install-deps',
               '启动', '重启', '停止', '状态', '菜单', '退出', '自检', '安装依赖', IgnoreCase = $true)]
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

  [switch]$Check,

  [switch]$InstallDeps,

  [Alias('b')]
  [switch]$Background,

  [string]$Proxy,
  [switch]$NoProxy,
  [string]$Registry,
  [switch]$ChinaMirror,
  [switch]$NoOpen,
  [switch]$Dev,
  [ValidateRange(1, 65535)]
  [int]$Port = 3080,
  [switch]$SkipUpdate,
  [switch]$ForceBuild,
  [switch]$NoAutoInstall
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
$actionSwitchCount = @($Start, $Restart, $Stop, $Status, $Menu, $Exit, $Check, $InstallDeps | Where-Object { $_ }).Count
if ($actionSwitchCount -gt 1) {
  Write-Host '[start] 错误: 操作开关只能指定一个。' -ForegroundColor Red
  exit 1
}
if ($Stop)        { $Action = 'stop' }
if ($Restart)     { $Action = 'restart' }
if ($Start)       { $Action = 'start' }
if ($Status)      { $Action = 'status' }
if ($Menu)        { $Action = 'menu' }
if ($Exit)        { $Action = 'exit' }
if ($Check)       { $Action = 'check' }
if ($InstallDeps) { $Action = 'install-deps' }

# 标准化动作名称
switch ($Action.ToLower()) {
  '启动'     { $Action = 'start' }
  '重启'     { $Action = 'restart' }
  '停止'     { $Action = 'stop' }
  '状态'     { $Action = 'status' }
  '菜单'     { $Action = 'menu' }
  '退出'     { $Action = 'exit' }
  'quit'     { $Action = 'exit' }
  '自检'     { $Action = 'check' }
  '安装依赖' { $Action = 'install-deps' }
}

# --- 辅助函数: 刷新当前进程 PATH 环境变量 --------------------------------------
function Update-SessionEnvironmentPath {
  $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $processPath = [System.Environment]::GetEnvironmentVariable('Path', 'Process')
  $paths = @()
  if ($userPath)    { $paths += ($userPath -split ';') }
  if ($machinePath) { $paths += ($machinePath -split ';') }
  if ($processPath) { $paths += ($processPath -split ';') }
  $combined = $paths | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
  $env:PATH = $combined -join ';'
}

# --- 辅助函数: 校验 Node.js 版本是否符合 ^22.19 || >=24 -------------------------
function Test-NodeVersionConforms([string]$ver) {
  if (-not $ver) { return $false }
  $cleanVer = $ver.Trim().TrimStart('v')
  $parts = $cleanVer.Split('.')
  if ($parts.Count -lt 2) { return $false }
  $major = 0; $minor = 0
  if (-not [int]::TryParse($parts[0], [ref]$major)) { return $false }
  if (-not [int]::TryParse($parts[1], [ref]$minor)) { return $false }

  if ($major -ge 24) { return $true }
  if ($major -eq 22 -and $minor -ge 19) { return $true }
  return $false
}

# --- 辅助函数: 校验 pnpm 版本是否 >= 10.0.0 ------------------------------------
function Test-PnpmVersionConforms([string]$ver) {
  if (-not $ver) { return $false }
  $cleanVer = $ver.Trim().TrimStart('v')
  $parts = $cleanVer.Split('.')
  if ($parts.Count -lt 1) { return $false }
  $major = 0
  if (-not [int]::TryParse($parts[0], [ref]$major)) { return $false }
  return ($major -ge 10)
}

# --- 辅助函数: 镜像源优选与测速配置 --------------------------------------------
function Resolve-NpmRegistry {
  if ($Registry) {
    Write-Host "[deps] 使用用户指定的 npm 镜像源: $Registry" -ForegroundColor Cyan
    return $Registry
  }

  if ($ChinaMirror) {
    $chinaReg = 'https://registry.npmmirror.com'
    Write-Host "[deps] 已强制启用国内 npmmirror 镜像源: $chinaReg" -ForegroundColor Cyan
    return $chinaReg
  }

  # 默认若未配置代理，测速优选源
  if (-not $env:HTTP_PROXY -and -not $env:HTTPS_PROXY) {
    Write-Host '[deps] 正在检测网络环境与最佳 npm 镜像源...' -ForegroundColor Cyan
    $testUrls = @(
      @{ Name = 'npmmirror (国内加速)'; Url = 'https://registry.npmmirror.com' },
      @{ Name = '腾讯云 npm 镜像';     Url = 'https://mirrors.cloud.tencent.com/npm/' },
      @{ Name = 'npm 官方源';          Url = 'https://registry.npmjs.org' }
    )

    foreach ($item in $testUrls) {
      try {
        $req = [System.Net.WebRequest]::Create($item.Url)
        $req.Timeout = 2500
        $req.Method = 'HEAD'
        $resp = $req.GetResponse()
        $resp.Close()
        Write-Host "[deps] 选用最优源: $($item.Name) ($($item.Url))" -ForegroundColor Green
        return $item.Url
      } catch { }
    }
  }

  return 'https://registry.npmmirror.com'
}

# --- 依赖自动安装模块 1: 安装 Git ---------------------------------------------
function Install-GitPrerequisite {
  # 结果经 $script:PrereqInstallFailed 传递；安装器的命令输出会污染布尔返回值
  $script:PrereqInstallFailed = $false
  Write-Host '----------------------------------------------------' -ForegroundColor Yellow
  Write-Host '[deps] 正在自动安装 Git 环境...' -ForegroundColor Yellow
  Write-Host '----------------------------------------------------' -ForegroundColor Yellow

  # 1. 尝试 winget
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 正在通过 Windows Package Manager (winget) 安装 Git...' -ForegroundColor Cyan
    try {
      & winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements --silent
      Update-SessionEnvironmentPath
      if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host '[deps] Git 安装成功 (via winget)!' -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 2. 尝试 scoop
  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 正在通过 Scoop 安装 Git...' -ForegroundColor Cyan
    try {
      & scoop install git
      Update-SessionEnvironmentPath
      if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host '[deps] Git 安装成功 (via scoop)!' -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 3. 尝试 choco
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 正在通过 Chocolatey 安装 Git...' -ForegroundColor Cyan
    try {
      & choco install git -y --no-progress
      Update-SessionEnvironmentPath
      if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host '[deps] Git 安装成功 (via choco)!' -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 4. 下载独立安装包自动安装
  Write-Host '[deps] 正在从高速镜像下载 Git for Windows 安装包...' -ForegroundColor Cyan
  $gitInstallerUrl = 'https://registry.npmmirror.com/-/binary/git-for-windows/v2.48.1.windows.1/Git-2.48.1-64-bit.exe'
  $tempInstaller = Join-Path $env:TEMP 'Git-Installer-Auto.exe'
  try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($gitInstallerUrl, $tempInstaller)
    Write-Host '[deps] 正在静默安装 Git，请稍候...' -ForegroundColor Cyan
    $p = Start-Process -FilePath $tempInstaller -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-' -Wait -PassThru
    Update-SessionEnvironmentPath
    if (Get-Command git -ErrorAction SilentlyContinue) {
      Write-Host '[deps] Git 静默安装成功!' -ForegroundColor Green
      Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
      return
    }
  } catch {
    Write-Host "[deps] 自动下载安装 Git 失败: $($_.Exception.Message)" -ForegroundColor Red
  }

  Write-Host '[deps] 错误: 未能自动安装 Git，请访问 https://git-scm.com/ 手动安装。' -ForegroundColor Red
  $script:PrereqInstallFailed = $true
}

# --- 依赖自动安装模块 2: 安装 Node.js -----------------------------------------
function Install-NodePrerequisite {
  $script:PrereqInstallFailed = $false
  Write-Host '----------------------------------------------------' -ForegroundColor Yellow
  Write-Host '[deps] 正在自动安装/升级 Node.js (^22.19 || >=24)...' -ForegroundColor Yellow
  Write-Host '----------------------------------------------------' -ForegroundColor Yellow

  # 1. 尝试 fnm
  if (Get-Command fnm -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 检测到 Fast Node Manager (fnm)，正在安装 Node.js 22 LTS...' -ForegroundColor Cyan
    try {
      & fnm install 22
      & fnm use 22
      & fnm default 22
      Update-SessionEnvironmentPath
      $curVer = (node -v 2>$null)
      if (Test-NodeVersionConforms $curVer) {
        Write-Host "[deps] Node.js 安装成功 (via fnm): $curVer" -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 2. 尝试 nvm
  if (Get-Command nvm -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 检测到 NVM for Windows，正在安装 Node.js 22.19.0...' -ForegroundColor Cyan
    try {
      & nvm install 22.19.0
      & nvm use 22.19.0
      Update-SessionEnvironmentPath
      $curVer = (node -v 2>$null)
      if (Test-NodeVersionConforms $curVer) {
        Write-Host "[deps] Node.js 安装成功 (via nvm): $curVer" -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 3. 尝试 winget
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 正在通过 winget 安装 Node.js LTS...' -ForegroundColor Cyan
    try {
      & winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-source-agreements --accept-package-agreements --silent
      Update-SessionEnvironmentPath
      $curVer = (node -v 2>$null)
      if (Test-NodeVersionConforms $curVer) {
        Write-Host "[deps] Node.js 安装成功 (via winget): $curVer" -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 4. 尝试 scoop
  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 正在通过 Scoop 安装 Node.js LTS...' -ForegroundColor Cyan
    try {
      & scoop install nodejs-lts
      Update-SessionEnvironmentPath
      $curVer = (node -v 2>$null)
      if (Test-NodeVersionConforms $curVer) {
        Write-Host "[deps] Node.js 安装成功 (via scoop): $curVer" -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 5. 从 Node.js 镜像下载 MSI 静默安装
  Write-Host '[deps] 正在从镜像源下载 Node.js v22.19.0 x64 MSI 安装包...' -ForegroundColor Cyan
  $nodeMsiUrl = 'https://npmmirror.com/mirrors/node/v22.19.0/node-v22.19.0-x64.msi'
  $tempMsi = Join-Path $env:TEMP 'node-v22.19.0-x64-Auto.msi'
  try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($nodeMsiUrl, $tempMsi)
    Write-Host '[deps] 正在执行 Node.js 静默安装，请稍候...' -ForegroundColor Cyan
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$tempMsi`"", '/qn', '/norestart' -Wait -PassThru
    Update-SessionEnvironmentPath

    # 尝试将标准 Program Files Node 路径追加进 PATH
    $defaultNodePath = Join-Path $env:ProgramFiles 'nodejs'
    if (Test-Path $defaultNodePath) {
      if ($env:PATH -notmatch [regex]::Escape($defaultNodePath)) {
        $env:PATH = "$defaultNodePath;$env:PATH"
      }
    }

    $curVer = (node -v 2>$null)
    if (Test-NodeVersionConforms $curVer) {
      Write-Host "[deps] Node.js 静默安装成功: $curVer" -ForegroundColor Green
      Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
      return
    }
  } catch {
    Write-Host "[deps] 自动下载安装 Node.js 失败: $($_.Exception.Message)" -ForegroundColor Red
  }

  Write-Host '[deps] 错误: 未能自动安装 Node.js，请访问 https://nodejs.org/ 手动安装 ^22.19 || >=24。' -ForegroundColor Red
  $script:PrereqInstallFailed = $true
}

# --- 依赖自动安装模块 3: 安装 pnpm -------------------------------------------
function Install-PnpmPrerequisite([string]$TargetRegistry) {
  $script:PrereqInstallFailed = $false
  Write-Host '----------------------------------------------------' -ForegroundColor Yellow
  Write-Host '[deps] 正在自动安装/启用 pnpm (>=10.0.0)...' -ForegroundColor Yellow
  Write-Host '----------------------------------------------------' -ForegroundColor Yellow

  # 1. 尝试 corepack
  if (Get-Command corepack -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 正在通过 corepack 启用 pnpm...' -ForegroundColor Cyan
    try {
      & corepack enable
      & corepack prepare pnpm@latest --activate
      Update-SessionEnvironmentPath
      $curVer = (pnpm -v 2>$null)
      if (Test-PnpmVersionConforms $curVer) {
        Write-Host "[deps] pnpm 启用成功 (via corepack): v$curVer" -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 2. 尝试 npm 全局安装
  if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Host "[deps] 正在通过 npm 全局安装 pnpm (源: $TargetRegistry)..." -ForegroundColor Cyan
    try {
      & npm install -g pnpm@latest --registry=$TargetRegistry
      Update-SessionEnvironmentPath
      $curVer = (pnpm -v 2>$null)
      if (Test-PnpmVersionConforms $curVer) {
        Write-Host "[deps] pnpm 安装成功 (via npm): v$curVer" -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 3. 尝试 winget
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host '[deps] 正在通过 winget 安装 pnpm...' -ForegroundColor Cyan
    try {
      & winget install --id pnpm.pnpm -e --source winget --accept-source-agreements --accept-package-agreements --silent
      Update-SessionEnvironmentPath
      $curVer = (pnpm -v 2>$null)
      if (Test-PnpmVersionConforms $curVer) {
        Write-Host "[deps] pnpm 安装成功 (via winget): v$curVer" -ForegroundColor Green
        return
      }
    } catch { }
  }

  # 4. 尝试官方独立脚本安装
  Write-Host '[deps] 正在通过独立安装脚本安装 pnpm...' -ForegroundColor Cyan
  try {
    Invoke-RestMethod -Uri https://get.pnpm.io/install.ps1 -UseBasicParsing | Invoke-Expression
    Update-SessionEnvironmentPath
    $curVer = (pnpm -v 2>$null)
    if (Test-PnpmVersionConforms $curVer) {
      Write-Host "[deps] pnpm 独立脚本安装成功: v$curVer" -ForegroundColor Green
      return
    }
  } catch { }

  Write-Host '[deps] 错误: 未能自动安装 pnpm，请运行 npm install -g pnpm@latest 手动安装。' -ForegroundColor Red
  $script:PrereqInstallFailed = $true
}

# --- 核心模块: 全系统依赖检测与自愈 (Ensure Prerequisites) -----------------------
function Ensure-DshPrerequisites {
  # 结果经 $script:PrereqFailed 传递；安装器与版本探测的输出会污染布尔返回值
  $script:PrereqFailed = $false
  Write-Host '====================================================' -ForegroundColor Cyan
  Write-Host ' 阶段 1: 系统与运行依赖环境自动检测' -ForegroundColor Cyan
  Write-Host '====================================================' -ForegroundColor Cyan

  Update-SessionEnvironmentPath
  $selectedRegistry = Resolve-NpmRegistry

  # 1. 检测 Git
  $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
  if ($hasGit) {
    $gitVer = (git --version 2>$null)
    Write-Host "[check] Git 运行环境: " -NoNewline
    Write-Host "● 已就绪 ($gitVer)" -ForegroundColor Green
  } else {
    Write-Host "[check] Git 运行环境: " -NoNewline
    Write-Host "○ 未检测到" -ForegroundColor Yellow
    if ($NoAutoInstall) {
      Write-Host '[check] 错误: 缺少 Git 依赖且已指定 -NoAutoInstall，终止。' -ForegroundColor Red
      $script:PrereqFailed = $true
      return
    }
    Install-GitPrerequisite
    if ($script:PrereqInstallFailed) { $script:PrereqFailed = $true; return }
  }

  # 2. 检测 Node.js
  $hasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
  $nodeVer = if ($hasNode) { (node -v 2>$null) } else { $null }
  $nodeValid = Test-NodeVersionConforms $nodeVer

  if ($hasNode -and $nodeValid) {
    Write-Host "[check] Node.js 运行环境: " -NoNewline
    Write-Host "● 已就绪 ($nodeVer, 要求 ^22.19 || >=24)" -ForegroundColor Green
  } else {
    $reason = if (-not $hasNode) { "未检测到 Node.js" } else { "当前版本 $nodeVer 低于要求 (^22.19 || >=24)" }
    Write-Host "[check] Node.js 运行环境: " -NoNewline
    Write-Host "○ $reason" -ForegroundColor Yellow
    if ($NoAutoInstall) {
      Write-Host '[check] 错误: Node.js 不满足要求且已指定 -NoAutoInstall，终止。' -ForegroundColor Red
      $script:PrereqFailed = $true
      return
    }
    Install-NodePrerequisite
    if ($script:PrereqInstallFailed) { $script:PrereqFailed = $true; return }
  }

  # 3. 检测 pnpm
  $hasPnpm = [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
  $pnpmVer = if ($hasPnpm) { (pnpm -v 2>$null) } else { $null }
  $pnpmValid = Test-PnpmVersionConforms $pnpmVer

  if ($hasPnpm -and $pnpmValid) {
    Write-Host "[check] pnpm 包管理器: " -NoNewline
    Write-Host "● 已就绪 (v$pnpmVer, 要求 >=10.0.0)" -ForegroundColor Green
  } else {
    $reason = if (-not $hasPnpm) { "未检测到 pnpm" } else { "当前版本 v$pnpmVer 低于要求 (>=10.0.0)" }
    Write-Host "[check] pnpm 包管理器: " -NoNewline
    Write-Host "○ $reason" -ForegroundColor Yellow
    if ($NoAutoInstall) {
      Write-Host '[check] 错误: pnpm 不满足要求且已指定 -NoAutoInstall，终止。' -ForegroundColor Red
      $script:PrereqFailed = $true
      return
    }
    Install-PnpmPrerequisite -TargetRegistry $selectedRegistry
    if ($script:PrereqInstallFailed) { $script:PrereqFailed = $true; return }
  }

  Write-Host '[check] 系统前置运行环境自检通过！' -ForegroundColor Green
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

# --- 工具函数: 等待后台服务端口就绪 (慢启动不误杀) ------------------------------
# 返回 Ready (端口已监听) 与 ProcessAlive (进程是否仍在运行)；超时仅表示未就绪，
# 慢启动中的进程保持存活，是否终止由调用方决定。
function Wait-DshWebReady([System.Diagnostics.Process]$Proc, [int]$TargetPort, [int]$TimeoutSec = 120) {
  Write-Host "[start] 正在等待服务监听端口 $TargetPort 就绪..." -NoNewline
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $status = Get-DshServiceStatus $TargetPort
    if ($Proc.HasExited) { break }
    if ($status.IsRunning -and ($status.Pids -contains $Proc.Id)) {
      Write-Host ''
      return [PSCustomObject]@{ Ready = $true; ProcessAlive = $true }
    }
    Write-Host '.' -NoNewline
    Start-Sleep -Milliseconds 400
  }
  Write-Host ''
  return [PSCustomObject]@{ Ready = $false; ProcessAlive = (-not $Proc.HasExited) }
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

# --- 核心阶段 6: 全面自检引擎 (DSH Full Self-Check Pipeline) -------------------
function Invoke-DshSelfCheck([switch]$AutoFix, [switch]$PerformBuild) {
  # 结果经 $script:SelfCheckFailed 传递；pnpm/node 的裸输出会污染布尔返回值
  $script:SelfCheckFailed = $false
  Write-Host '====================================================' -ForegroundColor Cyan
  Write-Host ' DeepSeek Harness (DSH) 全链路健康自检' -ForegroundColor Cyan
  Write-Host '====================================================' -ForegroundColor Cyan

  $repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
  $dshHome = if ($env:DSH_HOME -and $env:DSH_HOME.Trim()) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

  # 1. 运行环境自检
  Write-Host '[自检 1/6] 检验运行环境与包管理器...' -ForegroundColor Cyan
  Ensure-DshPrerequisites
  if ($script:PrereqFailed) {
    Write-Host '[自检 1/6] ❌ 环境依赖自检失败！' -ForegroundColor Red
    $script:SelfCheckFailed = $true
    return
  }
  Write-Host '[自检 1/6] ✅ 运行环境自检正常。' -ForegroundColor Green

  # 2. 项目与工作区结构自检
  Write-Host '[自检 2/6] 检验项目结构与工作区配置...' -ForegroundColor Cyan
  $requiredFiles = @(
    (Join-Path $repoRoot 'package.json'),
    (Join-Path $repoRoot 'pnpm-workspace.yaml'),
    (Join-Path $repoRoot 'packages'),
    (Join-Path $repoRoot 'apps\cli'),
    (Join-Path $repoRoot 'apps\web')
  )
  foreach ($f in $requiredFiles) {
    if (-not (Test-Path $f)) {
      Write-Host "[自检 2/6] ❌ 缺少关键工作区路径: $f" -ForegroundColor Red
      $script:SelfCheckFailed = $true
      return
    }
  }
  Write-Host '[自检 2/6] ✅ 工作区结构完整。' -ForegroundColor Green

  # 3. 依赖完整性自检 (node_modules)
  Write-Host '[自检 3/6] 检验项目 node_modules 依赖...' -ForegroundColor Cyan
  $rootNodeModules = Join-Path $repoRoot 'node_modules'
  if (-not (Test-Path $rootNodeModules) -or $AutoFix) {
    Write-Host '[自检 3/6] 正在校验/安装项目依赖 (pnpm install)...' -ForegroundColor Cyan
    & pnpm install
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[自检 3/6] ❌ 依赖安装校验失败！' -ForegroundColor Red
      $script:SelfCheckFailed = $true
      return
    }
  }
  Write-Host '[自检 3/6] ✅ 项目依赖校验完整。' -ForegroundColor Green

  # 4. 构建产物与可执行文件自检
  Write-Host '[自检 4/6] 检验项目构建产物与 CLI 入口...' -ForegroundColor Cyan
  $webDist = Join-Path $repoRoot 'apps\web\dist'
  $cliDist = Join-Path $repoRoot 'apps\cli\lib\bin.js'
  $bootLib = Join-Path $repoRoot 'packages\boot\app-boot\lib\index.js'

  $missingArtifacts = (-not (Test-Path $webDist)) -or (-not (Test-Path $cliDist)) -or (-not (Test-Path $bootLib))
  if ($PerformBuild -or $missingArtifacts) {
    Write-Host '[自检 4/6] 正在构建项目产物 (pnpm run build)...' -ForegroundColor Cyan
    & pnpm run build
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[自检 4/6] ❌ 构建校验失败，存在错误！' -ForegroundColor Red
      $script:SelfCheckFailed = $true
      return
    }
    Write-Host '[自检 4/6] ✅ 构建成功，产物完整。' -ForegroundColor Green
  } else {
    Write-Host '[自检 4/6] ✅ 构建产物均已就绪。' -ForegroundColor Green
  }

  # 5. Web Profile 插件生态自检
  Write-Host '[自检 5/6] 检验 Web Profile 插件与配置...' -ForegroundColor Cyan
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
await boot.healProfilesModuleFallback({ installAnchor: anchor })
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

  if (Test-Path (Join-Path $webProfileDir 'package.json')) {
    & node --input-type=module -e $profileCheckScript $repoRoot 'web' $webProfileDir
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[自检 5/6] 正在自动修复 Web Profile 依赖...' -ForegroundColor Yellow
      if (Test-Path $cliDist) {
        & node $cliDist plugin --profile web install
      } else {
        & pnpm dsh plugin --profile web install
      }
      if ($LASTEXITCODE -ne 0) {
        Write-Host '[自检 5/6] ❌ Web Profile 依赖修复失败！' -ForegroundColor Red
        $script:SelfCheckFailed = $true
        return
      }
    }
  }
  Write-Host '[自检 5/6] ✅ Web Profile 插件环境健康。' -ForegroundColor Green

  # 6. 服务端口与实例占用自检
  Write-Host "[自检 6/6] 检验服务端口 $Port 状态..." -ForegroundColor Cyan
  [void](Stop-DshService -TargetPort $Port -Silent)
  $remainingPortOwners = @(Get-WebPortOwnerPids $Port)
  if ($remainingPortOwners.Count -gt 0) {
    Write-Host "[自检 6/6] ❌ 端口 $Port 正在被其他非 DSH 进程占用 (PID: $($remainingPortOwners -join ', '))！" -ForegroundColor Red
    $script:SelfCheckFailed = $true
    return
  }
  Write-Host "[自检 6/6] ✅ 端口 $Port 干净可用。" -ForegroundColor Green

  Write-Host '====================================================' -ForegroundColor Green
  Write-Host ' ✨ 全链路自检全部通过 (All Checks Passed)！' -ForegroundColor Green
  Write-Host '====================================================' -ForegroundColor Green
}

# --- 操作 3: 启动服务 (Start) --------------------------------------------------
function Start-DshService([switch]$RunInBackground) {
  # 失败路径只置标志并返回，由主入口决定退出码；menu 场景停留控制台展示错误
  $script:StartServiceFailed = $false

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

  # 2. 检查官方仓库更新并合并
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
          Write-Host "[start] 提示: 检查远端 ($targetRemote) 更新失败 (网络受限或离线)，跳过更新检测。" -ForegroundColor Yellow
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

          $aheadCountRaw = (git rev-list --count "$targetRemote/$currentBranch..HEAD" 2>$null)
          $aheadCount = if ($aheadCountRaw) { [int]$aheadCountRaw.Trim() } else { 0 }

          if ($behindCount -gt 0 -and $aheadCount -gt 0) {
            # 历史已分叉: 自动 rebase 会重写本地提交且大概率冲突, 只提示不自动操作
            Write-Host "[start] 检测到 $targetRemote/$currentBranch 有 $behindCount 个新提交，但本地另有 $aheadCount 个独立提交（历史已分叉）；已跳过自动更新，如需同步请手动执行: git pull --rebase $targetRemote $currentBranch" -ForegroundColor Yellow
          } elseif ($behindCount -gt 0) {
            Write-Host "[start] 检测到仓库 ($targetRemote) 有 $behindCount 个新提交，开始拉取并合并更新..." -ForegroundColor Green

            $status = (git status --porcelain 2>$null)
            $hasLocalChanges = [bool]($status -and $status.Trim().Length -gt 0)
            $stashed = $false

            if ($hasLocalChanges) {
              Write-Host '[start] 检测到本地存在修改，正在暂存本地改动...' -ForegroundColor Cyan
              git stash push -u -m "dsh-auto-stash-before-update" 2>&1 | Out-Null
              $stashed = $true
            }

            # --ff-only 仅快进合并, 不重写本地提交; 分叉/冲突时直接失败且不产生中间状态
            Write-Host "[start] 正在拉取远端 $targetRemote/$currentBranch 更新..." -ForegroundColor Cyan
            & git @gitProxyArgs pull --ff-only $targetRemote $currentBranch
            if ($LASTEXITCODE -ne 0) {
              Write-Host '[start] 错误: git pull --ff-only 更新失败（本地与远端无法快进合并）；请确认工作区状态后再启动。' -ForegroundColor Red
              if ($stashed) {
                Write-Host '[start] 正在恢复本地暂存的修改...' -ForegroundColor Cyan
                git stash pop 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                  Write-Host '[start] 本地暂存修改已恢复。' -ForegroundColor Green
                } else {
                  Write-Host '[start] 提示: 恢复本地修改失败，改动仍保留在 git stash 中。' -ForegroundColor Yellow
                }
              }
              $script:StartServiceFailed = $true
              return
            }

            if ($stashed) {
              Write-Host '[start] 正在恢复本地暂存的修改...' -ForegroundColor Cyan
              git stash pop 2>&1 | Out-Null
              if ($LASTEXITCODE -ne 0) {
                Write-Host '[start] 错误: 恢复本地修改时存在冲突，已停止启动；请先解决工作区冲突。' -ForegroundColor Red
                $script:StartServiceFailed = $true
                return
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

  # 3. 运行全链路健康自检
  Invoke-DshSelfCheck -AutoFix -PerformBuild:$needsBuild
  if ($script:SelfCheckFailed) {
    Write-Host '[start] 启动终止: 项目自检未通过，请根据上方提示修复后再启动。' -ForegroundColor Red
    $script:StartServiceFailed = $true
    return
  }

  # 4. 可选 HMR Watcher (Dev Mode)
  $repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
  $dshHome = if ($env:DSH_HOME -and $env:DSH_HOME.Trim()) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

  if ($Dev) {
    Write-Host '[start] 正在新窗口中启动 dev:web 监听器...' -ForegroundColor Cyan
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    Start-Process $psExe -ArgumentList @(
      '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command',
      "Set-Location -LiteralPath '$repoRoot'; pnpm run dev:web"
    )
  }

  # 5. 启动 Web GUI 服务
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

    # 等待服务端口就绪 (慢启动仅告警，不终止进程)
    $readyWaitSec = 120
    $ready = Wait-DshWebReady -Proc $proc -TargetPort $Port -TimeoutSec $readyWaitSec
    if ($ready.Ready) {
      $status = Get-DshServiceStatus $Port
      Write-Host "[start] DeepSeek Harness Web 服务已在后台成功启动!" -ForegroundColor Green
      Write-Host "[start] 监听端口: $Port | 进程 PID: $($status.Pids -join ', ')" -ForegroundColor Cyan
      Write-Host "[start] 访问地址: http://127.0.0.1:$Port/" -ForegroundColor Green
      Write-Host "[start] 运行日志: $stdoutLog" -ForegroundColor DarkGray

      if (-not $NoOpen) {
        try { Start-Process "http://127.0.0.1:$Port/" } catch { }
      }
    } elseif ($ready.ProcessAlive) {
      Write-Host "[start] 警告: 服务未在 $readyWaitSec 秒内完成端口监听，进程仍在启动中，已保留 (PID $($proc.Id))；请稍后执行 status 查看或访问 http://127.0.0.1:$Port/ 确认，日志: $stderrLog" -ForegroundColor Yellow
      $script:StartServiceFailed = $true
      return
    } else {
      Write-Host "[start] 错误: 后台进程已提前退出 (exit $($proc.ExitCode))，请检查日志: $stderrLog" -ForegroundColor Red
      $script:StartServiceFailed = $true
      return
    }
  } else {
    # 前台交互运行模式
    Write-Host "[start] 正在前台启动 DeepSeek Harness Web 服务: http://127.0.0.1:$Port/" -ForegroundColor Green
    if (Test-Path $cliBin) {
      & node $cliBin @appArgs
    } else {
      & pnpm dsh @appArgs
    }
    if ($LASTEXITCODE -ne 0) { $script:StartServiceFailed = $true }
  }
}

# --- 操作 4: 重启服务 (Restart) ------------------------------------------------
function Restart-DshService([switch]$RunInBackground) {
  Write-Host "====================================================" -ForegroundColor Cyan
  Write-Host " 正在重启 DeepSeek Harness (DSH) Web 服务..." -ForegroundColor Cyan
  Write-Host "====================================================" -ForegroundColor Cyan

  if (-not (Stop-DshService -TargetPort $Port)) {
    $script:StartServiceFailed = $true
    return
  }
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
    Write-Host ' 6. 执行全链路健康自检 (Self-Check)' -ForegroundColor White
    Write-Host ' 7. 检测并安装系统前置依赖 (Install Prerequisites)' -ForegroundColor White
    Write-Host ' 0. 退出控制台 (Exit)' -ForegroundColor White
    Write-Host '====================================================' -ForegroundColor Cyan

    $choice = Read-Host '请输入选项编号 [0-7]'
    Write-Host ''

    switch ($choice.Trim()) {
      '1' {
        Start-DshService -RunInBackground
        Write-Host ''
        Read-Host '按回车键返回菜单...'
      }
      '2' {
        Start-DshService
        if ($script:StartServiceFailed) {
          Write-Host ''
          Read-Host '按回车键返回菜单...'
        } else {
          return
        }
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
      '6' {
        Invoke-DshSelfCheck
        Write-Host ''
        Read-Host '按回车键返回菜单...'
      }
      '7' {
        Ensure-DshPrerequisites
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
        Write-Host '无效的输入，请输入 0-7 之间的数字。' -ForegroundColor Red
        Start-Sleep -Seconds 1
      }
    }
  }
}

# --- 主执行入口 (Main Dispatcher) ---------------------------------------------
switch ($Action) {
  'start'        {
    Start-DshService -RunInBackground:$Background
    if ($script:StartServiceFailed) { exit 1 }
  }
  'restart'      {
    Restart-DshService -RunInBackground:$Background
    if ($script:StartServiceFailed) { exit 1 }
  }
  'stop'         { if (-not (Stop-DshService -TargetPort $Port)) { exit 1 } }
  'status'       { Show-DshStatus -TargetPort $Port }
  'check'        {
    Invoke-DshSelfCheck
    if ($script:SelfCheckFailed) { exit 1 }
  }
  'install-deps' {
    Ensure-DshPrerequisites
    if ($script:PrereqFailed) { exit 1 }
  }
  'menu'         { Show-InteractiveMenu }
  'exit'         {
    Write-Host '已退出。' -ForegroundColor Gray
    exit 0
  }
  default        {
    Write-Host "未知操作: '$Action'。支持的操作: start, restart, stop, status, check, install-deps, menu, exit。" -ForegroundColor Red
    exit 1
  }
}