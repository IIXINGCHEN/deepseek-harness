using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DeepSeekHarness.Desktop
{
    internal sealed class DesktopForm : Form
    {
        private readonly string targetUrl;
        private readonly string dataFolder;
        private WebView2 webView;

        public DesktopForm(string targetUrl, string dataFolder)
        {
            this.targetUrl = targetUrl;
            this.dataFolder = dataFolder;
            Text = "DeepSeek Harness";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new System.Drawing.Size(1000, 680);
            Size = new System.Drawing.Size(1440, 920);
            Icon = TryLoadIcon();
            ShowInTaskbar = true;
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            InitializeWebView();
        }

        private async void InitializeWebView()
        {
            Directory.CreateDirectory(dataFolder);
            webView = new WebView2
            {
                Dock = DockStyle.Fill
            };
            Controls.Add(webView);
            var environment = await CoreWebView2Environment.CreateAsync(null, dataFolder, null);
            await webView.EnsureCoreWebView2Async(environment);
            webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            webView.CoreWebView2.Settings.IsZoomControlEnabled = false;
            webView.CoreWebView2.Settings.AreBrowserAcceleratorKeysEnabled = true;
            webView.CoreWebView2.DocumentTitleChanged += (sender, args) =>
            {
                var title = webView.CoreWebView2.DocumentTitle;
                Text = string.IsNullOrWhiteSpace(title) ? "DeepSeek Harness" : title;
            };
            webView.CoreWebView2.NewWindowRequested += (sender, args) =>
            {
                args.Handled = true;
                // Only http(s) may reach the OS shell; any other scheme stays
                // in-app so page content cannot invoke arbitrary protocol
                // handlers or executables through this host.
                if (args.Uri == null) return;
                bool isWebScheme = args.Uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                    || args.Uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
                if (!isWebScheme) return;
                try
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = args.Uri,
                        UseShellExecute = true
                    });
                }
                catch
                {
                }
            };
            webView.CoreWebView2.Navigate(targetUrl);
        }

        private static string JsonString(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        private static Icon TryLoadIcon()
        {
            var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app.ico");
            return File.Exists(path) ? new Icon(path) : null;
        }

    }

    static class Program
    {
        /// <summary>Official desktop port; the backend always binds this one.</summary>
        const int OfficialPort = 3080;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        const int JobObjectExtendedLimitInformation = 9;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryLimit;
            public UIntPtr PeakJobMemoryLimit;
        }

        static IntPtr _jobHandle;
        static Process _nodeProcess;

        static void EnableAutoKillOnClose()
        {
            _jobHandle = CreateJobObject(IntPtr.Zero, null);
            if (_jobHandle != IntPtr.Zero)
            {
                var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr extendedInfoPtr = Marshal.AllocHGlobal(length);
                try
                {
                    Marshal.StructureToPtr(info, extendedInfoPtr, false);
                    SetInformationJobObject(_jobHandle, JobObjectExtendedLimitInformation, extendedInfoPtr, (uint)length);
                }
                finally
                {
                    Marshal.FreeHGlobal(extendedInfoPtr);
                }
            }
        }

        static void BindToJob(Process process)
        {
            if (_jobHandle != IntPtr.Zero && process != null && !process.HasExited)
            {
                AssignProcessToJobObject(_jobHandle, process.Handle);
            }
        }

        static void StopBackend()
        {
            try
            {
                if (_nodeProcess != null && !_nodeProcess.HasExited)
                {
                    _nodeProcess.Kill();
                }
            }
            catch
            {
            }
        }

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;

            // Codex-style release: one self-contained runtime exe beside the
            // host, plus its ripgrep sidecar. The dev fallback keeps the host
            // runnable from a source checkout with a built tree.
            string[] backendCandidates = new string[]
            {
                Path.Combine(baseDir, "dsh-runtime.exe"),
                Path.Combine(baseDir, "bin", "dsh-runtime.exe"),
                Path.Combine(baseDir, "runtime", "deepseek-harness-sdk-runtime-win-x64.exe")
            };
            string backendExe = null;
            foreach (var candidate in backendCandidates)
            {
                if (File.Exists(candidate))
                {
                    backendExe = candidate;
                    break;
                }
            }

            string nodeExe = Path.Combine(baseDir, "runtime", "node.exe");
            string[] entryCandidates = new string[]
            {
                Path.Combine(baseDir, "app", "apps", "cli", "lib", "bin.js"),
                Path.Combine(baseDir, "apps", "cli", "lib", "bin.js")
            };
            string entryScript = null;
            foreach (var candidate in entryCandidates)
            {
                if (File.Exists(candidate))
                {
                    entryScript = candidate;
                    break;
                }
            }

            if (backendExe == null && (entryScript == null || !File.Exists(nodeExe)))
            {
                MessageBox.Show(
                    "Cannot locate the DeepSeek Harness runtime.\nTried:\n - "
                    + string.Join("\n - ", backendCandidates)
                    + "\n - " + nodeExe + " + " + (entryScript ?? "apps/cli/lib/bin.js"),
                    "DeepSeek Harness",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            // The official port is part of the product contract; refuse to
            // start on a random port when 3080 is taken.
            try
            {
                var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, OfficialPort);
                probe.Start();
                probe.Stop();
            }
            catch
            {
                MessageBox.Show(
                    "官方端口 3080 已被占用，DeepSeek Harness 无法启动。\n请关闭占用该端口的程序后重试。",
                    "DeepSeek Harness",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            EnableAutoKillOnClose();

            string portArg = OfficialPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
            string targetUrl = "http://127.0.0.1:" + portArg;
            string workingDir = baseDir;
            if (File.Exists(Path.Combine(baseDir, "app", "package.json")))
            {
                workingDir = Path.Combine(baseDir, "app");
            }

            var startInfo = new ProcessStartInfo
            {
                WorkingDirectory = workingDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            if (backendExe != null)
            {
                startInfo.FileName = backendExe;
                startInfo.Arguments = "web --port " + portArg + " --no-open";
            }
            else
            {
                startInfo.FileName = nodeExe;
                startInfo.Arguments = "\"" + entryScript + "\" web --port " + portArg + " --no-open";
            }
            startInfo.EnvironmentVariables["NODE_ENV"] = "production";
            startInfo.EnvironmentVariables["DSH_DESKTOP"] = "1";
            // User data never lives beside the executable. The desktop build
            // owns a fixed per-user home beside the CLI's (%USERPROFILE%\.dsh-desktop,
            // the codex-style ~/.codex pattern): settings and credentials stay
            // there, so a copied or re-packaged install directory cannot leak
            // them. It is deliberately separate from the CLI's ~/.dsh profile:
            // that profile's out-of-tree plugins cannot resolve their imports
            // inside the packaged runtime yet, and a fresh home keeps the
            // packaged boot clean.
            string envDshHome = Environment.GetEnvironmentVariable("DSH_HOME");
            string dshHome = !string.IsNullOrWhiteSpace(envDshHome)
                ? envDshHome
                : Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".dsh-desktop");
            startInfo.EnvironmentVariables["DSH_HOME"] = dshHome;
            var dataFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DeepSeek-Harness",
                "WebView2");

            string authenticatedUrl = null;
            var readyEvent = new ManualResetEvent(false);
            var stderrBuilder = new System.Text.StringBuilder();

            try
            {
                _nodeProcess = Process.Start(startInfo);
                BindToJob(_nodeProcess);

                _nodeProcess.OutputDataReceived += (sender, args) =>
                {
                    if (string.IsNullOrEmpty(args.Data)) return;
                    if (args.Data.Contains("dsh web: http"))
                    {
                        int index = args.Data.IndexOf("http");
                        if (index >= 0)
                        {
                            string urlPart = args.Data.Substring(index).Trim();
                            int spaceIndex = urlPart.IndexOf(' ');
                            authenticatedUrl = spaceIndex > 0 ? urlPart.Substring(0, spaceIndex) : urlPart;
                            readyEvent.Set();
                        }
                    }
                };
                _nodeProcess.ErrorDataReceived += (sender, args) =>
                {
                    if (!string.IsNullOrEmpty(args.Data))
                    {
                        lock (stderrBuilder)
                        {
                            stderrBuilder.AppendLine(args.Data);
                        }
                    }
                };
                _nodeProcess.BeginOutputReadLine();
                _nodeProcess.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                MessageBox.Show("Failed to launch DSH backend: " + ex.Message, "DeepSeek Harness", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            bool isReady = readyEvent.WaitOne(25000);

            if (_nodeProcess.HasExited)
            {
                string errorDetail = "";
                lock (stderrBuilder)
                {
                    errorDetail = stderrBuilder.ToString();
                }
                MessageBox.Show(
                    "DeepSeek Harness backend stopped unexpectedly.\n\n" + (string.IsNullOrWhiteSpace(errorDetail) ? "Exit code: " + _nodeProcess.ExitCode : errorDetail),
                    "DeepSeek Harness",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            if (!string.IsNullOrEmpty(authenticatedUrl))
            {
                targetUrl = authenticatedUrl;
            }

            Application.Run(new DesktopForm(targetUrl, dataFolder));
            StopBackend();
        }
    }
}