using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

public class DshProgressForm : Form {
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref Margins m);
    [StructLayout(LayoutKind.Sequential)] private struct Margins { public int L, R, T, B; }

    public string Title = "";
    public string Stage = "";
    private int _shown;
    private int _lastSecond = -1;
    private string _lastTimeText = "";
    private readonly DateTime _start = DateTime.Now;
    private readonly Bitmap _logo, _mascot, _wordmark;
    private Bitmap _background;
    private Bitmap _stageArt, _timeArt;
    private float _stageInkRight;
    private float _dotPhase;
    private bool _isLoading;
    private Rectangle _dotBounds = Rectangle.Empty;
    private readonly float _k;
    private readonly Color _bg, _bgEnd, _track, _edge;
    private readonly bool _dark;
    private static readonly Color Accent1 = Color.FromArgb(92, 124, 255);
    private static readonly Color Accent2 = Color.FromArgb(140, 109, 236);
    private readonly System.Windows.Forms.Timer _tick;
    private Size _regionSize = Size.Empty;
    private bool _updatingRegion;

    public DshProgressForm(string title, string stage, string logoPath, string mascotPath) {
        Title = title; Stage = stage;
        bool dark = false;
        try {
            object v = Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1);
            dark = v is int && (int)v == 0;
        } catch { }
        _dark = dark;
        _bg = dark ? Color.FromArgb(34, 36, 44) : Color.FromArgb(255, 255, 255);
        _bgEnd = dark ? Color.FromArgb(40, 43, 54) : Color.FromArgb(246, 249, 255);
        _track = dark ? Color.FromArgb(61, 64, 76) : Color.FromArgb(229, 234, 245);
        _edge = dark ? Color.FromArgb(63, 67, 80) : Color.FromArgb(231, 235, 244);
        // Read system DPI without creating this Form's HWND. CreateGraphics()
        // here fires OnHandleCreated before the final ClientSize is assigned.
        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { _k = g.DpiX / 96f; }

        _logo = LoadFitted(logoPath, S(42), S(42));
        _mascot = LoadFitted(mascotPath, S(307), S(348));
        if (_mascot == null && !string.IsNullOrEmpty(mascotPath))
            _mascot = LoadFitted(Path.Combine(Path.GetDirectoryName(mascotPath) ?? "", "deepseek-logo.png"), S(307), S(348));

        Text = title;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = _bg;
        ClientSize = new Size(S(760), S(360));
        _wordmark = BuildWordmark(Title, S(340), S(49), dark);
        string displayStage = NormalizeStage(Stage);
        _isLoading = !IsTerminalStage(0, displayStage);
        _stageArt = BuildFooterArtwork(displayStage, S(430), S(36), S(24), dark, false, _isLoading, true, out _stageInkRight);
        _dotBounds = GetDotBounds();
        UpdateTimeArtwork();
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        _background = BuildBackground(ClientSize.Width, ClientSize.Height);
        _tick = new System.Windows.Forms.Timer();
        _tick.Interval = 100;
        _tick.Tick += delegate(object s, EventArgs e) {
            int second = (int)(DateTime.Now - _start).TotalSeconds;
            if (second != _lastSecond) {
                _lastSecond = second;
                UpdateTimeArtwork();
            }
            if (_isLoading) {
                _dotPhase += 0.42f;
                if (_dotPhase >= (float)(Math.PI * 2.0)) _dotPhase -= (float)(Math.PI * 2.0);
                if (!_dotBounds.IsEmpty) Invalidate(_dotBounds);
            }
        };
        _tick.Start();
    }

    private int S(float v) { return (int)Math.Round(v * _k); }

    private static Bitmap LoadFitted(string path, int width, int height) {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        try {
            using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(path)))
            using (Image source = Image.FromStream(ms)) {
                Bitmap result = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                using (Graphics g = Graphics.FromImage(result)) {
                    g.Clear(Color.Transparent);
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    float scale = Math.Min((float)width / source.Width, (float)height / source.Height);
                    int dw = (int)Math.Round(source.Width * scale), dh = (int)Math.Round(source.Height * scale);
                    g.DrawImage(source, new Rectangle((width-dw)/2, (height-dh)/2, dw, dh));
                }
                return result;
            }
        } catch { return null; }
    }

    private static Bitmap BuildWordmark(string text, int width, int height, bool dark) {
        Bitmap bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        try {
            using (Graphics g = Graphics.FromImage(bitmap)) {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                string[] candidates = new string[] { "Segoe Print", "Segoe Script", "Segoe UI" };
                GraphicsPath glyphs = null;
                FontFamily family = null;
                RectangleF bounds = RectangleF.Empty;
                try {
                    foreach (string candidate in candidates) {
                        try {
                            family = new FontFamily(candidate);
                            glyphs = new GraphicsPath();
                            glyphs.AddString(text, family, (int)FontStyle.Bold, 40f, PointF.Empty, StringFormat.GenericDefault);
                            bounds = glyphs.GetBounds();
                            if (bounds.Width > 0.1f && bounds.Height > 0.1f) break;
                            glyphs.Dispose(); glyphs = null; family.Dispose(); family = null;
                        } catch {
                            if (glyphs != null) { glyphs.Dispose(); glyphs = null; }
                            if (family != null) { family.Dispose(); family = null; }
                        }
                    }
                    if (glyphs == null || family == null) return bitmap;
                    float marginX = Math.Max(2f, width * 0.012f);
                    float marginY = Math.Max(2f, height * 0.06f);
                    float scale = Math.Min((width - marginX * 2f) / bounds.Width,
                                           (height - marginY * 2f) / bounds.Height);
                    float drawWidth = bounds.Width * scale, drawHeight = bounds.Height * scale;
                    using (Matrix transform = new Matrix(scale, 0f, 0f, scale,
                        (width - drawWidth) / 2f - bounds.X * scale,
                        (height - drawHeight) / 2f - bounds.Y * scale))
                        glyphs.Transform(transform);
                    RectangleF fitted = glyphs.GetBounds();
                    Color start = dark ? Color.FromArgb(157, 184, 255) : Color.FromArgb(69, 111, 246);
                    Color end = dark ? Color.FromArgb(207, 166, 255) : Color.FromArgb(145, 91, 221);
                    using (LinearGradientBrush fill = new LinearGradientBrush(fitted, start, end, LinearGradientMode.Horizontal))
                    using (Pen outline = new Pen(dark ? Color.FromArgb(54, 245, 245, 255) : Color.FromArgb(210, 255, 255, 255), Math.Max(0.7f, width / 520f))) {
                        outline.LineJoin = LineJoin.Round;
                        g.DrawPath(outline, glyphs);
                        g.FillPath(fill, glyphs);
                    }
                } finally {
                    if (glyphs != null) glyphs.Dispose();
                    if (family != null) family.Dispose();
                }
            }
            return bitmap;
        } catch {
            bitmap.Dispose();
            throw;
        }
    }

    private static GraphicsPath CreateFooterPath(string text, FontFamily family, float emSize) {
        GraphicsPath path = new GraphicsPath();
        if (!string.IsNullOrEmpty(text))
            path.AddString(text, family, (int)FontStyle.Regular, emSize, PointF.Empty, StringFormat.GenericTypographic);
        return path;
    }

    private static string NormalizeStage(string text) {
        string value = (text ?? "").TrimEnd();
        while (value.EndsWith("…", StringComparison.Ordinal) || value.EndsWith("...", StringComparison.Ordinal) || value.EndsWith(".", StringComparison.Ordinal)) {
            if (value.EndsWith("...", StringComparison.Ordinal)) value = value.Substring(0, value.Length - 3).TrimEnd();
            else value = value.Substring(0, value.Length - 1).TrimEnd();
        }
        return value;
    }

    private static bool IsTerminalStage(int percent, string stage) {
        if (percent >= 100) return true;
        string value = (stage ?? "").ToLowerInvariant();
        return value.Contains("失败") || value.Contains("错误") || value.Contains("完成") ||
               value.Contains("failed") || value.Contains("failure") || value.Contains("error") || value.Contains("complete") || value.Contains("done");
    }

    private static Bitmap BuildFooterArtwork(string text, int width, int height, float emSize, bool dark, bool warmPalette, bool reserveDots, bool roundedStageFont, out float inkRight) {
        inkRight = 0f;
        if (string.IsNullOrEmpty(text))
            return new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        Bitmap bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        try {
            using (Graphics g = Graphics.FromImage(bitmap)) {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                string[] candidates = roundedStageFont
                    ? new string[] { "幼圆", "YouYuan", "KaiTi", "楷体", "Microsoft YaHei UI" }
                    : new string[] { "KaiTi", "楷体", "Microsoft YaHei UI" };
                FontFamily family = null;
                GraphicsPath glyphs = null;
                try {
                    foreach (string candidate in candidates) {
                        try {
                            family = new FontFamily(candidate);
                            glyphs = CreateFooterPath(text, family, emSize);
                            if (glyphs.PointCount > 0) break;
                            glyphs.Dispose(); glyphs = null; family.Dispose(); family = null;
                        } catch {
                            if (glyphs != null) { glyphs.Dispose(); glyphs = null; }
                            if (family != null) { family.Dispose(); family = null; }
                        }
                    }
                    if (glyphs == null || family == null) return bitmap;

                    RectangleF measured = glyphs.GetBounds();
                    float dotReserve = reserveDots ? Math.Max(1f, emSize * 1.35f) : 0f;
                    float maxWidth = Math.Max(1f, width - 2f - dotReserve);
                    if (measured.Width > maxWidth) {
                        List<string> elements = new List<string>();
                        System.Globalization.TextElementEnumerator iter = System.Globalization.StringInfo.GetTextElementEnumerator(text);
                        while (iter.MoveNext()) elements.Add(iter.GetTextElement());
                        int low = 0, high = elements.Count;
                        GraphicsPath best = null;
                        while (low <= high) {
                            int count = low + (high - low) / 2;
                            string candidateText = string.Concat(elements.GetRange(0, count).ToArray());
                            if (!reserveDots && count < elements.Count) candidateText += "…";
                            GraphicsPath trial = CreateFooterPath(candidateText, family, emSize);
                            float candidateWidth = trial.GetBounds().Width;
                            if (candidateWidth <= maxWidth) {
                                if (best != null) best.Dispose();
                                best = trial; low = count + 1;
                            } else {
                                trial.Dispose(); high = count - 1;
                            }
                        }
                        glyphs.Dispose();
                        glyphs = best ?? CreateFooterPath("", family, emSize);
                        measured = glyphs.GetBounds();
                    }

                    float marginY = Math.Max(1f, height * 0.04f);
                    float scale = Math.Min(1f, (height - marginY * 2f) / Math.Max(1f, measured.Height));
                    float drawHeight = measured.Height * scale;
                    using (Matrix transform = new Matrix(scale, 0f, 0f, scale,
                        1f - measured.X * scale,
                        (height - drawHeight) / 2f - measured.Y * scale))
                        glyphs.Transform(transform);

                    RectangleF fitted = glyphs.GetBounds();
                    Color start, end;
                    if (warmPalette) {
                        start = dark ? Color.FromArgb(255, 183, 157) : Color.FromArgb(218, 91, 82);
                        end = dark ? Color.FromArgb(255, 205, 184) : Color.FromArgb(196, 73, 127);
                    } else {
                        start = dark ? Color.FromArgb(124, 224, 236) : Color.FromArgb(12, 137, 166);
                        end = dark ? Color.FromArgb(151, 228, 185) : Color.FromArgb(28, 151, 120);
                    }
                    using (LinearGradientBrush fill = new LinearGradientBrush(fitted, start, end, LinearGradientMode.Horizontal))
                    using (Pen outline = new Pen(dark ? Color.FromArgb(54, 245, 245, 255) : Color.FromArgb(175, 255, 255, 255), 0.8f)) {
                        outline.LineJoin = LineJoin.Round;
                        g.DrawPath(outline, glyphs);
                        g.FillPath(fill, glyphs);
                    }
                    inkRight = Math.Max(0f, fitted.Right + 1f);
                } finally {
                    if (glyphs != null) glyphs.Dispose();
                    if (family != null) family.Dispose();
                }
            }
            return bitmap;
        } catch {
            bitmap.Dispose();
            throw;
        }
    }

    private void UpdateTimeArtwork() {
        TimeSpan elapsed = DateTime.Now - _start;
        string text = elapsed.TotalHours >= 1
            ? string.Format("用时  {0}:{1:00}:{2:00}", (int)elapsed.TotalHours, elapsed.Minutes, elapsed.Seconds)
            : string.Format("用时  {0}:{1:00}", (int)elapsed.TotalMinutes, elapsed.Seconds);
        if (text == _lastTimeText) return;
        float ignoredInkRight;
        Bitmap next = BuildFooterArtwork(text, S(230), S(24), S(18), _dark, true, false, false, out ignoredInkRight);
        Bitmap old = _timeArt;
        _timeArt = next;
        _lastTimeText = text;
        if (old != null) old.Dispose();
        Invalidate(new Rectangle(S(48), S(216), S(240), S(32)));
    }

    private Rectangle GetDotBounds() {
        int diameter = Math.Max(3, S(5));
        float radius = diameter / 2f;
        float spacing = S(7);
        float firstX = S(52) + (int)Math.Ceiling(_stageInkRight) + S(7);
        float lastRight = firstX + spacing * 2f + radius;
        float baseY = S(178) + S(18);
        float maxLift = S(4);
        int padding = Math.Max(2, S(1));
        int left = (int)Math.Floor(firstX - radius) - padding;
        int top = (int)Math.Floor(baseY - maxLift - radius) - padding;
        int right = (int)Math.Ceiling(lastRight) + padding;
        int bottom = (int)Math.Ceiling(baseY + radius) + padding;
        return Rectangle.FromLTRB(left, top, right, bottom);
    }

    private void DrawLoadingDots(Graphics g) {
        if (!_isLoading || _dotBounds.IsEmpty) return;
        int diameter = Math.Max(3, S(5));
        float radius = diameter / 2f;
        float baseY = S(178) + S(18);
        int firstX = S(52) + (int)Math.Ceiling(_stageInkRight) + S(7);
        Color dotColor = _dark ? Color.FromArgb(151, 228, 185) : Color.FromArgb(28, 151, 120);
        using (SolidBrush brush = new SolidBrush(dotColor)) {
            for (int i = 0; i < 3; i++) {
                double phase = _dotPhase - i * Math.PI * 0.72;
                float lift = (float)Math.Max(0.0, Math.Sin(phase)) * S(4);
                float x = firstX + i * S(7) - radius;
                float y = baseY - lift - radius;
                g.FillEllipse(brush, x, y, diameter, diameter);
            }
        }
    }

    private int MascotRightAt(int physicalY) {
        if (_mascot == null) return S(468);
        int top = S(4), left = S(435);
        int row = physicalY - top;
        if (row < 0 || row >= _mascot.Height) return -1;
        for (int x = _mascot.Width - 1; x >= 0; x--) {
            if (_mascot.GetPixel(x, row).A >= 12) return left + x;
        }
        return -1;
    }

    private GraphicsPath CardPath() {
        int left = S(24), top = S(60), bottom = S(340), radius = S(18);
        int d = Math.Max(2, radius * 2);
        List<Point> edge = new List<Point>();
        int previous = S(470);
        int step = Math.Max(1, S(1));
        for (int y = top; y <= bottom; y += step) {
            int right = MascotRightAt(y);
            if (right >= 0) previous = right + Math.Max(1, S(1));
            edge.Add(new Point(Math.Min(ClientSize.Width - 1, previous), y));
        }
        if (edge.Count == 0 || edge[edge.Count - 1].Y != bottom)
            edge.Add(new Point(Math.Min(ClientSize.Width - 1, previous), bottom));

        GraphicsPath path = new GraphicsPath();
        path.StartFigure();
        path.AddLine(left + radius, top, edge[0].X, top);
        if (edge.Count > 1) path.AddLines(edge.ToArray());
        path.AddLine(edge[edge.Count - 1].X, bottom, left + radius, bottom);
        path.AddArc(left, bottom - d, d, d, 90, 90);
        path.AddLine(left, bottom - radius, left, top + radius);
        path.AddArc(left, top, d, d, 180, 90);
        path.CloseFigure();
        return path;
    }

    private GraphicsPath MascotRegionPath() {
        GraphicsPath path = new GraphicsPath();
        if (_mascot == null) return path;
        int left = S(435), top = S(4), cardTop = S(60);
        int rowsAboveCard = Math.Min(_mascot.Height, cardTop - top);
        // The card contains the entire mascot below its top edge; only add
        // pixels above it so the head can overhang without a rectangular HWND.
        for (int y = 0; y < rowsAboveCard; y++) {
            int x = 0;
            while (x < _mascot.Width) {
                while (x < _mascot.Width && _mascot.GetPixel(x, y).A < 12) x++;
                int start = x;
                while (x < _mascot.Width && _mascot.GetPixel(x, y).A >= 12) x++;
                if (x > start) path.AddRectangle(new Rectangle(left + start, top + y, x - start, 1));
            }
        }
        return path;
    }

    private void UpdateWindowRegion() {
        if (_updatingRegion || !IsHandleCreated || IsDisposed || ClientSize.Width < 2 || ClientSize.Height < 2) return;
        if (_regionSize == ClientSize && Region != null) return;
        _updatingRegion = true;
        try {
            using (GraphicsPath card = CardPath())
            using (GraphicsPath figure = MascotRegionPath()) {
                Region combined = new Region(card);
                if (figure.PointCount > 0) combined.Union(figure);
                using (Region clientBounds = new Region(new Rectangle(Point.Empty, ClientSize)))
                    combined.Intersect(clientBounds);
                // Control.Region owns the assigned object and releases its predecessor.
                Region = combined;
            }
            _regionSize = ClientSize;
        } finally {
            _updatingRegion = false;
        }
    }

    private Bitmap BuildBackground(int width, int height) {
        Bitmap b = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, width, height);
            using (GraphicsPath card = CardPath())
            using (LinearGradientBrush fill = new LinearGradientBrush(bounds, _bg, _bgEnd, LinearGradientMode.Vertical))
                g.FillPath(fill, card);
        }
        return b;
    }

    private void RebuildBackground() {
        Bitmap next = BuildBackground(ClientSize.Width, ClientSize.Height);
        Bitmap old = _background;
        _background = next;
        if (old != null) old.Dispose();
    }

    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80; return cp; }
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try {
            _regionSize = Size.Empty;
            UpdateWindowRegion();
            int policy = 2; DwmSetWindowAttribute(Handle, 2, ref policy, 4);
        } catch { }
    }

    protected override void OnSizeChanged(EventArgs e) {
        base.OnSizeChanged(e);
        if (_updatingRegion || !IsHandleCreated || IsDisposed) return;
        try {
            RebuildBackground();
            _regionSize = Size.Empty;
            UpdateWindowRegion();
            Invalidate();
        } catch { }
    }

    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        Rectangle wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(wa.X + (wa.Width - Width) / 2, wa.Y + (wa.Height - Height) / 2);
    }

    private static GraphicsPath Pill(RectangleF r) {
        GraphicsPath p = new GraphicsPath();
        float d = r.Height;
        p.AddArc(r.X, r.Y, d, d, 90, 180);
        p.AddArc(r.Right-d, r.Y, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }

    public void SetProgress(int percent, string stage) {
        _shown = Math.Max(0, Math.Min(100, percent));
        string normalized = NormalizeStage(stage);
        bool loading = !IsTerminalStage(_shown, normalized);
        bool changed = stage != Stage;
        bool loadingChanged = loading != _isLoading;
        Rectangle previousDots = _dotBounds;
        _isLoading = loading;
        if (changed || loadingChanged) {
            if (changed) { Stage = stage; Text = stage; }
            Bitmap next = BuildFooterArtwork(normalized, S(430), S(36), S(24), _dark, false, _isLoading, true, out _stageInkRight);
            Bitmap old = _stageArt;
            _stageArt = next;
            if (old != null) old.Dispose();
            _dotBounds = GetDotBounds();
        }
        if (loadingChanged) {
            if (_isLoading) _dotPhase = 0f;
            Invalidate(previousDots);
            Invalidate(_dotBounds);
        }
        if (changed) {
            Invalidate(new Rectangle(S(48), S(172), S(450), S(52)));
        }
        Invalidate(new Rectangle(S(48), S(292), S(430), S(18)));
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        if (_background != null) g.DrawImageUnscaled(_background, 0, 0);
        else g.Clear(_bg);

        if (_logo != null) g.DrawImageUnscaled(_logo, S(50), S(101));
        if (_wordmark != null) g.DrawImageUnscaled(_wordmark, S(106), S(98));
        if (_stageArt != null) g.DrawImageUnscaled(_stageArt, S(52), S(178));
        DrawLoadingDots(g);
        if (_timeArt != null) g.DrawImageUnscaled(_timeArt, S(52), S(220));

        RectangleF track = new RectangleF(S(52), S(296), S(420), S(10));
        using (GraphicsPath tp = Pill(track))
        using (SolidBrush tb = new SolidBrush(_track)) g.FillPath(tb, tp);
        float w = track.Width * _shown / 100f;
        if (w > 0.5f) {
            RectangleF fill = new RectangleF(track.X, track.Y, Math.Max(w, track.Height), track.Height);
            using (GraphicsPath fp = Pill(fill))
            using (LinearGradientBrush accent = new LinearGradientBrush(track, Accent1, Accent2, LinearGradientMode.Horizontal))
                g.FillPath(accent, fp);
        }
        if (_mascot != null) g.DrawImageUnscaled(_mascot, S(435), S(4));
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        if (_tick != null) _tick.Stop();
        base.OnFormClosed(e);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            if (_tick != null) { _tick.Stop(); _tick.Dispose(); }
            if (_logo != null) _logo.Dispose();
            if (_mascot != null) _mascot.Dispose();
            if (_background != null) _background.Dispose();
            if (_wordmark != null) _wordmark.Dispose();
            if (_stageArt != null) _stageArt.Dispose();
            if (_timeArt != null) _timeArt.Dispose();
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

    // PowerShell runspaces are not available on arbitrary ThreadPool threads.
    // Keep the blocking console read inside compiled C# instead.
    public static Task<string> ReadCommandAsync() {
        return Task.Factory.StartNew<string>(() => Console.In.ReadLine());
    }

    public static bool Show(string title, string stage, string logoPath) {
        string mascotPath = Path.Combine(Path.GetDirectoryName(logoPath) ?? "", "whale-maid-static.png");
        return Show(title, stage, logoPath, mascotPath, true);
    }
    public static bool Show(string title, string stage, string logoPath, bool staticMascot) {
        string mascotPath = Path.Combine(Path.GetDirectoryName(logoPath) ?? "", "whale-maid-static.png");
        return Show(title, stage, logoPath, mascotPath, true);
    }
    public static bool Show(string title, string stage, string logoPath, string mascotPath, bool staticMascot) {
        lock (_lock) {
            if (_thread != null && _thread.IsAlive) return _form != null;
            _thread = null; _form = null; _failure = ""; _ready.Reset();
            _thread = new Thread(delegate() {
                try {
                    try { SetProcessDPIAware(); } catch { }
                    Application.EnableVisualStyles();
                    DshProgressForm f = new DshProgressForm(title, stage, logoPath, mascotPath);
                    IntPtr handle = f.Handle;
                    _form = f;
                    f.Shown += delegate(object sender, EventArgs args) {
                        // Shown runs after the HWND is visible. Queue the signal once
                        // more so the first message-pump turn has completed too.
                        try { f.BeginInvoke((MethodInvoker)delegate() { _ready.Set(); }); }
                        catch (InvalidOperationException) { }
                    };
                    Application.Run(f);
                } catch (Exception ex) {
                    _failure = ex.ToString();
                    _ready.Set();
                }
            });
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.IsBackground = true;
            _thread.Start();
        }
        return _ready.WaitOne(4500) && _form != null && string.IsNullOrEmpty(_failure);
    }
    public static void SetStage(int percent, string stage) {
        DshProgressForm f;
        lock (_lock) { f = _form; }
        if (f == null || f.IsDisposed) return;
        int p = Math.Max(0, Math.Min(100, percent));
        try { f.BeginInvoke((MethodInvoker)delegate() { f.SetProgress(p, stage); }); }
        catch (InvalidOperationException) { }
    }
    public static void Close() {
        DshProgressForm f; Thread t;
        lock (_lock) { f = _form; t = _thread; _form = null; }
        if (f != null && !f.IsDisposed) {
            try { f.BeginInvoke((MethodInvoker)delegate() { f.Close(); }); }
            catch (InvalidOperationException) { }
        }
        if (t != null && t != Thread.CurrentThread && t.Join(3000))
            lock (_lock) { if (_thread == t) { _thread = null; _form = null; } }
    }
}
