using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

// Small per-pixel-alpha desktop greeting. The mascot is split at runtime into
// a static body and a masked hand/cuff layer; only that layer rotates.
public sealed class DshProgressForm : Form {
    [StructLayout(LayoutKind.Sequential)] private struct BlendFunction {
        public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat;
    }
    [StructLayout(LayoutKind.Sequential)] private struct PointNative { public int X, Y; public PointNative(int x, int y) { X=x; Y=y; } }
    [StructLayout(LayoutKind.Sequential)] private struct SizeNative { public int Width, Height; public SizeNative(int w, int h) { Width=w; Height=h; } }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfoHeader {
        public uint Size; public int Width, Height; public ushort Planes, BitCount; public uint Compression, SizeImage;
        public int XPelsPerMeter, YPelsPerMeter; public uint ClrUsed, ClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfo { public BitmapInfoHeader Header; public uint Colors; }

    [DllImport("user32.dll", SetLastError=true)] private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr screenDc, ref PointNative dst, ref SizeNative size, IntPtr sourceDc, ref PointNative src, int colorKey, ref BlendFunction blend, int flags);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll", SetLastError=true)] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll", SetLastError=true)] private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr bits, IntPtr section, uint offset);

    private const int CanvasWidth = 420, CanvasHeight = 370;
    private const int MascotX = 126, MascotY = 43, MascotWidth = 280, MascotHeight = 318;
    private readonly float _scale;
    private readonly bool _dark;
    private readonly Bitmap _mascot, _body, _waveLayer, _frame;
    private readonly Graphics _frameGraphics;
    private readonly Font _bubbleFont;
    private readonly System.Windows.Forms.Timer _animation;
    private readonly DateTime _animationStart = DateTime.UtcNow;
    private readonly IntPtr _memoryDc, _dib, _dibBits, _previousObject;
    private bool _nativeReady;
    private bool _resourcesReleased;
    private string _title, _stage;
    private int _shown;
    private readonly Color _bubbleFill, _bubbleEdge, _bubbleInk;

    public string Title { get { return _title; } }
    public string Stage { get { return _stage; } }
    public float DpiScale { get { return _scale; } }

    public DshProgressForm(string title, string stage, string logoPath, string mascotPath) {
        _title = title ?? ""; _stage = stage ?? "";
        object theme = null;
        try { theme = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1); } catch { }
        _dark = theme is int && (int)theme == 0;
        _bubbleFill = _dark ? Color.FromArgb(34, 39, 53) : Color.FromArgb(250, 253, 255);
        _bubbleEdge = _dark ? Color.FromArgb(119, 170, 247) : Color.FromArgb(112, 164, 246);
        _bubbleInk = _dark ? Color.FromArgb(234, 241, 255) : Color.FromArgb(49, 76, 132);
        using (Graphics screen = Graphics.FromHwnd(IntPtr.Zero)) { _scale = screen.DpiX / 96f; }

        _mascot = LoadImage(mascotPath);
        if (_mascot == null) throw new FileNotFoundException("The goodbye mascot image could not be loaded.", mascotPath);
        _body = BuildBody(_mascot);
        _waveLayer = BuildWaveLayer(_mascot);
        ClientSize = new Size(S(CanvasWidth), S(CanvasHeight));
        Text = _title;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = false;
        BackColor = Color.Magenta;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        _frame = new Bitmap(ClientSize.Width, ClientSize.Height, PixelFormat.Format32bppPArgb);
        _frameGraphics = Graphics.FromImage(_frame);
        _frameGraphics.SmoothingMode = SmoothingMode.AntiAlias;
        _frameGraphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        _frameGraphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        _frameGraphics.CompositingQuality = CompositingQuality.HighQuality;
        _bubbleFont = new Font("Microsoft YaHei UI", S(25), FontStyle.Bold, GraphicsUnit.Pixel);

        _memoryDc = CreateCompatibleDC(IntPtr.Zero);
        if (_memoryDc == IntPtr.Zero) throw new InvalidOperationException("Could not create layered-window memory DC.");
        BitmapInfo info = new BitmapInfo();
        info.Header.Size = (uint)Marshal.SizeOf(typeof(BitmapInfoHeader));
        info.Header.Width = ClientSize.Width; info.Header.Height = -ClientSize.Height;
        info.Header.Planes = 1; info.Header.BitCount = 32; info.Header.Compression = 0;
        _dib = CreateDIBSection(IntPtr.Zero, ref info, 0, out _dibBits, IntPtr.Zero, 0);
        if (_dib == IntPtr.Zero || _dibBits == IntPtr.Zero) throw new InvalidOperationException("Could not create layered-window bitmap.");
        _previousObject = SelectObject(_memoryDc, _dib);

        _animation = new System.Windows.Forms.Timer();
        _animation.Interval = 50; // 20 fps; all scene elements are cached.
        _animation.Tick += delegate { UpdateLayeredFrame(CurrentWaveAngle()); };
        Shown += delegate { UpdateLayeredFrame(CurrentWaveAngle()); _animation.Start(); };
    }

    private int S(float value) { return (int)Math.Round(value * _scale); }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x00080000 | 0x00000080 | 0x08000000; return cp; }
    }

    private static Bitmap LoadImage(string path) {
        if (String.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(path)))
        using (Image source = Image.FromStream(ms)) {
            Bitmap copy = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppPArgb);
            using (Graphics g = Graphics.FromImage(copy)) {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.DrawImage(source, new Rectangle(0, 0, copy.Width, copy.Height));
            }
            return copy;
        }
    }

    // This contour severs the open hand and its ruffled cuff at the wrist.
    // Coordinates are in the source illustration's 1178 x 1335 pixel space.
    private static GraphicsPath WaveMask(int width, int height) {
        PointF[] source = new PointF[] {
            new PointF(205,574), new PointF(212,565), new PointF(214,550), new PointF(225,540),
            new PointF(228,529), new PointF(241,529), new PointF(248,539), new PointF(259,527),
            new PointF(272,534), new PointF(282,548), new PointF(294,557), new PointF(307,570),
            new PointF(321,582), new PointF(333,596), new PointF(335,610), new PointF(328,623),
            new PointF(316,631), new PointF(308,642), new PointF(300,653), new PointF(287,660),
            new PointF(273,655), new PointF(260,646), new PointF(249,637), new PointF(239,626),
            new PointF(229,615), new PointF(220,602), new PointF(211,590)
        };
        float sx = width / 1178f, sy = height / 1335f;
        PointF[] scaled = new PointF[source.Length];
        for (int i=0;i<source.Length;i++) scaled[i] = new PointF(source[i].X*sx, source[i].Y*sy);
        GraphicsPath path = new GraphicsPath(); path.AddPolygon(scaled); return path;
    }

    private static Bitmap BuildBody(Bitmap source) {
        Bitmap body = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppPArgb);
        using (Graphics g = Graphics.FromImage(body)) {
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImageUnscaled(source, 0, 0);
            using (GraphicsPath mask = WaveMask(source.Width, source.Height))
            using (SolidBrush clear = new SolidBrush(Color.Transparent)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.FillPath(clear, mask);
            }
        }
        return body;
    }

    private static Bitmap BuildWaveLayer(Bitmap source) {
        Bitmap layer = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppPArgb);
        using (Graphics g = Graphics.FromImage(layer)) {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath mask = WaveMask(source.Width, source.Height)) {
                g.SetClip(mask);
                g.DrawImageUnscaled(source, 0, 0);
                g.ResetClip();
            }
        }
        return layer;
    }

    private float CurrentWaveAngle() {
        double t = (DateTime.UtcNow - _animationStart).TotalMilliseconds / 1000.0;
        return (float)(16.0 * Math.Sin(t * Math.PI * 2.0 / 0.8));
    }

    private void DrawBubble(Graphics g) {
        float x=S(18), y=S(28), w=S(150), h=S(82), radius=S(23);
        using (GraphicsPath shape = new GraphicsPath()) {
            shape.StartFigure();
            shape.AddArc(x, y, radius, radius, 180, 90);
            shape.AddLine(x+radius/2, y, x+w-radius/2, y);
            shape.AddArc(x+w-radius, y, radius, radius, 270, 90);
            shape.AddLine(x+w, y+radius/2, x+w, y+h-radius/2);
            shape.AddArc(x+w-radius, y+h-radius, radius, radius, 0, 90);
            shape.AddLine(x+w-radius/2, y+h, x+w-S(26), y+h);
            shape.AddLine(x+w-S(26), y+h, S(212), S(156));
            shape.AddLine(S(212), S(156), x+w-S(55), y+h);
            shape.AddLine(x+w-S(55), y+h, x+radius/2, y+h);
            shape.AddArc(x, y+h-radius, radius, radius, 90, 90);
            shape.AddLine(x, y+h-radius/2, x, y+radius/2);
            shape.CloseFigure();
            using (SolidBrush fill = new SolidBrush(_bubbleFill))
            using (Pen edge = new Pen(_bubbleEdge, Math.Max(1f, S(1.6f)))) {
                edge.LineJoin = LineJoin.Round;
                g.FillPath(fill, shape);
                g.DrawPath(edge, shape);
            }
        }
        using (SolidBrush ink = new SolidBrush(_bubbleInk)) {
            StringFormat format = new StringFormat(); format.Alignment = StringAlignment.Center; format.LineAlignment = StringAlignment.Center;
            g.DrawString("再见", _bubbleFont, ink, new RectangleF(S(28), S(39), S(130), S(53)), format);
            format.Dispose();
        }
    }

    private void RenderScene(float waveDegrees) {
        _frameGraphics.Clear(Color.Transparent);
        Rectangle mascotRect = new Rectangle(S(MascotX), S(MascotY), S(MascotWidth), S(MascotHeight));
        _frameGraphics.DrawImage(_body, mascotRect);
        float pivotX = mascotRect.X + mascotRect.Width * (285f / 1178f);
        float pivotY = mascotRect.Y + mascotRect.Height * (635f / 1335f);
        GraphicsState saved = _frameGraphics.Save();
        _frameGraphics.TranslateTransform(pivotX, pivotY);
        _frameGraphics.RotateTransform(waveDegrees);
        _frameGraphics.TranslateTransform(-pivotX, -pivotY);
        _frameGraphics.DrawImage(_waveLayer, mascotRect);
        _frameGraphics.Restore(saved);
        DrawBubble(_frameGraphics);
    }

    public void ExportFrameForTesting(string path, float waveDegrees) {
        RenderScene(waveDegrees);
        _frame.Save(path, ImageFormat.Png);
    }

    private void UpdateLayeredFrame(float waveDegrees) {
        if (!IsHandleCreated || IsDisposed) return;
        RenderScene(waveDegrees);
        BitmapData data = _frame.LockBits(new Rectangle(0, 0, _frame.Width, _frame.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        try {
            byte[] row = new byte[_frame.Width * 4];
            for (int y=0;y<_frame.Height;y++) {
                IntPtr source = IntPtr.Add(data.Scan0, y * data.Stride);
                Marshal.Copy(source, row, 0, row.Length);
                Marshal.Copy(row, 0, IntPtr.Add(_dibBits, y * _frame.Width * 4), row.Length);
            }
        } finally { _frame.UnlockBits(data); }
        IntPtr screen = GetDC(IntPtr.Zero);
        try {
            PointNative destination = new PointNative(Left, Top), source = new PointNative(0, 0);
            SizeNative size = new SizeNative(_frame.Width, _frame.Height);
            BlendFunction blend = new BlendFunction(); blend.BlendOp=0; blend.BlendFlags=0; blend.SourceConstantAlpha=255; blend.AlphaFormat=1;
            _nativeReady = UpdateLayeredWindow(Handle, screen, ref destination, ref size, _memoryDc, ref source, 0, ref blend, 2);
            if (!_nativeReady) throw new InvalidOperationException("UpdateLayeredWindow failed: " + Marshal.GetLastWin32Error());
        } finally { ReleaseDC(IntPtr.Zero, screen); }
    }

    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        Rectangle area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(area.X + (area.Width-Width)/2, area.Y + (area.Height-Height)/2);
        UpdateLayeredFrame(CurrentWaveAngle());
    }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { }

    public void SetProgress(int percent, string stage) {
        _shown = Math.Max(0, Math.Min(100, percent));
        _stage = stage ?? "";
        // Keep lifecycle/test state observable through the HWND title only.
        Text = _stage;
    }

    protected override void Dispose(bool disposing) {
        if (disposing && !_resourcesReleased) {
            _resourcesReleased = true;
            if (_animation != null) { _animation.Stop(); _animation.Dispose(); }
            if (_frameGraphics != null) _frameGraphics.Dispose();
            if (_frame != null) _frame.Dispose();
            if (_body != null) _body.Dispose();
            if (_waveLayer != null) _waveLayer.Dispose();
            if (_mascot != null) _mascot.Dispose();
            if (_bubbleFont != null) _bubbleFont.Dispose();
            if (_memoryDc != IntPtr.Zero) {
                if (_previousObject != IntPtr.Zero) SelectObject(_memoryDc, _previousObject);
                if (_dib != IntPtr.Zero) DeleteObject(_dib);
                DeleteDC(_memoryDc);
            }
        }
        base.Dispose(disposing);
    }
}

public static class DshProgress {
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    private static DshProgressForm _form;
    private static Thread _thread;
    private static readonly object _lock = new object();
    private static readonly ManualResetEvent _ready = new ManualResetEvent(false);
    private static string _failure = "";
    public static string Failure { get { return _failure; } }
    public static Task<string> ReadCommandAsync() { return Task.Factory.StartNew<string>(() => Console.In.ReadLine()); }

    public static bool Show(string title, string stage, string logoPath) {
        return Show(title, stage, logoPath, Path.Combine(Path.GetDirectoryName(logoPath) ?? "", "whale-maid-goodbye.png"), true);
    }
    public static bool Show(string title, string stage, string logoPath, bool staticMascot) {
        return Show(title, stage, logoPath, Path.Combine(Path.GetDirectoryName(logoPath) ?? "", "whale-maid-goodbye.png"), true);
    }
    public static bool Show(string title, string stage, string logoPath, string mascotPath, bool staticMascot) {
        lock (_lock) {
            if (_thread != null && _thread.IsAlive) return _form != null;
            _thread = null; _form = null; _failure = ""; _ready.Reset();
            _thread = new Thread(delegate() {
                DshProgressForm form = null;
                try {
                    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
                    try { SetProcessDPIAware(); } catch { }
                    Application.EnableVisualStyles();
                    form = new DshProgressForm(title, stage, logoPath, mascotPath);
                    IntPtr handle = form.Handle;
                    _form = form;
                    form.Shown += delegate(object sender, EventArgs args) {
                        try { form.BeginInvoke((MethodInvoker)delegate() { _ready.Set(); }); }
                        catch (InvalidOperationException) { }
                    };
                    Application.Run(form);
                } catch (Exception ex) {
                    _failure = ex.ToString(); _ready.Set();
                } finally {
                    if (form != null && !form.IsDisposed) form.Dispose();
                }
            });
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.IsBackground = true;
            _thread.Start();
        }
        return _ready.WaitOne(4500) && _form != null && String.IsNullOrEmpty(_failure);
    }
    public static void SetStage(int percent, string stage) {
        DshProgressForm form; lock (_lock) { form = _form; }
        if (form == null || form.IsDisposed) return;
        try { form.BeginInvoke((MethodInvoker)delegate { form.SetProgress(percent, stage); }); } catch (InvalidOperationException) { }
    }
    public static void Close() {
        DshProgressForm form; Thread thread;
        lock (_lock) { form = _form; thread = _thread; _form = null; }
        if (form != null && !form.IsDisposed) {
            try { form.BeginInvoke((MethodInvoker)delegate { form.Close(); }); } catch (InvalidOperationException) { }
        }
        if (thread != null && thread != Thread.CurrentThread && thread.Join(3000))
            lock (_lock) { if (_thread == thread) { _thread = null; _form = null; } }
    }
}
