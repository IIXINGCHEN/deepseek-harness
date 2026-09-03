import { execSync } from 'node:child_process'
import { existsSync, copyFileSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { execPath } from 'node:process'

const root = resolve(import.meta.dirname, '..')
const outDir = join(root, 'dist-desktop')

/**
 * Windows corepack installs expose pnpm only as a .CMD shim, so the exe
 * builder's JS-entrypoint contract needs npm_execpath pointed at the
 * corepack pnpm.js beside this Node before it can invoke pnpm.
 */
function exeBuildEnv(): NodeJS.ProcessEnv {
  if (process.env.npm_execpath !== undefined && process.env.npm_execpath !== '') return process.env
  const corepackPnpm = join(dirname(execPath), 'node_modules', 'corepack', 'dist', 'pnpm.js')
  if (existsSync(corepackPnpm)) return { ...process.env, npm_execpath: corepackPnpm }
  return process.env
}

/** The pkg single-file runtime product this packaging consumes. */
const RUNTIME_EXE = join(root, 'dist-exe', 'deepseek-harness-sdk-runtime-win-x64.exe')
const RUNTIME_RG = `${RUNTIME_EXE.slice(0, -'.exe'.length)}-rg.exe`

console.log('========================================================')
console.log(' DeepSeek Harness Windows desktop packaging (codex-style)')
console.log(' Source:', root)
console.log('========================================================')

const skipPkg = process.argv.includes('--skip-pkg')
console.log('[1/4] Build/Update the pkg single-file runtime executable')
if (!skipPkg || !existsSync(RUNTIME_EXE) || !existsSync(RUNTIME_RG)) {
  console.log('  building latest pkg runtime via repository pkg pipeline')
  console.log('  command: node --import tsx/esm scripts/build-exe-for-python-sdk.ts --targets node24-win-x64 --skip-build')
  execSync(
    'node --import tsx/esm scripts/build-exe-for-python-sdk.ts --targets node24-win-x64 --skip-build',
    { stdio: 'inherit', cwd: root, env: exeBuildEnv() },
  )
  if (!existsSync(RUNTIME_EXE) || !existsSync(RUNTIME_RG)) {
    throw new Error(`package-windows-desktop: expected pkg products missing after build:\n  ${RUNTIME_EXE}\n  ${RUNTIME_RG}`)
  }
}
console.log('  runtime exe:', RUNTIME_EXE)

console.log('[2/4] Stage the release directory')
if (existsSync(outDir)) {
  rmSync(outDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
}
mkdirSync(outDir, { recursive: true })

// The single-file runtime and its ripgrep sidecar. The sidecar name must keep
// the `<exe-name>-rg.exe` convention tool-fs-search resolves beside the exe.
copyFileSync(RUNTIME_EXE, join(outDir, 'dsh-runtime.exe'))
copyFileSync(RUNTIME_RG, join(outDir, 'dsh-runtime-rg.exe'))

// WebView2 managed libraries for the WinForms host, plus the native loader.
const webviewNetLib = join(root, 'scripts', 'desktop-host', 'vendor', 'WebView2', 'lib', 'net462')
const webviewLoader = join(root, 'scripts', 'desktop-host', 'vendor', 'WebView2', 'runtimes', 'win-x64', 'native', 'WebView2Loader.dll')
for (const dll of ['Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll']) {
  copyFileSync(join(webviewNetLib, dll), join(outDir, dll))
}
copyFileSync(webviewLoader, join(outDir, 'WebView2Loader.dll'))

const iconPath = join(root, 'scripts', 'desktop-host', 'app.ico')
if (existsSync(iconPath)) {
  copyFileSync(iconPath, join(outDir, 'app.ico'))
}

console.log('[3/4] Compile the WinForms WebView2 desktop host')
const csc = 'C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe'
const cscArgs = [
  JSON.stringify(csc),
  '-target:winexe',
  '-optimize+',
  `-r:"${join(webviewNetLib, 'Microsoft.Web.WebView2.Core.dll')}"`,
  `-r:"${join(webviewNetLib, 'Microsoft.Web.WebView2.WinForms.dll')}"`,
]
if (existsSync(iconPath)) {
  cscArgs.push(`-win32icon:"${iconPath}"`)
}
cscArgs.push(`-out:"${join(outDir, 'DeepSeek-Harness.exe')}"`)
cscArgs.push(JSON.stringify(join(root, 'scripts', 'desktop-host', 'Program.cs')))
execSync(cscArgs.join(' '), { stdio: 'inherit' })
console.log('  host compiled:', join(outDir, 'DeepSeek-Harness.exe'))

writeFileSync(join(outDir, 'README.md'), [
  '# DeepSeek Harness for Windows (x86_64-pc-windows-msvc)',
  '',
  'A self-contained desktop build in the same release shape as a single-binary',
  'distribution: unzip anywhere and run `DeepSeek-Harness.exe`. No Node.js,',
  'pnpm, Python, or other prerequisites are installed or required.',
  '',
  '## Files',
  '',
  '- `DeepSeek-Harness.exe` — desktop window host (WinForms + WebView2)',
  '- `dsh-runtime.exe` — self-contained single-file runtime (embedded Node.js',
  '  and the full DeepSeek Harness program, including the web UI)',
  '- `dsh-runtime-rg.exe` — bundled ripgrep sidecar used by the runtime\'s',
  '  search (an internal tool; double-clicking it is not supported)',
  '- `Microsoft.Web.WebView2.*.dll`, `WebView2Loader.dll` — WebView2 host libraries',
  '',
  '## Usage',
  '',
  '1. Double-click `DeepSeek-Harness.exe` (binds the official port 3080).',
  '2. On first launch, enter your DeepSeek API key or another provider in Settings.',
  '',
  '## Data and privacy',
  '',
  'The install directory holds no user data. Settings and credentials live in',
  'your per-user DSH home (`%USERPROFILE%\\.dsh`, the same fixed location the',
  '`dsh` CLI uses) and browser profile data in',
  '`%LOCALAPPDATA%\\DeepSeek-Harness\\WebView2`. Copying, sharing, or',
  're-packaging this folder therefore cannot leak your API key or history.',
  '',
  'Uninstall: delete the unzipped folder; optionally also delete the two data',
  'directories above to remove all traces.',
].join('\n'), 'utf8')
writeFileSync(join(outDir, '使用说明.txt'), [
  'DeepSeek Harness Windows 桌面客户端（便携版）',
  '',
  '1. 双击 DeepSeek-Harness.exe 启动（使用官方端口 3080，请勿占用）。',
  '2. 首次打开后在界面 Settings 中填写 DeepSeek API Key 或其他 Provider 配置。',
  '3. 关闭窗口时后台服务一并退出，无残留进程。',
  '',
  '隐私说明：本目录不含任何用户数据。',
  '- 设置与 API Key 等凭证：%USERPROFILE%\\.dsh（与 dsh 命令行同一固定位置）',
  '- 浏览器缓存与 Cookie：%LOCALAPPDATA%\\DeepSeek-Harness\\WebView2',
  '- 因此拷贝、分发、重新打包本目录都不会泄露您的密钥与会话记录。',
  '',
  '卸载：删除解压目录即可；如需彻底清除痕迹，另删上述两个数据目录。',
  '',
  '文件说明：',
  '- DeepSeek-Harness.exe: 桌面窗口宿主',
  '- dsh-runtime.exe: 自包含单文件运行时（内嵌 Node.js 与全部程序）',
  '- dsh-runtime-rg.exe: 运行时内置搜索工具边车（内部工具，双击无界面属正常）',
].join('\r\n'), 'utf8')
writeFileSync(join(outDir, 'codex-package.json'), JSON.stringify({
  layoutVersion: 1,
  version: '0.1.2-alpha.2',
  target: 'x86_64-pc-windows-msvc',
  variant: 'deepseek-harness',
  entrypoint: 'DeepSeek-Harness.exe',
  resourcesDir: '.',
  pathDir: '.',
}, null, 2) + '\n', 'utf8')
writeFileSync(join(outDir, 'dsh-package.json'), JSON.stringify({
  layoutVersion: 1,
  version: '0.1.2-alpha.2',
  target: 'x86_64-pc-windows-msvc',
  variant: 'deepseek-harness',
  entrypoint: 'DeepSeek-Harness.exe',
  resourcesDir: '.',
  pathDir: '.',
}, null, 2) + '\n', 'utf8')
copyFileSync(join(root, 'LICENSE'), join(outDir, 'LICENSE'))

console.log('[4/4] Create ZIP release')
// codex-style per-target release asset name.
const zipName = 'DeepSeek-Harness-x86_64-pc-windows-msvc.zip'
const tempZip = join(root, 'tmp-release.zip')
rmSync(tempZip, { force: true, maxRetries: 5, retryDelay: 200 })
rmSync(join(outDir, zipName), { force: true, maxRetries: 5, retryDelay: 200 })
rmSync(join(root, zipName), { force: true, maxRetries: 5, retryDelay: 200 })
rmSync(join(root, 'DeepSeek-Harness-Windows-x64.zip'), { force: true, maxRetries: 5, retryDelay: 200 })

// Package contents of dist-desktop into temporary zip first to avoid recursive inclusion
// bsdtar treats `E:/...` as host:path; relative paths under cwd avoid the colon.
execSync('tar.exe -a -c -f tmp-release.zip -C dist-desktop .', { stdio: 'inherit', cwd: root })
copyFileSync(tempZip, join(outDir, zipName))
copyFileSync(tempZip, join(root, zipName))
rmSync(tempZip, { force: true, maxRetries: 5, retryDelay: 200 })

console.log('  release in dist-desktop:', join(outDir, zipName))
console.log('  release in root:', join(root, zipName))
console.log('Package complete.')
