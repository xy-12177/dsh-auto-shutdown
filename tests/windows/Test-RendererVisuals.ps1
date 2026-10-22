$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$rendererPath = Join-Path $PSScriptRoot '..\..\lib\windows\renderer.cs'
$assetRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\lib\windows')).Path
$artifactDir = Join-Path $PSScriptRoot 'artifacts'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$source = [IO.File]::ReadAllText((Resolve-Path $rendererPath).Path, [Text.Encoding]::UTF8)
$themePattern = '(?s)object theme = null;\s*try \{ theme = Microsoft\.Win32\.Registry\.GetValue\(.*?\); \} catch \{ \}'
$source = [regex]::Replace($source, $themePattern, 'object theme = DshRendererVisualQaConfig.Dark ? (object)0 : (object)1;', 1)
$source = $source.Replace('using (Graphics screen = Graphics.FromHwnd(IntPtr.Zero)) { _scale = screen.DpiX / 96f; }', 'using (Graphics screen = Graphics.FromHwnd(IntPtr.Zero)) { _scale = DshRendererVisualQaConfig.Scale; }')
if ($source -match 'Registry\.GetValue|Graphics.FromHwnd\(IntPtr.Zero\).*DpiX') { throw 'The visual QA renderer did not replace live theme/DPI reads.' }
$source = $source.Replace('DshProgressForm', 'DshRendererVisualQaForm_Eval')
$source = $source.Replace('DshProgress', 'DshRendererVisualQaProgress_Eval')
$qaPrefix = @'
public static class DshRendererVisualQaConfig { public static bool Dark; public static float Scale; }
'@
$qaDriver = @'
public static class DshRendererVisualQaDriver {
    public static void Render(bool dark, float scale, string mascot, string output, float angle) {
        DshRendererVisualQaConfig.Dark = dark;
        DshRendererVisualQaConfig.Scale = scale;
        Exception failure = null;
        Thread thread = new Thread(delegate() {
            DshRendererVisualQaForm_Eval form = null;
            try {
                form = new DshRendererVisualQaForm_Eval("DeepSeek Harness", "再见", "", mascot);
                if (form.ClientSize.Width != (int)Math.Round(420f * scale) ||
                    form.ClientSize.Height != (int)Math.Round(370f * scale))
                    throw new InvalidOperationException("Unexpected scaled form dimensions: " + form.ClientSize);
                form.ExportFrameForTesting(output, angle);
                using (Bitmap bitmap = new Bitmap(output)) {
                    if (bitmap.GetPixel(0, 0).A != 0 || bitmap.GetPixel(bitmap.Width-1, bitmap.Height-1).A != 0)
                        throw new InvalidOperationException("Window corners must remain fully transparent.");
                    int opaqueMascot = 0, bubbleInk = 0;
                    Rectangle mascotBounds = new Rectangle((int)(145*scale), (int)(140*scale), (int)(270*scale), (int)(220*scale));
                    Rectangle bubble = new Rectangle((int)(22*scale), (int)(32*scale), (int)(140*scale), (int)(65*scale));
                    for (int y=mascotBounds.Top; y<Math.Min(bitmap.Height,mascotBounds.Bottom); y+=2)
                        for (int x=mascotBounds.Left; x<Math.Min(bitmap.Width,mascotBounds.Right); x+=2)
                            if (bitmap.GetPixel(x,y).A > 220) opaqueMascot++;
                    for (int y=bubble.Top; y<Math.Min(bitmap.Height,bubble.Bottom); y+=1)
                        for (int x=bubble.Left; x<Math.Min(bitmap.Width,bubble.Right); x+=1) {
                            Color c = bitmap.GetPixel(x,y);
                            if (c.A > 220 && c.B > c.R + 12 && c.B > c.G + 3) bubbleInk++;
                        }
                    if (opaqueMascot < 300) throw new InvalidOperationException("Mascot is missing or cropped.");
                    if (bubbleInk < 20) throw new InvalidOperationException("The goodbye bubble text was not rendered.");
                }
            } catch (Exception ex) { failure = ex; }
            finally { if (form != null) form.Dispose(); }
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
        if (failure != null) throw new InvalidOperationException("Visual QA failed.", failure);
    }
    public static void CompareWaveFrames(string first, string second, float scale) {
        using (Bitmap a = new Bitmap(first)) using (Bitmap b = new Bitmap(second)) {
            int changed = 0;
            Rectangle hand = new Rectangle((int)(160*scale), (int)(155*scale), (int)(65*scale), (int)(72*scale));
            for (int y=hand.Top; y<Math.Min(a.Height,hand.Bottom); y++) for (int x=hand.Left; x<Math.Min(a.Width,hand.Right); x++) {
                Color p=a.GetPixel(x,y), q=b.GetPixel(x,y);
                if (Math.Abs(p.A-q.A)+Math.Abs(p.R-q.R)+Math.Abs(p.G-q.G)+Math.Abs(p.B-q.B) > 70) changed++;
            }
            if (changed < 60) throw new InvalidOperationException("Wave hand did not visibly change position (changed pixels=" + changed + ").");
        }
    }
}
'@
$source = $source.Replace('public sealed class DshRendererVisualQaForm_Eval', $qaPrefix + 'public sealed class DshRendererVisualQaForm_Eval')
$source = $source + [Environment]::NewLine + $qaDriver
Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll')
$mascot = Join-Path $assetRoot 'whale-maid-goodbye.png'
foreach ($case in @(
    @{ Name = 'light-100'; Dark = $false; Scale = 1.0 },
    @{ Name = 'dark-100'; Dark = $true; Scale = 1.0 },
    @{ Name = 'light-150'; Dark = $false; Scale = 1.5 },
    @{ Name = 'dark-150'; Dark = $true; Scale = 1.5 }
)) {
    $left = Join-Path $artifactDir ('goodbye-' + $case.Name + '.png')
    $right = Join-Path $artifactDir ('goodbye-' + $case.Name + '-wave.png')
    [DshRendererVisualQaDriver]::Render($case.Dark, [single]$case.Scale, $mascot, $left, -16)
    [DshRendererVisualQaDriver]::Render($case.Dark, [single]$case.Scale, $mascot, $right, 16)
    [DshRendererVisualQaDriver]::CompareWaveFrames($left, $right, [single]$case.Scale)
    Write-Output ("PASS {0}: transparent canvas, goodbye bubble, mascot bounds, and visible hand wave" -f $case.Name)
}
Copy-Item -LiteralPath (Join-Path $artifactDir 'goodbye-light-100.png') -Destination (Join-Path $artifactDir 'exit-window-wave-left.png') -Force
Copy-Item -LiteralPath (Join-Path $artifactDir 'goodbye-light-100-wave.png') -Destination (Join-Path $artifactDir 'exit-window-wave-right.png') -Force

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
public static class DshGoodbyeGifExporter {
    private sealed class BitWriter {
        private readonly List<byte> bytes = new List<byte>(); private int pending, bitCount;
        public void Write(int code, int width) {
            pending |= code << bitCount; bitCount += width;
            while (bitCount >= 8) { bytes.Add((byte)(pending & 255)); pending >>= 8; bitCount -= 8; }
        }
        public byte[] Finish() { if (bitCount > 0) bytes.Add((byte)(pending & 255)); return bytes.ToArray(); }
    }
    private static byte[] Compress(byte[] pixels) {
        // Literal-only LZW with a conservative clear cadence. The decoder's
        // dictionary never reaches 512 entries, so every code remains 9 bits.
        const int clear = 256, end = 257, codeWidth = 9, literalsPerDictionary = 200;
        BitWriter writer = new BitWriter(); writer.Write(clear, codeWidth);
        int sinceClear = 0;
        for (int i=0;i<pixels.Length;i++) {
            if (sinceClear == literalsPerDictionary) { writer.Write(clear, codeWidth); sinceClear = 0; }
            writer.Write(pixels[i], codeWidth); sinceClear++;
        }
        writer.Write(end, codeWidth); return writer.Finish();
    }
    private static void WriteBlocks(BinaryWriter writer, byte[] bytes) {
        int offset=0; while (offset<bytes.Length) { int count=Math.Min(255,bytes.Length-offset); writer.Write((byte)count); writer.Write(bytes,offset,count); offset+=count; } writer.Write((byte)0);
    }
    private static byte[] ReadIndices(string path, int expectedWidth, int expectedHeight) {
        using (Bitmap bitmap = new Bitmap(path)) {
            if (bitmap.Width != expectedWidth || bitmap.Height != expectedHeight) throw new InvalidOperationException("GIF frame dimensions differ.");
            BitmapData data = bitmap.LockBits(new Rectangle(0,0,bitmap.Width,bitmap.Height),ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
            try {
                byte[] pixels = new byte[bitmap.Width*bitmap.Height]; byte[] row = new byte[bitmap.Width*4];
                for (int y=0;y<bitmap.Height;y++) {
                    Marshal.Copy(IntPtr.Add(data.Scan0,y*data.Stride),row,0,row.Length);
                    for (int x=0;x<bitmap.Width;x++) {
                        int p=x*4, b=row[p], g=row[p+1], r=row[p+2], a=row[p+3];
                        if (a < 100) pixels[y*bitmap.Width+x]=0;
                        else { int index=1 | ((r>>5)<<5) | ((g>>5)<<2) | (b>>6); pixels[y*bitmap.Width+x]=(byte)index; }
                    }
                }
                return pixels;
            } finally { bitmap.UnlockBits(data); }
        }
    }
    public static void Compose(string[] framePaths, string output) {
        if (framePaths == null || framePaths.Length < 2) throw new ArgumentException("At least two frames are required.");
        using (Bitmap dimensions = new Bitmap(framePaths[0])) using (BinaryWriter writer = new BinaryWriter(File.Create(output))) {
            int width=dimensions.Width,height=dimensions.Height;
            writer.Write(new byte[] { (byte)'G',(byte)'I',(byte)'F',(byte)'8',(byte)'9',(byte)'a' });
            writer.Write((ushort)width); writer.Write((ushort)height); writer.Write((byte)0xF7); writer.Write((byte)0); writer.Write((byte)0);
            for (int i=0;i<256;i++) {
                if (i==0) { writer.Write((byte)0); writer.Write((byte)0); writer.Write((byte)0); }
                else { writer.Write((byte)(((i>>5)&7)*255/7)); writer.Write((byte)(((i>>2)&7)*255/7)); writer.Write((byte)((i&3)*255/3)); }
            }
            writer.Write(new byte[] { 0x21,0xFF,0x0B }); writer.Write(System.Text.Encoding.ASCII.GetBytes("NETSCAPE2.0")); writer.Write(new byte[] { 3,1,0,0,0 });
            foreach (string path in framePaths) {
                byte[] pixels=ReadIndices(path,width,height), compressed=Compress(pixels);
                writer.Write(new byte[] { 0x21,0xF9,4,9,8,0,0,0 }); // transparency, disposal=background, 80ms
                writer.Write((byte)0x2C); writer.Write((ushort)0); writer.Write((ushort)0); writer.Write((ushort)width); writer.Write((ushort)height); writer.Write((byte)0);
                writer.Write((byte)8); WriteBlocks(writer,compressed);
            }
            writer.Write((byte)0x3B);
        }
        using (Image check = Image.FromFile(output)) {
            if (check.GetFrameCount(FrameDimension.Time) != framePaths.Length) throw new InvalidOperationException("Animated preview frame count is incorrect.");
            for (int frame=0;frame<framePaths.Length;frame++) {
                check.SelectActiveFrame(FrameDimension.Time, frame);
                using (Bitmap decoded = new Bitmap(check)) {
                    long checksum=0;
                    for (int y=0;y<decoded.Height;y++) for (int x=0;x<decoded.Width;x++) {
                        Color pixel=decoded.GetPixel(x,y); checksum += pixel.A + pixel.R + pixel.G + pixel.B;
                    }
                    if (checksum == 0) throw new InvalidOperationException("Decoded GIF frame is empty: " + frame);
                }
            }
        }
    }
}
'@ -ReferencedAssemblies @('System.Drawing.dll')

$animationDir = Join-Path $artifactDir 'gif-frames'
New-Item -ItemType Directory -Path $animationDir -Force | Out-Null
try {
    $frames = @()
    for ($i = 0; $i -lt 12; $i++) {
        $angle = [single](16 * [Math]::Sin(2 * [Math]::PI * $i / 12))
        $framePath = Join-Path $animationDir ('frame-{0:D2}.png' -f $i)
        [DshRendererVisualQaDriver]::Render($false, [single]1.0, $mascot, $framePath, $angle)
        $frames += $framePath
    }
    $gifPath = Join-Path $artifactDir 'goodbye-animation.gif'
    [DshGoodbyeGifExporter]::Compose($frames, $gifPath)
    Write-Output ("PASS animated preview: {0}" -f $gifPath)
} finally {
    $resolvedFrames = (Resolve-Path -LiteralPath $animationDir).Path
    $resolvedArtifacts = (Resolve-Path -LiteralPath $artifactDir).Path.TrimEnd('\')
    if ($resolvedFrames.StartsWith($resolvedArtifacts + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedFrames -Recurse -Force
    } else { throw "Refusing to remove animation frames outside artifacts: $resolvedFrames" }
}
