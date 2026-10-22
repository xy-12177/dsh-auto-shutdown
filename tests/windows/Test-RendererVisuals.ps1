$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$rendererPath = Join-Path $PSScriptRoot '..\..\lib\windows\renderer.cs'
$assetRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\lib\windows')).Path
$artifactDir = Join-Path $PSScriptRoot 'artifacts'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$source = [IO.File]::ReadAllText((Resolve-Path $rendererPath).Path, [Text.Encoding]::UTF8)
$themePattern = '(?s)bool dark = false;\s*try \{\s*object v = Microsoft\.Win32\.Registry\.GetValue\(.*?\);\s*dark = v is int && \(int\)v == 0;\s*\} catch \{ \}'
$source = [regex]::Replace($source, $themePattern, 'bool dark = DshRendererVisualQaConfig.Dark;', 1)
$source = $source.Replace('using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { _k = g.DpiX / 96f; }', '_k = DshRendererVisualQaConfig.Scale;')
if ($source -match 'Registry\.GetValue|Graphics\.FromHwnd\(IntPtr.Zero\)') { throw 'The visual QA renderer did not replace live theme/DPI reads.' }
$source = $source.Replace('DshProgressForm', 'DshRendererVisualQaForm_Eval')
$source = $source.Replace('DshProgress', 'DshRendererVisualQaProgress_Eval')
$qaPrefix = @'
public static class DshRendererVisualQaConfig { public static bool Dark; public static float Scale; }
'@
$qaDriver = @'
public static class DshRendererVisualQaDriver {
    public static void Render(bool dark, float scale, string logo, string mascot, string output) {
        DshRendererVisualQaConfig.Dark = dark;
        DshRendererVisualQaConfig.Scale = scale;
        Exception failure = null;
        Thread thread = new Thread(delegate() {
            DshRendererVisualQaForm_Eval form = null;
            try {
                form = new DshRendererVisualQaForm_Eval("DeepSeek Harness", "正在关闭…", logo, mascot);
                IntPtr hwnd = form.Handle;
                if (form.ClientSize.Width != (int)Math.Round(760f * scale) ||
                    form.ClientSize.Height != (int)Math.Round(360f * scale))
                    throw new InvalidOperationException("Unexpected scaled form dimensions: " + form.ClientSize);
                Point[] points = new Point[] {
                    new Point(450, 200), new Point(560, 30), new Point(539, 324), new Point(603, 324),
                    new Point(5, 5), new Point(750, 5), new Point(750, 200), new Point(25, 339), new Point(570, 30)
                };
                bool[] expected = new bool[] { true, true, true, true, false, false, false, false, false };
                for (int i = 0; i < points.Length; i++) {
                    bool actual = form.Region.IsVisible((int)Math.Round(points[i].X * scale), (int)Math.Round(points[i].Y * scale));
                    if (actual != expected[i])
                        throw new InvalidOperationException("Region point " + points[i] + " expected " + expected[i] + " got " + actual + " at scale " + scale);
                }
                using (Bitmap bitmap = new Bitmap(form.ClientSize.Width, form.ClientSize.Height)) {
                    form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.ClientSize));
                    bitmap.Save(output, System.Drawing.Imaging.ImageFormat.Png);
                }
            } catch (Exception ex) {
                failure = ex;
            } finally {
                if (form != null) form.Dispose();
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure != null) throw new InvalidOperationException("Visual QA failed.", failure);
    }
}
'@
$source = $source.Replace('public class DshRendererVisualQaForm_Eval', $qaPrefix + 'public class DshRendererVisualQaForm_Eval')
$source = $source + [Environment]::NewLine + $qaDriver
Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll')
$logo = Join-Path $assetRoot 'deepseek-logo.png'
$mascot = Join-Path $assetRoot 'whale-maid-static.png'
foreach ($case in @(
    @{ Name = 'light-100'; Dark = $false; Scale = 1.0 },
    @{ Name = 'dark-100'; Dark = $true; Scale = 1.0 },
    @{ Name = 'light-150'; Dark = $false; Scale = 1.5 },
    @{ Name = 'dark-150'; Dark = $true; Scale = 1.5 }
)) {
    $output = Join-Path $artifactDir ('exit-window-' + $case.Name + '.png')
    [DshRendererVisualQaDriver]::Render($case.Dark, [single]$case.Scale, $logo, $mascot, $output)
    Write-Output ("PASS {0}: {1}" -f $case.Name, $output)
}
