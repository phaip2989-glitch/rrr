<#
  ShadowReaper  -  FiveM Performance Suite
  (c) 2026 ShadowReaper. All rights reserved.
  Discord : https://discord.gg/jZmgjzRq7j
  Run     : right-click > Run with PowerShell  (auto-elevates to Administrator)
#>
$ErrorActionPreference = 'SilentlyContinue'

# ---------- hosted URL (used when launched with:  irm <url> | iex ) ----------
$SelfUrl = 'https://raw.githubusercontent.com/phaip2989-glitch/rrr/main/ShadowReaper.ps1'

# ---------- elevate + Windows PowerShell 5.1 STA ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needRelaunch = (-not $isAdmin) -or ($PSVersionTable.PSEdition -ne 'Desktop') -or ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA')
if ($needRelaunch) {
    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if ($PSCommandPath) {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    }
    elseif ($SelfUrl -match '^https://') {
        $cmd = '[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm ''' + $SelfUrl + ''' | iex'
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "' + $cmd + '"')
    }
    else {
        Write-Host 'ShadowReaper: set $SelfUrl at the top of the script, or run it from an Administrator Windows PowerShell.' -ForegroundColor Yellow
    }
    return
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$CSharp = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Diagnostics;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class SRNative
{
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, int w, int l);
    [DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr h);
    [DllImport("ntdll.dll")] public static extern int RtlAdjustPrivilege(int priv, bool enable, bool thread, out bool old);
    [DllImport("ntdll.dll")] public static extern int NtSetSystemInformation(int cls, IntPtr info, int len);


    [StructLayout(LayoutKind.Sequential)]
    public struct FILTERKEYS { public uint cbSize; public uint dwFlags; public uint iWaitMSec; public uint iDelayMSec; public uint iRepeatMSec; public uint iBounceMSec; }
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfo", SetLastError = true)]
    static extern bool SpiFilterKeys(uint action, uint param, ref FILTERKEYS fk, uint winIni);

    // returns flags, wait, delay, repeat, bounce
    public static uint[] GetFK()
    {
        FILTERKEYS f = new FILTERKEYS();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FILTERKEYS));
        SpiFilterKeys(0x32, f.cbSize, ref f, 0);
        return new uint[] { f.dwFlags, f.iWaitMSec, f.iDelayMSec, f.iRepeatMSec, f.iBounceMSec };
    }
    public static bool SetFK(uint flags, uint wait, uint delay, uint rep, uint bounce, uint winIni)
    {
        FILTERKEYS f = new FILTERKEYS();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FILTERKEYS));
        f.dwFlags = flags; f.iWaitMSec = wait; f.iDelayMSec = delay; f.iRepeatMSec = rep; f.iBounceMSec = bounce;
        return SpiFilterKeys(0x33, f.cbSize, ref f, winIni);
    }


    [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint min, out uint max, out uint cur);
    [DllImport("ntdll.dll")] static extern int NtSetTimerResolution(uint desired, bool set, out uint cur);
    // returns min(slowest), max(fastest), current  (100ns units)
    public static uint[] QueryTimer()
    {
        uint a = 0, b = 0, c = 0;
        NtQueryTimerResolution(out a, out b, out c);
        return new uint[] { a, b, c };
    }
    public static uint SetTimer(uint desired, bool set)
    {
        uint cur = 0;
        NtSetTimerResolution(desired, set, out cur);
        return cur;
    }

    public static void DragWindow(IntPtr h)
    {
        ReleaseCapture();
        SendMessage(h, 0xA1, 2, 0);
    }

    public static GraphicsPath Round(Rectangle r, int rad)
    {
        GraphicsPath p = new GraphicsPath();
        int d = rad * 2;
        if (d < 2) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    // purge standby list (needs admin)
    public static string PurgeStandby()
    {
        try
        {
            bool old;
            RtlAdjustPrivilege(20, true, false, out old);
            IntPtr mem = Marshal.AllocHGlobal(4);
            Marshal.WriteInt32(mem, 4); // MemoryPurgeStandbyList
            int r = NtSetSystemInformation(80, mem, 4);
            Marshal.FreeHGlobal(mem);
            return r == 0 ? "ok" : ("status " + r);
        }
        catch (Exception ex) { return ex.Message; }
    }
}

// Main borderless form with cover-fit background
public class SRForm : Form
{
    public Image Bg;
    public SRForm()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FormBorderStyle = FormBorderStyle.None;
        DoubleBuffered = true;
    }
    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (Width > 0 && Height > 0)
        {
            using (GraphicsPath p = SRNative.Round(new Rectangle(0, 0, Width, Height), 14)) { Region = new Region(p); }
        }
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(Color.FromArgb(10, 10, 12));
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        if (Bg != null)
        {
            float sw = (float)Width / Bg.Width, sh = (float)Height / Bg.Height;
            float s = Math.Max(sw, sh);
            float w = Bg.Width * s, h = Bg.Height * s;
            g.DrawImage(Bg, (Width - w) / 2f, (Height - h) / 2f, w, h);
        }
        using (LinearGradientBrush br = new LinearGradientBrush(new Rectangle(0, 0, Width, Height), Color.FromArgb(215, 6, 6, 8), Color.FromArgb(120, 6, 6, 8), 0f))
        { g.FillRectangle(br, 0, 0, Width, Height); }
        using (Pen pen = new Pen(Color.FromArgb(90, 255, 255, 255), 1.5f))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath p = SRNative.Round(new Rectangle(0, 0, Width - 1, Height - 1), 14)) { g.DrawPath(pen, p); }
        }
    }
}

public class GlassPanel : Panel
{
    public int Alpha = 150;
    public int Radius = 12;
    public bool Border = true;
    public GlassPanel()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = SRNative.Round(r, Radius))
        {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(Alpha, 14, 14, 16))) { g.FillPath(b, p); }
            if (Border) { using (Pen pen = new Pen(Color.FromArgb(70, 255, 255, 255), 1f)) { g.DrawPath(pen, p); } }
        }
    }
}

public class FxButton : Control
{
    public bool Accent = false;
    public bool Active = false;
    public bool LeftAlign = false;
    public int Radius = 10;
    bool hover = false, down = false;
    float hv = 0f, rip = 2f, pr = 0f;
    Point ripPt;
    Timer tm;

    public FxButton()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor | ControlStyles.Selectable, true);
        BackColor = Color.Transparent;
        ForeColor = Color.White;
        Cursor = Cursors.Hand;
        tm = new Timer();
        tm.Interval = 15;
        tm.Tick += delegate
        {
            bool busy = false;
            float target = hover ? 1f : 0f;
            if (Math.Abs(hv - target) > 0.02f) { hv += (target - hv) * 0.25f; busy = true; } else { hv = target; }
            float pt = down ? 1f : 0f;
            if (Math.Abs(pr - pt) > 0.02f) { pr += (pt - pr) * 0.4f; busy = true; } else { pr = pt; }
            if (rip <= 1f) { rip += 0.06f; busy = true; if (rip > 1f) rip = 2f; }
            Invalidate();
            if (!busy) tm.Stop();
        };
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; tm.Start(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; tm.Start(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        down = true; ripPt = e.Location; rip = 0f; tm.Start();
        base.OnMouseDown(e);
    }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; tm.Start(); base.OnMouseUp(e); }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        Rectangle r = new Rectangle(1, 1, Width - 3, Height - 3);
        if (pr > 0) { r.Inflate((int)(-2 * pr), (int)(-1 * pr)); }
        Color baseC, hovC, txt;
        if (Accent) { baseC = Color.FromArgb(235, 235, 235); hovC = Color.FromArgb(255, 255, 255); txt = Color.FromArgb(10, 10, 10); }
        else if (Active) { baseC = Color.FromArgb(200, 70, 70, 76); hovC = Color.FromArgb(225, 95, 95, 102); txt = Color.White; }
        else { baseC = Color.FromArgb(120, 24, 24, 28); hovC = Color.FromArgb(190, 62, 62, 68); txt = Color.FromArgb(230, 230, 230); }
        Color fill = Color.FromArgb((int)(baseC.A + (hovC.A - baseC.A) * hv), (int)(baseC.R + (hovC.R - baseC.R) * hv), (int)(baseC.G + (hovC.G - baseC.G) * hv), (int)(baseC.B + (hovC.B - baseC.B) * hv));
        using (GraphicsPath p = SRNative.Round(r, Radius))
        {
            using (SolidBrush b = new SolidBrush(fill)) { g.FillPath(b, p); }
            if (rip <= 1f)
            {
                GraphicsState st = g.Save();
                g.SetClip(p, CombineMode.Intersect);
                float mr = (float)Math.Sqrt(Width * Width + Height * Height) * rip;
                int a = (int)(150 * (1f - rip));
                Color rc = Accent ? Color.FromArgb(a, 90, 90, 90) : Color.FromArgb(a, 255, 255, 255);
                using (SolidBrush rb = new SolidBrush(rc)) { g.FillEllipse(rb, ripPt.X - mr, ripPt.Y - mr, mr * 2, mr * 2); }
                g.Restore(st);
            }
            Color bc = Active || Accent ? Color.FromArgb(220, 255, 255, 255) : Color.FromArgb((int)(60 + 120 * hv), 255, 255, 255);
            using (Pen pen = new Pen(bc, 1.2f)) { g.DrawPath(pen, p); }
        }
        if (Active && !Accent)
        {
            using (SolidBrush wb = new SolidBrush(Color.White)) { g.FillRectangle(wb, 0, Height / 2 - 11, 4, 22); }
        }
        StringFormat sf = new StringFormat();
        sf.LineAlignment = StringAlignment.Center;
        sf.Alignment = LeftAlign ? StringAlignment.Near : StringAlignment.Center;
        sf.Trimming = StringTrimming.EllipsisCharacter;
        sf.FormatFlags = StringFormatFlags.NoWrap;
        Rectangle tr = new Rectangle(LeftAlign ? 18 : 4, 0, Width - (LeftAlign ? 22 : 8), Height);
        if (pr > 0) tr.Offset(0, 1);
        using (SolidBrush tb = new SolidBrush(txt)) { g.DrawString(Text, Font, tb, tr, sf); }
    }
}

public class SRToast : Form
{
    static List<SRToast> active = new List<SRToast>();
    string ttl, msg; int kind;
    Timer tm; int age = 0; int targetLeft, targetTop;
    const int W = 310, H = 64;

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x80 | 0x08; return cp; }
    }

    public static void Notify(string title, string message, int kind)
    {
        SRToast t = new SRToast(title, message, kind);
        if (active.Count >= 5) { active[0].Kill(); }
        active.Add(t);
        Relayout();
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        t.Left = wa.Right + 10; t.Top = t.targetTop;
        t.Show();
    }

    static void Relayout()
    {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        for (int i = 0; i < active.Count; i++)
        {
            int fromBottom = active.Count - 1 - i;
            active[i].targetLeft = wa.Right - W - 14;
            active[i].targetTop = wa.Bottom - 14 - (fromBottom + 1) * H - fromBottom * 8;
        }
    }

    SRToast(string title, string message, int k)
    {
        ttl = title; msg = message; kind = k;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false; TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(W, H);
        BackColor = Color.FromArgb(16, 16, 18);
        DoubleBuffered = true;
        Opacity = 0.0;
        using (GraphicsPath p = SRNative.Round(new Rectangle(0, 0, W, H), 10)) { Region = new Region(p); }
        tm = new Timer(); tm.Interval = 16;
        tm.Tick += delegate
        {
            age += 16;
            Left += (targetLeft - Left) / 5;
            Top += (targetTop - Top) / 4;
            if (age < 260) Opacity = Math.Min(0.96, age / 260.0);
            else if (age > 3000) { Opacity -= 0.06; if (Opacity <= 0.05) Kill(); }
        };
        tm.Start();
    }

    void Kill()
    {
        if (tm != null) { tm.Stop(); tm.Dispose(); tm = null; }
        active.Remove(this);
        Relayout();
        try { Close(); } catch { }
    }

    protected override void OnMouseClick(MouseEventArgs e) { age = Math.Max(age, 2950); base.OnMouseClick(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        Color c = kind == 1 ? Color.FromArgb(255, 255, 255) : kind == 2 ? Color.FromArgb(255, 200, 80) : kind == 3 ? Color.FromArgb(255, 80, 80) : Color.FromArgb(160, 160, 165);
        using (SolidBrush b = new SolidBrush(c)) { g.FillRectangle(b, 0, 0, 5, H); }
        using (Pen p = new Pen(Color.FromArgb(90, 255, 255, 255), 1f)) { g.DrawRectangle(p, 0, 0, W - 1, H - 1); }
        using (Font f1 = new Font("Segoe UI Black", 10f, FontStyle.Bold))
        using (Font f2 = new Font("Segoe UI", 9f, FontStyle.Bold))
        using (SolidBrush w = new SolidBrush(Color.White))
        using (SolidBrush gr = new SolidBrush(Color.FromArgb(200, 200, 205)))
        {
            g.DrawString(ttl, f1, w, new RectangleF(16, 8, W - 24, 22));
            g.DrawString(msg, f2, gr, new RectangleF(16, 30, W - 24, 32));
        }
    }
}


public class GraphPanel : Panel
{
    public List<float> Data = new List<float>();
    public float Ceil = 60f;
    public GraphPanel()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.FromArgb(12, 12, 14);
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);
        using (Pen gp = new Pen(Color.FromArgb(40, 255, 255, 255)))
        {
            for (int i = 1; i < 5; i++) { int yy = Height * i / 5; g.DrawLine(gp, 0, yy, Width, yy); }
        }
        float max = Ceil;
        foreach (float d in Data) { if (d * 1.15f > max) max = d * 1.15f; }
        using (Font f = new Font("Segoe UI", 8f, FontStyle.Bold))
        using (SolidBrush tb = new SolidBrush(Color.FromArgb(150, 150, 158)))
        {
            g.DrawString(((int)max) + " ms", f, tb, 4, 2);
            g.DrawString("0", f, tb, 4, Height - 16);
        }
        if (Data.Count < 2) return;
        float step = (Width - 12f) / 59f;
        List<PointF> pts = new List<PointF>();
        int start = Math.Max(0, Data.Count - 60);
        for (int i = start; i < Data.Count; i++)
        {
            float x = 6f + (i - start) * step;
            float v = Data[i];
            if (v < 0)
            {
                using (Pen rp = new Pen(Color.FromArgb(220, 255, 80, 80), 2f)) { g.DrawLine(rp, x, Height - 4, x, Height - 14); }
                continue;
            }
            float y = (Height - 6f) - (v / max) * (Height - 12f);
            pts.Add(new PointF(x, y));
        }
        if (pts.Count > 1) { using (Pen lp = new Pen(Color.White, 2f)) { g.DrawLines(lp, pts.ToArray()); } }
    }
}

public static class Bench
{
    public static double Cpu()
    {
        Stopwatch sw = Stopwatch.StartNew();
        ulong x = 88172645463325252UL; ulong acc = 0;
        for (int i = 0; i < 150000000; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; acc += x; }
        sw.Stop();
        if (acc == 42) Console.Write("");
        return 150.0 / sw.Elapsed.TotalSeconds; // Mops/s
    }
    public static double Ram()
    {
        byte[] a = new byte[128 * 1024 * 1024];
        byte[] b = new byte[a.Length];
        Buffer.BlockCopy(a, 0, b, 0, a.Length);
        Stopwatch sw = Stopwatch.StartNew();
        for (int i = 0; i < 4; i++) { Buffer.BlockCopy(a, 0, b, 0, a.Length); }
        sw.Stop();
        return (4 * 128.0) / sw.Elapsed.TotalSeconds; // MB/s
    }
}

'@
if (-not ('SRForm' -as [type])) {
    try { Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $CSharp -ErrorAction Stop }
    catch {
        [System.Windows.Forms.MessageBox]::Show('ShadowReaper failed to start: ' + $_.Exception.Message, 'ShadowReaper') | Out-Null
        return
    }
}

$Discord = 'https://discord.gg/jZmgjzRq7j'

$BgB64 = @'
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
'@

$RegB64 = @'
H4sIACoEx2oC/91Y/0/iShD/nb+C9GfzAuh59y55idAWIU+gactx5tWYtZ3ChrLbt7tV9K9/s6WI0NY7jRrzjIk4MztfPjM7s8OMsojfyaYLcyqVuG/aEVVcNH+AkJSz5pc/Wq1G45/B3/bl9cXE7F5cj7rmYDi2
A+/S8+1RYGZCAFMmZ0rwxAMVeCBuaQgy8MOUpoFDBFmBQn1XDaPPxR0RUU9wEoVEKmn8Fd1xEX1vFT8Nw5WyRySYaXbAazcM33TG3IKE3FfwwrQbLvsC/s2AhdUCeBRlfBouKwwj36criGaEqgobbWgYI7KeShAO
F+opM45jZFpAovOZhaGGeD4mWaIqnWgfd44naVXoQ8dm5CYBl2eIV5m/4Q7NkeNCRAXaKRl4o1QFQ4Z/YoK8q3fQGZydnU+H1tnZ1Vvkrb4oqj2f9P1Z17WDEQ0FlzxWway4BWN/G1BR/8EIs6iLgpLAu5cKVo7g
MU0AHR+DQmtLfyG4Ugll8yGLYL31IS5+GsbmnAsy5UzSW2AgK6IY8wvycD/iEZQR2HJ0eWJpPBFo54ffL8zAJ3JZWwJvZyHoZhHlCGo3jimj6jCVXxtGj4TLueAZi5oTlqCA4YsMjIZhJjxcNl2i9pDrfG0jqufO
tOkIykVZ5beGUcM5xZyFC4gyndSmiYrnXGiDI3Q/W6FJrz+cPNGLyRMrkhjvD5NJUpUJqAeq9ZFAffm8QFlUptgRHC4VMrDlSHTxdbDtGPUAvTm03+qgHdD5ogLYDfkjYFWC3mQKZT9JEZ583iI8x8knXwhTnyTy
Y7vasxWFs0fpsdz0AIeXwvG1S+UzI+vdoXXwct8geK9E95d3+uQdMnD8eSsV/2v+YgR/bLW2X1itH4bU5mBzRBiZg/ifD2KHJzSk+F4vARc4UhvUz2DOeiCVHce4FV3QFVUlJF62QBQfg623xf9oCj/dglAUlyAv
wSArWg8iiB4ed7aHPUhxAdHjal+wc/par/hdnnYzIVK2h5h5SpIpQytLE1N9EPwJ+mNmUvEVfQArE5geVJal5Wq3GYj5vS2x9nJ3N7teVA5vQG9A9LEgPVTpgAiBlRE3RnEvw61UG8QFBeSCJxW68HhskiTMNJrd
UGUYiqIJfahALL+SPEN7GIFCvbK4MeUup/cU4cINrvGPxifMEjSV9vqwPo7DIiaGPhRR167Ph4LlkExOEpChjlt7ke+ct1jpZUFZq8PGJW37bOSiWuxxxplT17XH/vXUs91tlTQdwiAJRjyT+Vs91INzc3N8gV0B
vatoFwBpfjPxulo8Q5sm3r7lALDjIRTGyT7dS0E7ZfzZau0zZjRSi0LeXuP0jiDydBeSW+25XwOOd2lP+Y6sodPEXPWO/FRzTt0+CjY9pf0ovfXtkfBYBu1KamePKghNZEHxVpyrRU7/iZdSPz8WsEbUjup+SQVx
T8/lb+g5PT0ip0etTlkPI6nPi/rsZUrp+t94ekfSXP+GWgTwuibj6X2Fs+2UCZZY9KA7oJWGM6LCRcTnxViaxLEEVZ4jeeGLLFWegrwN4NO9uo6NguPL9W/V+GYq5o9b9Demc0/xfCXVFOuHe9337B4syC124AOF
nZ1Q7eWr0FLR559oGnDGhf5a7vkT7d0J6+f5MD+FJ4p5ZvJVSvLJUn/MRvE+EL2A9xMyl/W+W88g8Mpv07p9a++r1P8AkWQ+j7kVAAA=
'@

# =====================================================================
#  helpers
# =====================================================================
$script:busy = $false
$script:rtb = $null
$script:BkDir = Join-Path $env:ProgramData 'ShadowReaper\Backup'
$script:FiveApp = Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app'

function Pump([int]$ms = 100) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 8 }
}

function Log([string]$s, [string]$lvl = 'info') {
    if ($lvl -eq 'err') { try { Add-Content -Path (Join-Path $env:ProgramData 'ShadowReaper\error.log') -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $s) } catch {} }
    if (-not $script:rtb) { return }
    $col = 'Silver'
    if ($lvl -eq 'ok') { $col = 'White' } elseif ($lvl -eq 'err') { $col = 'IndianRed' } elseif ($lvl -eq 'warn') { $col = 'Gold' }
    $script:rtb.SelectionStart = $script:rtb.TextLength
    $script:rtb.SelectionColor = [System.Drawing.Color]::FromName($col)
    $script:rtb.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $s))
    $script:rtb.ScrollToCaret()
}

function Log-Err($er) {
    try {
        $d = Join-Path $env:ProgramData 'ShadowReaper'
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $msg = "[{0}] {1}`r`n{2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $er.Exception.Message, $er.InvocationInfo.PositionMessage
        Add-Content -Path (Join-Path $d 'error.log') -Value $msg
    } catch {}
}

function Toast([string]$t, [string]$m, [int]$k = 1) {
    [SRToast]::Notify($t, $m, $k)
    $lvl = 'info'
    if ($k -eq 1) { $lvl = 'ok' } elseif ($k -eq 2) { $lvl = 'warn' } elseif ($k -eq 3) { $lvl = 'err' }
    Log ("{0}  -  {1}" -f $t, $m) $lvl
    Pump 160
}

function Set-Progress([int]$pct) {
    if ($script:progFill) { $script:progFill.Width = [int]($script:progBack.Width * $pct / 100); $script:progFill.Invalidate() }
    Pump 20
}

function Run-Step([string]$name, [scriptblock]$sb) {
    try { $null = @(& $sb); return $true }
    catch { Log ("{0}: {1}" -f $name, $_.Exception.Message) 'err'; return $false }
}

function Set-Reg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

function Pick-Font($names, [single]$size, $style = [System.Drawing.FontStyle]::Bold) {
    foreach ($n in $names) {
        if ($script:families -contains $n) { return (New-Object System.Drawing.Font -ArgumentList $n, $size, $style) }
    }
    return (New-Object System.Drawing.Font -ArgumentList 'Segoe UI', $size, $style)
}
$script:families = [System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name }
$fTitle = Pick-Font @('Impact', 'Bahnschrift', 'Segoe UI Black') 26
$fBig = Pick-Font @('Impact', 'Segoe UI Black') 22
$fBtn = Pick-Font @('Segoe UI Black', 'Bahnschrift SemiBold', 'Segoe UI') 10.5
$fBody = Pick-Font @('Segoe UI Black', 'Segoe UI') 9
$fSmall = Pick-Font @('Segoe UI Semibold', 'Segoe UI') 8.5
$fMono = Pick-Font @('Consolas', 'Courier New') 9.5

# =====================================================================
#  system / registry modules
# =====================================================================
function Get-ActiveAdapter {
    $ad = $null
    try {
        $rt = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
        if ($rt) { $ad = Get-NetAdapter -InterfaceIndex $rt.InterfaceIndex }
    } catch {}
    if (-not $ad) { $ad = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1 }
    if (-not $ad) { $ad = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1 }
    return $ad
}

function Get-RegText {
    $b = [Convert]::FromBase64String($RegB64)
    $ms = New-Object System.IO.MemoryStream -ArgumentList (, $b)
    $gz = New-Object System.IO.Compression.GZipStream -ArgumentList $ms, ([System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader -ArgumentList $gz, ([System.Text.Encoding]::UTF8)
    $t = $sr.ReadToEnd(); $sr.Close()
    return $t
}

function Backup-Reg {
    if (Test-Path (Join-Path $script:BkDir 'original.done')) { return 'Backup already exists' }
    New-Item -ItemType Directory -Path $script:BkDir -Force | Out-Null
    $keys = [ordered]@{
        tcpip  = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        afd    = 'HKLM\SYSTEM\CurrentControlSet\Services\AFD\Parameters'
        mmcss  = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        prio   = 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl'
        power  = 'HKLM\SYSTEM\CurrentControlSet\Control\Power'
        kernel = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
        gcs    = 'HKCU\System\GameConfigStore'
        mouse  = 'HKCU\Control Panel\Mouse'
    }
    foreach ($k in $keys.GetEnumerator()) { & reg.exe export $k.Value (Join-Path $script:BkDir ($k.Key + '.reg')) /y 2>&1 | Out-Null }
    $ini = Join-Path $script:FiveApp 'CitizenFX.ini'
    if (Test-Path $ini) { Copy-Item $ini (Join-Path $script:BkDir 'CitizenFX.ini.bak') -Force }
    Set-Content -Path (Join-Path $script:BkDir 'original.done') -Value (Get-Date).ToString()
    return 'Original settings saved'
}

function Do-RegImport {
    Get-NetAdapter | Select-Object Name, InterfaceGuid, MacAddress | ForEach-Object { Log ("  {0}   {1}   {2}" -f $_.Name, $_.InterfaceGuid, $_.MacAddress) }
    $ad = Get-ActiveAdapter
    if (-not $ad) { throw 'No active network adapter found' }
    $guid = [string]$ad.InterfaceGuid
    if ($guid -notmatch '^\{') { $guid = '{' + $guid.Trim('{', '}') + '}' }
    Log ("Using adapter: {0}  {1}" -f $ad.Name, $guid)
    $txt = (Get-RegText).Replace('@@GUID@@', $guid)
    $txt = $txt -replace "`r?`n", "`r`n"
    $f = Join-Path $env:TEMP 'ShadowReaper_Tcpip.reg'
    [System.IO.File]::WriteAllText($f, $txt, [System.Text.Encoding]::Unicode)
    & reg.exe import $f 2>&1 | Out-Null
    $code = $LASTEXITCODE
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "reg import failed (code $code)" }
    return ("Registry applied to {0}" -f $ad.Name)
}

function Do-Tcp {
    $cmds = @(
        'int tcp set global autotuninglevel=normal', 'int tcp set global rss=enabled', 'int tcp set global rsc=disabled',
        'int tcp set global ecncapability=disabled', 'int tcp set global timestamps=disabled', 'int tcp set global initialRto=2000',
        'int tcp set global nonsackrttresiliency=disabled', 'int tcp set heuristics disabled', 'int tcp set global dca=enabled'
    )
    foreach ($c in $cmds) { & netsh.exe ($c -split ' ') 2>&1 | Out-Null }
    # Local Group Policy (gpedit.msc) equivalents written straight to the policy keys
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0              # QoS: limit reservable bandwidth = 0%
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0                    # disable Game DVR
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0     # no P2P update uploads
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
    $ad = Get-ActiveAdapter
    if ($ad) {
        $ip = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $ad.InterfaceGuid
        Set-Reg $ip 'TcpAckFrequency' 1; Set-Reg $ip 'TCPNoDelay' 1; Set-Reg $ip 'TcpDelAckTicks' 0
    }
    Start-Process -FilePath gpupdate.exe -ArgumentList '/force' -WindowStyle Hidden
    return 'TCP + Group Policy tweaks applied'
}

function Get-FiveMExes {
    $list = @{}
    $list['FiveM_GTAProcess.exe'] = $null
    Get-Process | Where-Object { $_.Name -like 'FiveM*GTAProcess*' } | ForEach-Object {
        $n = $_.Name + '.exe'
        $list[$n] = $_.Path
    }
    if (Test-Path $script:FiveApp) {
        Get-ChildItem -Path $script:FiveApp -Recurse -Depth 4 -Filter 'FiveM*GTAProcess.exe' -ErrorAction SilentlyContinue | ForEach-Object { $list[$_.Name] = $_.FullName }
    }
    return $list
}

function Do-Priority {
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $exes = Get-FiveMExes
    foreach ($e in $exes.GetEnumerator()) {
        $pk = Join-Path (Join-Path $ifeo $e.Key) 'PerfOptions'
        Set-Reg $pk 'CpuPriorityClass' 3     # High
        Set-Reg $pk 'IoPriority' 3           # High
        if ($e.Value) { Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $e.Value 'GpuPreference=2;' 'String' }
    }
    $live = 0
    Get-Process | Where-Object { $_.Name -like 'FiveM*GTAProcess*' } | ForEach-Object { try { $_.PriorityClass = 'High'; $live++ } catch {} }
    return ("Permanent High priority set for {0} exe ({1} running now)" -f $exes.Count, $live)
}

function Set-IniKey([string]$file, [string]$key, [string]$val) {
    $lines = @(Get-Content -Path $file -ErrorAction SilentlyContinue)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) { $lines[$i] = "$key=$val"; $found = $true }
    }
    if (-not $found) {
        $hasGame = $false
        foreach ($l in $lines) { if ($l -match '^\s*\[Game\]') { $hasGame = $true } }
        if (-not $hasGame) { $lines = @('[Game]') + $lines }
        $new = New-Object System.Collections.ArrayList
        $done = $false
        foreach ($l in $lines) {
            [void]$new.Add($l)
            if (-not $done -and $l -match '^\s*\[Game\]') { [void]$new.Add("$key=$val"); $done = $true }
        }
        $lines = $new.ToArray()
    }
    Set-Content -Path $file -Value $lines -Encoding ASCII
}

function Do-FiveMConfig {
    $ini = Join-Path $script:FiveApp 'CitizenFX.ini'
    if (-not (Test-Path $script:FiveApp)) { throw 'FiveM not found - launch FiveM once first' }
    if (-not (Test-Path $ini)) { Set-Content -Path $ini -Value '[Game]' -Encoding ASCII }
    if (-not (Test-Path ($ini + '.sr.bak'))) { Copy-Item $ini ($ini + '.sr.bak') -Force }
    Set-IniKey $ini 'UpdateChannel' 'production'
    Set-IniKey $ini 'DisableOSVersionCheck' '1'
    return 'CitizenFX.ini optimized (backup saved)'
}

function Do-Cache {
    $base = Join-Path $script:FiveApp 'data'
    if (Get-Process -Name 'FiveM*' -ErrorAction SilentlyContinue) { Log 'FiveM is running - locked files will be skipped' 'warn' }
    $freed = [double]0
    if (Test-Path $base) {
        $targets = 'cache\browser', 'cache\db', 'cache\priv', 'cache\servers', 'cache\unconfirmed', 'server-cache', 'server-cache-priv', 'nui-storage'
        foreach ($t in $targets) {
            $p = Join-Path $base $t
            if (Test-Path $p) {
                $sz = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                Remove-Item (Join-Path $p '*') -Recurse -Force -ErrorAction SilentlyContinue
                $freed += [double]$sz
            }
        }
    }
    & ipconfig.exe /flushdns 2>&1 | Out-Null
    Get-ChildItem $env:TEMP -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    return ("Cache cleaned: {0} MB freed, DNS flushed, temp cleared" -f [math]::Round($freed / 1MB, 1))
}

function Do-Ram {
    $before = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024
    foreach ($p in Get-Process) {
        if ($p.Name -like 'FiveM*' -or $p.Name -like 'GTA*') { continue }
        try { [void][SRNative]::EmptyWorkingSet($p.Handle) } catch {}
    }
    $r = [SRNative]::PurgeStandby()
    [GC]::Collect()
    Start-Sleep -Milliseconds 500
    $after = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024
    $gain = [math]::Round([math]::Max(0, $after - $before))
    return ("RAM cleaned: ~{0} MB freed (standby list: {1})" -f $gain, $r)
}

function Do-Restore {
    if (-not (Test-Path (Join-Path $script:BkDir 'original.done'))) { throw 'No backup found - nothing to restore' }
    Get-ChildItem $script:BkDir -Filter '*.reg' | ForEach-Object { & reg.exe import $_.FullName 2>&1 | Out-Null }
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    Get-ChildItem $ifeo -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'FiveM*GTAProcess*' } | ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -Name 'NonBestEffortLimit' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name 'DODownloadMode' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name 'PowerThrottlingOff' -ErrorAction SilentlyContinue
    $ad = Get-ActiveAdapter
    if ($ad) {
        $ip = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $ad.InterfaceGuid
        foreach ($n in 'TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks') { Remove-ItemProperty -Path $ip -Name $n -ErrorAction SilentlyContinue }
    }
    $bak = Join-Path $script:BkDir 'CitizenFX.ini.bak'
    if (Test-Path $bak) { Copy-Item $bak (Join-Path $script:FiveApp 'CitizenFX.ini') -Force }
    & netsh.exe int tcp set global autotuninglevel=normal rss=enabled 2>&1 | Out-Null
    return 'Original settings restored - reboot recommended'
}

# =====================================================================
#  network tweaker helpers
# =====================================================================
$script:twDefs = @(
    @{ N = 'DefaultReceiveWindow'; S = 'afd'; R = 65536 }, @{ N = 'DefaultSendWindow'; S = 'afd'; R = 65536 },
    @{ N = 'FastSendDatagramThreshold'; S = 'afd'; R = 16384 }, @{ N = 'FastCopyReceiveThreshold'; S = 'afd'; R = 16384 },
    @{ N = 'IgnorePushBitOnReceives'; S = 'afd'; R = 1 }, @{ N = 'DynamicSendBufferDisable'; S = 'afd'; R = 0 },
    @{ N = 'TcpAckFrequency'; S = 'if'; R = 1 }, @{ N = 'TCPNoDelay'; S = 'if'; R = 1 }, @{ N = 'TcpDelAckTicks'; S = 'if'; R = 0 },
    @{ N = 'TcpTimedWaitDelay'; S = 'tcp'; R = 30 }, @{ N = 'MaxUserPort'; S = 'tcp'; R = 65534 },
    @{ N = 'DefaultTTL'; S = 'tcp'; R = 64 }, @{ N = 'Tcp1323Opts'; S = 'tcp'; R = 0 }
)

function Get-TwPath($scope, $guid) {
    if ($scope -eq 'afd') { return 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' }
    if ($scope -eq 'tcp') { return 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' }
    return ('HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid)
}

function Get-AdvRec($p) {
    $dn = [string]$p.DisplayName
    $kw = [string]$p.RegistryKeyword
    $valid = @($p.ValidDisplayValues)
    $wantOff = ($dn -match '^Flow Control') -or ($dn -match 'Interrupt Moderation$') -or
    ($dn -match 'Energy[ -]?Efficient|Green Ethernet|Power Saving|Ultra Low Power|Gigabit Lite|Selective Suspend|Idle Power|Reduce Speed|Shutdown Wake|Wake on (Magic|Pattern)|Wake From|Large Send Offload|Jumbo|Advanced EEE|^EEE')
    if ($wantOff) { foreach ($o in 'Disabled', 'Off', 'Disable') { if ($valid -contains $o) { return $o } }; return $null }
    if ($dn -match 'Interrupt Moderation Rate') { if ($valid -contains 'Off') { return 'Off' }; return $null }
    if ($kw -eq '*ReceiveBuffers' -or $kw -eq '*TransmitBuffers') {
        $max = 0; $min = 0
        try { $max = [int]$p.NumericParameterMaxValue; $min = [int]$p.NumericParameterMinValue } catch {}
        if ($max -ge 512 -and $min -le 512 -and [int]$p.RegistryValue[0] -lt 512) { return '512' }
    }
    return $null
}

function Get-RssRec {
    $c = [Environment]::ProcessorCount
    $q = 1; if ($c -ge 8) { $q = 4 } elseif ($c -ge 4) { $q = 2 }
    $b = 0; if ($c -ge 8) { $b = 2 } elseif ($c -ge 4) { $b = 1 }
    return @{ Enabled = 'True'; NumberOfReceiveQueues = "$q"; BaseProcessorNumber = "$b"; MaxProcessors = "$q" }
}

$script:GlobalRec = [ordered]@{
    ReceiveSideScaling = 'Enabled'; ReceiveSegmentCoalescing = 'Disabled'; Chimney = 'Disabled'; TaskOffload = 'Enabled'
    NetworkDirect = 'Enabled'; NetworkDirectAcrossIPSubnets = 'Blocked'; PacketCoalescingFilter = 'Disabled'
}

function Apply-Rss([string]$name, $h) {
    $p = @{ Name = $name }
    if ($h.Enabled -ne '' -and $null -ne $h.Enabled) { $p['Enabled'] = ([string]$h.Enabled -match '^(True|Enabled|1)$') }
    foreach ($k in 'NumberOfReceiveQueues', 'BaseProcessorNumber', 'MaxProcessorNumber', 'MaxProcessors') {
        if ($h[$k] -match '^\d+$') { $p[$k] = [uint32]$h[$k] }
    }
    if ($h.Profile) { $p['Profile'] = [string]$h.Profile }
    Set-NetAdapterRss @p -ErrorAction SilentlyContinue
}

function Apply-Global($h) {
    $p = @{}
    foreach ($k in $h.Keys) { if ($h[$k]) { $p[$k] = [string]$h[$k] } }
    if ($p.Count) { Set-NetOffloadGlobalSetting @p -ErrorAction SilentlyContinue }
}

function Apply-NetRecommended($ad) {
    $name = $ad.Name
    try { Apply-Rss $name (Get-RssRec) } catch {}
    try { Apply-Global $script:GlobalRec } catch {}
    $n = 0
    foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $name -ErrorAction SilentlyContinue)) {
        $rec = Get-AdvRec $p
        if ($null -eq $rec) { continue }
        try {
            if (@($p.ValidDisplayValues).Count -gt 0) {
                if ($p.DisplayValue -ne $rec) { Set-NetAdapterAdvancedProperty -Name $name -DisplayName $p.DisplayName -DisplayValue $rec -NoRestart -ErrorAction Stop; $n++ }
            } else {
                Set-NetAdapterAdvancedProperty -Name $name -RegistryKeyword $p.RegistryKeyword -RegistryValue $rec -NoRestart -ErrorAction Stop; $n++
            }
        } catch {}
    }
    try { Set-NetAdapterPowerManagement -Name $name -AllowComputerToTurnOffDevice Disabled -WakeOnMagicPacket Disabled -WakeOnPattern Disabled -ErrorAction SilentlyContinue } catch {}
    foreach ($t in $script:twDefs) {
        Set-Reg (Get-TwPath $t.S $ad.InterfaceGuid) $t.N ([int]$t.R)
    }
    return $n
}

function Do-NetRecommended {
    $ad = Get-ActiveAdapter
    if (-not $ad) { throw 'No active network adapter found' }
    $n = Apply-NetRecommended $ad
    Restart-NetAdapter -Name $ad.Name -ErrorAction SilentlyContinue
    return ("Adapter {0}: {1} properties tuned, adapter restarted" -f $ad.Name, $n)
}

# =====================================================================
#  main window
# =====================================================================
$ms = New-Object System.IO.MemoryStream -ArgumentList (, [Convert]::FromBase64String($BgB64))
$bgImg = [System.Drawing.Image]::FromStream($ms)

$form = New-Object SRForm
$form.Text = 'ShadowReaper'
$form.ClientSize = New-Object System.Drawing.Size(1120, 680)
$form.StartPosition = 'CenterScreen'
$form.Bg = $bgImg
$form.ForeColor = [System.Drawing.Color]::White

$white = [System.Drawing.Color]::White
$gray = [System.Drawing.Color]::FromArgb(160, 160, 168)
$tr = [System.Drawing.Color]::Transparent

function New-Label($parent, $text, $x, $y, $w, $h, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Height = $h
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = $tr; $l.AutoSize = $false
    $parent.Controls.Add($l)
    return $l
}

function New-Fx($parent, $text, $x, $y, $w, $h, $font) {
    $b = New-Object FxButton
    $b.Text = $text; $b.Left = $x; $b.Top = $y; $b.Width = $w; $b.Height = $h; $b.Font = $font
    $parent.Controls.Add($b)
    return $b
}

# =====================================================================
#  LICENSE SYSTEM  (hardware-bound, signed keys)
# =====================================================================
$script:LicPubX = 'tnXQo3DtVVrLQd5+PvgLKFYCqBrP4YZwbxbeKu/7DZU='
$script:LicPubY = 'Qn78gZlQdhM56tf99pfTq7aWLCcaLe0qIHVDZfLmn1U='
$script:B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
$script:LicS1 = '2HV/03qbi7VuCUMjZcw1P4'
$script:LicS2 = 'bcULpRilCjiaq+U9AbFZQ='
$script:HwIdCache = $null
$script:licOk = $false
$script:licChecked = $null
$script:licInfo = ''
$script:licFile = Join-Path $env:ProgramData 'ShadowReaper\license.key'

function From-B32([string]$s) {
    $out = New-Object System.Collections.Generic.List[byte]
    $val = 0; $bits = 0
    foreach ($ch in $s.ToCharArray()) {
        $i = $script:B32.IndexOf($ch)
        if ($i -lt 0) { continue }
        $val = ($val -shl 5) -bor $i; $bits += 5
        if ($bits -ge 8) { $out.Add([byte](($val -shr ($bits - 8)) -band 255)); $bits -= 8; $val = $val -band ((1 -shl $bits) - 1) }
    }
    return , $out.ToArray()
}

function To-B32([byte[]]$b) {
    $sb = New-Object System.Text.StringBuilder; $val = 0; $bits = 0
    foreach ($x in $b) {
        $val = ($val -shl 8) -bor $x; $bits += 8
        while ($bits -ge 5) { [void]$sb.Append($script:B32[($val -shr ($bits - 5)) -band 31]); $bits -= 5 }
        $val = $val -band ((1 -shl $bits) - 1)
    }
    if ($bits -gt 0) { [void]$sb.Append($script:B32[($val -shl (5 - $bits)) -band 31]) }
    return $sb.ToString()
}

function Get-ShortMac([string]$hwid, [string]$code) {
    $hm = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, [Convert]::FromBase64String($script:LicS1 + $script:LicS2))
    $h = $hm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("SR2|$hwid|$code"))
    return (To-B32 ([byte[]]$h[0..9]))
}

function Get-HwId {
    if ($script:HwIdCache) { return $script:HwIdCache }
    $bad = 'To be filled|Default string|None|N/A|Not Applicable|123456789|System Serial|Unknown'
    $parts = @()
    try { $u = [string](Get-CimInstance Win32_ComputerSystemProduct).UUID; if ($u -and $u -notmatch '^[0F-]+$' -and $u -notmatch $bad) { $parts += "U:$u" } } catch {}
    try { $c = [string](Get-CimInstance Win32_Processor | Select-Object -First 1).ProcessorId; if ($c -and $c -notmatch '^0+$') { $parts += "C:$c" } } catch {}
    try { $b = [string](Get-CimInstance Win32_BaseBoard | Select-Object -First 1).SerialNumber; if ($b -and $b.Trim() -and $b -notmatch $bad -and $b -notmatch '^0+$') { $parts += "B:$($b.Trim())" } } catch {}
    if ($parts.Count -lt 2) {
        try { $m = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction Stop).MachineGuid; if ($m) { $parts += "M:$m" } } catch {}
    }
    $raw = ($parts -join '|').ToUpper()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('SR-HWID|' + $raw))
    $hex = ([BitConverter]::ToString($h) -replace '-', '').Substring(0, 20)
    $script:HwIdCache = ($hex.Substring(0, 5) + '-' + $hex.Substring(5, 5) + '-' + $hex.Substring(10, 5) + '-' + $hex.Substring(15, 5))
    return $script:HwIdCache
}

function Test-Sig([byte[]]$data, [byte[]]$sig) {
    $x = [Convert]::FromBase64String($script:LicPubX); $y = [Convert]::FromBase64String($script:LicPubY)
    try {
        $p = New-Object System.Security.Cryptography.ECParameters
        $p.Curve = [System.Security.Cryptography.ECCurve+NamedCurves]::nistP256
        $q = New-Object System.Security.Cryptography.ECPoint
        $q.X = $x; $q.Y = $y; $p.Q = $q
        $ec = [System.Security.Cryptography.ECDsa]::Create($p)
        return [bool]$ec.VerifyData($data, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    } catch {
        $blob = [byte[]]((0x45, 0x43, 0x53, 0x31, 32, 0, 0, 0) + $x + $y)
        $key = [System.Security.Cryptography.CngKey]::Import($blob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $ec = New-Object System.Security.Cryptography.ECDsaCng -ArgumentList $key
        return [bool]$ec.VerifyData($data, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    }
}

function Test-LicenseKey([string]$key, [string]$hwid) {
    $k = ($key -replace '\s', '').ToUpper()
    $flat = $k -replace '-', ''
    if ($k -match '^[A-Z2-7]{5}(-[A-Z2-7]{5}){3}$') {
        $code = $flat.Substring(0, 4); $mac = $flat.Substring(4, 16)
        if ((Get-ShortMac $hwid $code) -ne $mac) { return @{ Ok = $false; Msg = 'Key does not match this PC' } }
        $n = 0
        foreach ($ch in $code.ToCharArray()) { $n = ($n * 32) + $script:B32.IndexOf($ch) }
        if ($n -eq 0) { return @{ Ok = $true; Msg = 'OK'; Info = 'Lifetime' } }
        $d = ([datetime]'2026-01-01').AddDays($n - 1)
        if ((Get-Date) -gt $d.AddDays(1)) { return @{ Ok = $false; Msg = 'Key expired on ' + $d.ToString('yyyy-MM-dd') } }
        return @{ Ok = $true; Msg = 'OK'; Info = 'Expires ' + $d.ToString('yyyy-MM-dd') }
    }
    if ($k -match '^SR-(\d{8})-([A-Z2-7-]+)$') { $exp = $matches[1]; $sigTxt = $matches[2] -replace '-', '' }
    else { return @{ Ok = $false; Msg = 'Invalid key format' } }
    $sig = From-B32 $sigTxt
    if ($sig.Length -ne 64) { return @{ Ok = $false; Msg = 'Invalid key' } }
    $data = [System.Text.Encoding]::UTF8.GetBytes("SR1|$hwid|$exp")
    $ok = $false
    try { $ok = Test-Sig $data $sig } catch { return @{ Ok = $false; Msg = 'Cannot verify key on this system' } }
    if (-not $ok) { return @{ Ok = $false; Msg = 'Key does not match this PC' } }
    if ($exp -ne '00000000') {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($exp, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return @{ Ok = $false; Msg = 'Invalid key' } }
        if ((Get-Date) -gt $d.AddDays(1)) { return @{ Ok = $false; Msg = 'Key expired on ' + $d.ToString('yyyy-MM-dd') } }
        return @{ Ok = $true; Msg = 'OK'; Info = 'Expires ' + $d.ToString('yyyy-MM-dd') }
    }
    return @{ Ok = $true; Msg = 'OK'; Info = 'Lifetime' }
}

function Test-Licensed {
    if ($script:licChecked -and ((Get-Date) - $script:licChecked).TotalMinutes -lt 10) { return $script:licOk }
    $ok = $false
    try {
        if (Test-Path $script:licFile) {
            $r = Test-LicenseKey (Get-Content $script:licFile -Raw) (Get-HwId)
            $ok = $r.Ok; if ($ok) { $script:licInfo = $r.Info }
        }
    } catch {}
    $script:licOk = $ok; $script:licChecked = Get-Date
    return $ok
}

function Show-License {
    $hw = Get-HwId
    $script:lf = New-Object SRForm
    $script:lf.ClientSize = New-Object System.Drawing.Size(760, 500)
    $script:lf.StartPosition = 'CenterScreen'
    $script:lf.Bg = $bgImg
    $script:lf.ForeColor = $white
    $t1 = New-Label $script:lf 'SHADOWREAPER' 24 10 400 40 $fTitle $white
    $t2 = New-Label $script:lf 'LICENSE ACTIVATION' 28 48 400 18 $fSmall $gray
    $dg = { [SRNative]::DragWindow($script:lf.Handle) }
    $t1.Add_MouseDown($dg); $t2.Add_MouseDown($dg); $script:lf.Add_MouseDown($dg)
    $xb = New-Fx $script:lf 'X' 700 14 38 30 $fBtn
    $xb.Add_Click({ $script:lf.DialogResult = 'Cancel'; $script:lf.Close() })

    $gp = New-Object GlassPanel
    $gp.SetBounds(24, 84, 712, 392); $gp.Alpha = 175
    $script:lf.Controls.Add($gp)

    $null = New-Label $gp 'YOUR HARDWARE ID' 28 22 400 20 $fSmall $gray
    $null = New-Label $gp $hw 28 46 440 34 $fBig $white
    $bc = New-Fx $gp 'COPY' 560 46 120 36 $fSmall
    $bc.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText((Get-HwId)); Toast 'ShadowReaper' 'Hardware ID copied' 1 } catch { Toast 'ShadowReaper' 'Copy failed' 3 } })
    $null = New-Label $gp 'Send this ID to the seller on Discord to receive your license key.' 28 90 650 20 $fSmall $gray

    $null = New-Label $gp 'LICENSE KEY' 28 132 400 20 $fSmall $gray
    $script:licBox = New-Object System.Windows.Forms.TextBox
    $script:licBox.SetBounds(28, 156, 652, 96); $script:licBox.Multiline = $true; $script:licBox.Font = $fMono
    $script:licBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34); $script:licBox.ForeColor = $white
    $script:licBox.BorderStyle = 'FixedSingle'; $script:licBox.ScrollBars = 'None'
    $gp.Controls.Add($script:licBox)
    $script:licMsg = New-Label $gp '' 28 262 652 22 $fBody $gray

    $ba = New-Fx $gp 'ACTIVATE' 28 304 220 50 $fBtn
    $ba.Accent = $true
    $bd = New-Fx $gp 'GET A KEY (DISCORD)' 262 304 260 50 $fSmall
    $bd.Add_Click({ Start-Process $Discord })
    $ba.Add_Click({
        try {
            $r = Test-LicenseKey $script:licBox.Text (Get-HwId)
            if ($r.Ok) {
                $d = Split-Path $script:licFile
                if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
                Set-Content -Path $script:licFile -Value (($script:licBox.Text -replace '\s', '').ToUpper()) -Encoding ASCII
                $script:licOk = $true; $script:licChecked = Get-Date; $script:licInfo = $r.Info
                Toast 'ShadowReaper' 'License activated' 1
                Pump 500
                $script:lf.DialogResult = 'OK'; $script:lf.Close()
            } else {
                $script:licMsg.Text = $r.Msg; $script:licMsg.ForeColor = [System.Drawing.Color]::IndianRed
                Toast 'ShadowReaper' $r.Msg 3
            }
        } catch { Log-Err $_; Toast 'ShadowReaper' 'Activation failed' 3 }
    })
    $res = $script:lf.ShowDialog()
    return ($res -eq 'OK')
}

if (-not (Test-Licensed)) {
    if (-not (Show-License)) { return }
}

# ---- title bar ----
$title = New-Label $form 'SHADOWREAPER' 24 10 300 40 $fTitle $white
$sub = New-Label $form 'FIVEM  PERFORMANCE  SUITE' 28 48 300 18 $fSmall $gray
$dragH = { [SRNative]::DragWindow($form.Handle) }
$title.Add_MouseDown($dragH); $sub.Add_MouseDown($dragH); $form.Add_MouseDown($dragH)
$btnMin = New-Fx $form '_' 1020 14 38 30 $fBtn
$btnClose = New-Fx $form 'X' 1064 14 38 30 $fBtn
$btnMin.Add_Click({ $form.WindowState = 'Minimized' })
$btnClose.Add_Click({ $form.Close() })

# ---- sidebar ----
$side = New-Object GlassPanel
$side.SetBounds(16, 68, 252, 596); $side.Alpha = 175
$form.Controls.Add($side)

$items = @(
    @('FIVEM BOOST', 'boost'), @('NETWORK TWEAKER', 'net'), @('FILTERKEYS SETTER', 'fk'), @('TCP OPTIMIZER', 'tcpopt'),
    @('FILE ANALYZER', 'ana'), @('TIMER RESOLUTION', 'timer')
)
$script:sideBtns = @()
$y = 16
foreach ($it in $items) {
    $b = New-Fx $side $it[0] 14 $y 224 52 $fBtn
    $b.LeftAlign = $true; $b.Tag = $it[1]
    if ($it[1] -eq 'boost') { $b.Accent = $true }
    $script:sideBtns += $b
    $y += 62
}
$btnDisc = New-Fx $side 'JOIN DISCORD' 14 520 224 44 $fBtn
$btnDisc.Add_Click({ Start-Process $Discord })
$null = New-Label $side ([string][char]0x00A9 + ' 2026 ShadowReaper') 14 570 224 18 $fSmall $gray

# ---- pages ----
function New-Page { $p = New-Object GlassPanel; $p.SetBounds(284, 68, 820, 596); $p.Alpha = 165; $p.Visible = $false; $form.Controls.Add($p); return $p }
$pgHome = New-Page; $pgNet = New-Page; $pgFk = New-Page; $pgTcp = New-Page; $pgAna = New-Page; $pgTimer = New-Page

function Show-Page($which) {
    $pgHome.Visible = ($which -eq 'home'); $pgNet.Visible = ($which -eq 'net'); $pgFk.Visible = ($which -eq 'fk'); $pgTcp.Visible = ($which -eq 'tcpopt'); $pgAna.Visible = ($which -eq 'ana'); $pgTimer.Visible = ($which -eq 'timer')
}

# home page (status only - details are hidden, progress + toasts only)
$script:hdr = New-Label $pgHome 'READY' 36 36 600 60 $fTitle $white
$null = New-Label $pgHome 'Press RUN to optimize everything in one click.' 40 100 740 22 $fBody $gray
$script:info = New-Label $pgHome '' 40 126 740 20 $fSmall $gray
$script:progBack = New-Object System.Windows.Forms.Panel
$script:progBack.SetBounds(40, 170, 740, 8); $script:progBack.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 46)
$script:progFill = New-Object System.Windows.Forms.Panel
$script:progFill.SetBounds(0, 0, 0, 8); $script:progFill.BackColor = $white
$script:progBack.Controls.Add($script:progFill); $pgHome.Controls.Add($script:progBack)
$btnRun = New-Fx $pgHome 'RUN' 40 214 360 72 $fBig
$btnRun.Accent = $true
$btnRun.Add_Click({ Invoke-Action 'run' })
$btnRestore = New-Fx $pgHome 'RESTORE ORIGINAL' 40 520 220 44 $fBtn
$btnRestore.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try { $null = Do-Restore; Toast 'ShadowReaper' 'Restored - reboot recommended' 1 }
    catch { Log-Err $_; Toast 'ShadowReaper' 'Nothing to restore' 2 }
    finally { $script:busy = $false }
})
# hidden log sink (kept for debugging, never shown)
$script:rtb = New-Object System.Windows.Forms.RichTextBox
$script:rtb.Visible = $false
$pgHome.Controls.Add($script:rtb)

# =====================================================================
#  network tweaker page
# =====================================================================
$script:ui = $null
$script:netBuilt = $false

function New-Combo($parent, $x, $y, $w, $values, [bool]$editable) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.SetBounds($x, $y, $w, 24); $c.Font = $fSmall; $c.FlatStyle = 'Flat'
    $c.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34); $c.ForeColor = $white
    if ($editable) { $c.DropDownStyle = 'DropDown' } else { $c.DropDownStyle = 'DropDownList' }
    foreach ($v in @($values)) { [void]$c.Items.Add([string]$v) }
    $parent.Controls.Add($c)
    return $c
}

function Add-Group($parent, $text, $x, [ref]$y) {
    $l = New-Label $parent $text $x $y.Value 365 22 $fBtn $white
    $ln = New-Object System.Windows.Forms.Panel
    $ln.SetBounds($x, $y.Value + 24, 365, 1); $ln.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 96)
    $parent.Controls.Add($ln)
    $y.Value += 34
}

function Add-Row($parent, $label, $x, [ref]$y, $values, $current, [bool]$editable) {
    $null = New-Label $parent $label $x ($y.Value + 3) 190 20 $fSmall ([System.Drawing.Color]::FromArgb(215, 215, 220))
    $c = New-Combo $parent ($x + 195) $y.Value 165 $values $editable
    $cur = [string]$current
    if ($c.DropDownStyle -eq 'DropDownList') {
        $i = $c.FindStringExact($cur); if ($i -ge 0) { $c.SelectedIndex = $i }
    } else { $c.Text = $cur }
    $y.Value += 28
    return $c
}

function Build-NetUi {
    $p = $script:netScroll
    $p.SuspendLayout()
    while ($p.Controls.Count) { $p.Controls[0].Dispose() }
    $name = $script:cbAdapter.Text
    $ad = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
    $script:ui = @{ Rss = @{}; Glob = @{}; Adv = @{}; Pow = @{}; Tw = @{}; Msi = $null }
    if (-not $ad) { $p.ResumeLayout(); return }
    $guid = [string]$ad.InterfaceGuid
    $cores = [Environment]::ProcessorCount
    $cpuList = 0..($cores - 1)
    $x1 = 6; $x2 = 396; $y1 = 4; $y2 = 4

    # RSS
    Add-Group $p 'RSS SETTINGS' $x1 ([ref]$y1)
    $r = Get-NetAdapterRss -Name $name -ErrorAction SilentlyContinue
    $script:ui.Rss['Enabled'] = Add-Row $p 'Status' $x1 ([ref]$y1) @('True', 'False') $r.Enabled $false
    $script:ui.Rss['NumberOfReceiveQueues'] = Add-Row $p 'NumberOfReceiveQueues' $x1 ([ref]$y1) @(1, 2, 3, 4, 6, 8, 16) $r.NumberOfReceiveQueues $true
    $script:ui.Rss['Profile'] = Add-Row $p 'Profile' $x1 ([ref]$y1) @('Closest', 'ClosestStatic', 'NUMA', 'NUMAStatic', 'Conservative') $r.Profile $true
    $script:ui.Rss['BaseProcessorNumber'] = Add-Row $p 'BaseProcessor' $x1 ([ref]$y1) $cpuList $r.BaseProcessorNumber $true
    $script:ui.Rss['MaxProcessorNumber'] = Add-Row $p 'MaxProcessor' $x1 ([ref]$y1) $cpuList $r.MaxProcessorNumber $true
    $script:ui.Rss['MaxProcessors'] = Add-Row $p 'MaxProcessors' $x1 ([ref]$y1) $cpuList $r.MaxProcessors $true
    $y1 += 10

    # Global
    Add-Group $p 'GLOBAL SETTINGS' $x1 ([ref]$y1)
    $g = Get-NetOffloadGlobalSetting -ErrorAction SilentlyContinue
    $gv = @{
        ReceiveSideScaling = @('Enabled', 'Disabled'); ReceiveSegmentCoalescing = @('Enabled', 'Disabled'); Chimney = @('Disabled', 'Enabled', 'Automatic')
        TaskOffload = @('Enabled', 'Disabled'); NetworkDirect = @('Enabled', 'Disabled'); NetworkDirectAcrossIPSubnets = @('Allowed', 'Blocked'); PacketCoalescingFilter = @('Enabled', 'Disabled')
    }
    foreach ($k in $script:GlobalRec.Keys) { $script:ui.Glob[$k] = Add-Row $p $k $x1 ([ref]$y1) $gv[$k] $g.$k $false }
    $y1 += 10

    # Power saving
    Add-Group $p 'POWER SAVING' $x1 ([ref]$y1)
    $pm = Get-NetAdapterPowerManagement -Name $name -ErrorAction SilentlyContinue
    foreach ($k in 'AllowComputerToTurnOffDevice', 'WakeOnMagicPacket', 'WakeOnPattern') {
        if ($pm -and [string]$pm.$k -and [string]$pm.$k -ne 'Unsupported') { $script:ui.Pow[$k] = Add-Row $p $k $x1 ([ref]$y1) @('Enabled', 'Disabled') $pm.$k $false }
    }
    $msiPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $ad.PnPDeviceID + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
    $msiCur = ''
    $mv = Get-ItemProperty -Path $msiPath -Name MSISupported -ErrorAction SilentlyContinue
    if ($mv) { if ($mv.MSISupported -eq 1) { $msiCur = 'Enabled' } else { $msiCur = 'Disabled' } }
    $script:ui.Msi = @{ Path = $msiPath; Combo = (Add-Row $p 'MSI Mode (reboot)' $x1 ([ref]$y1) @('Enabled', 'Disabled') $msiCur $false); Orig = $msiCur }

    # Advanced adapter
    Add-Group $p 'ADV. ADAPTER' $x2 ([ref]$y2)
    foreach ($ap in @(Get-NetAdapterAdvancedProperty -Name $name -ErrorAction SilentlyContinue)) {
        $valid = @($ap.ValidDisplayValues)
        $cur = [string]$ap.DisplayValue
        $label = [string]$ap.DisplayName
        if ($valid.Count -gt 0) { $c = Add-Row $p $label $x2 ([ref]$y2) $valid $cur $false }
        else { $c = Add-Row $p $label $x2 ([ref]$y2) @() $cur $true }
        $script:ui.Adv[[string]$ap.RegistryKeyword] = @{ Combo = $c; Prop = $ap; List = ($valid.Count -gt 0); Orig = $cur }
    }
    $y2 += 10

    # Tweaks (registry)
    Add-Group $p 'TWEAKS' $x2 ([ref]$y2)
    foreach ($t in $script:twDefs) {
        $pth = Get-TwPath $t.S $guid
        $cv = (Get-ItemProperty -Path $pth -Name $t.N -ErrorAction SilentlyContinue).($t.N)
        $curS = ''; if ($null -ne $cv) { $curS = [string]$cv }
        $script:ui.Tw[$t.N] = @{ Combo = (Add-Row $p $t.N $x2 ([ref]$y2) @($t.R) $curS $true); Def = $t; Orig = $curS }
    }
    $sp = New-Label $p '' 0 ([Math]::Max($y1, $y2) + 10) 10 10 $fSmall $gray
    $p.ResumeLayout()
}

function Fill-NetRecommended {
    if (-not $script:ui) { return }
    $rr = Get-RssRec
    foreach ($k in $rr.Keys) { $c = $script:ui.Rss[$k]; if ($c) { $c.Text = $rr[$k] } }
    foreach ($k in $script:GlobalRec.Keys) { $c = $script:ui.Glob[$k]; if ($c) { $i = $c.FindStringExact($script:GlobalRec[$k]); if ($i -ge 0) { $c.SelectedIndex = $i } } }
    foreach ($k in 'AllowComputerToTurnOffDevice', 'WakeOnMagicPacket', 'WakeOnPattern') {
        $c = $script:ui.Pow[$k]; if ($c) { $i = $c.FindStringExact('Disabled'); if ($i -ge 0) { $c.SelectedIndex = $i } }
    }
    foreach ($kv in $script:ui.Adv.GetEnumerator()) {
        $rec = Get-AdvRec $kv.Value.Prop
        if ($null -ne $rec) {
            if ($kv.Value.List) { $i = $kv.Value.Combo.FindStringExact($rec); if ($i -ge 0) { $kv.Value.Combo.SelectedIndex = $i } } else { $kv.Value.Combo.Text = $rec }
        }
    }
    foreach ($kv in $script:ui.Tw.GetEnumerator()) { $kv.Value.Combo.Text = [string]$kv.Value.Def.R }
}

function Apply-NetUi {
    if (-not $script:ui) { return 0 }
    $name = $script:cbAdapter.Text
    $ad = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
    if (-not $ad) { throw 'Select an adapter first' }
    $n = 0
    $rss = @{}; foreach ($k in $script:ui.Rss.Keys) { $rss[$k] = $script:ui.Rss[$k].Text }
    try { Apply-Rss $name $rss } catch { Log-Err $_ }
    $gl = @{}; foreach ($k in $script:ui.Glob.Keys) { $gl[$k] = $script:ui.Glob[$k].Text }
    try { Apply-Global $gl } catch { Log-Err $_ }
    foreach ($kv in $script:ui.Adv.GetEnumerator()) {
        $v = $kv.Value; $new = $v.Combo.Text
        if ($new -ne $v.Orig -and $new -ne '') {
            try {
                if ($v.List) { Set-NetAdapterAdvancedProperty -Name $name -DisplayName $v.Prop.DisplayName -DisplayValue $new -NoRestart -ErrorAction Stop }
                else { Set-NetAdapterAdvancedProperty -Name $name -RegistryKeyword $kv.Key -RegistryValue $new -NoRestart -ErrorAction Stop }
                $n++
            } catch { Log ("  skip {0}: {1}" -f $v.Prop.DisplayName, $_.Exception.Message) 'warn' }
        }
    }
    $pp = @{ Name = $name }
    foreach ($k in $script:ui.Pow.Keys) { $pp[$k] = $script:ui.Pow[$k].Text }
    if ($pp.Count -gt 1) { try { Set-NetAdapterPowerManagement @pp -ErrorAction Stop } catch { Log-Err $_ } }
    foreach ($kv in $script:ui.Tw.GetEnumerator()) {
        $txt = $kv.Value.Combo.Text.Trim()
        if ($txt -match '^\d+$' -and $txt -ne $kv.Value.Orig) { try { Set-Reg (Get-TwPath $kv.Value.Def.S $ad.InterfaceGuid) $kv.Key ([int]$txt); $n++ } catch { Log-Err $_ } }
    }
    $m = $script:ui.Msi
    if ($m -and $m.Combo.Text -and $m.Combo.Text -ne $m.Orig) {
        try { if ($m.Combo.Text -eq 'Enabled') { Set-Reg $m.Path 'MSISupported' 1 } else { Set-Reg $m.Path 'MSISupported' 0 }; $n++ } catch { Log-Err $_ }
    }
    return $n
}

function Init-Net {
    $script:cbAdapter.Items.Clear()
    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) { [void]$script:cbAdapter.Items.Add($a.Name) }
    $act = Get-ActiveAdapter
    if ($act) { $i = $script:cbAdapter.FindStringExact($act.Name); if ($i -ge 0) { $script:cbAdapter.SelectedIndex = $i } }
    elseif ($script:cbAdapter.Items.Count) { $script:cbAdapter.SelectedIndex = 0 }
    Build-NetUi
    $script:netBuilt = $true
}

$null = New-Label $pgNet 'ADAPTER' 16 20 70 20 $fSmall $white
$script:cbAdapter = New-Combo $pgNet 82 16 190 @() $false
$bNOpen = New-Fx $pgNet 'OPEN' 280 12 62 32 $fSmall
$bNRef = New-Fx $pgNet 'REFRESH' 346 12 76 32 $fSmall
$bNRec = New-Fx $pgNet 'RECOMMENDED' 426 12 124 32 $fSmall
$bNApp = New-Fx $pgNet 'APPLY ALL' 554 12 96 32 $fSmall
$bNRst = New-Fx $pgNet 'RESTART ADAPTER' 654 12 156 32 $fSmall
$bNRec.Accent = $true; $bNApp.Accent = $true
$script:netScroll = New-Object System.Windows.Forms.Panel
$script:netScroll.SetBounds(12, 56, 796, 530)
$script:netScroll.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 14); $script:netScroll.AutoScroll = $true; $script:netScroll.HorizontalScroll.Visible = $false
$pgNet.Controls.Add($script:netScroll)

$bNOpen.Add_Click({ Start-Process 'ncpa.cpl' })
$bNRef.Add_Click({ if (-not $script:busy) { $script:busy = $true; try { Init-Net; Toast 'ShadowReaper' 'Reloaded' 0 } finally { $script:busy = $false } } })
$script:cbAdapter.Add_SelectionChangeCommitted({ if ($script:netBuilt -and -not $script:busy) { Build-NetUi } })
$bNRec.Add_Click({ Fill-NetRecommended; Toast 'ShadowReaper' 'Recommended values loaded' 0 })
$bNApp.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try { $n = Apply-NetUi; Toast 'ShadowReaper' 'Applied' 1 }
    catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
    finally { $script:busy = $false }
})
$bNRst.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try {
        Toast 'ShadowReaper' 'Restarting adapter...' 0
        Restart-NetAdapter -Name $script:cbAdapter.Text -ErrorAction Stop
        Toast 'ShadowReaper' 'Done' 1
        Build-NetUi
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
    finally { $script:busy = $false }
})

# =====================================================================
#  small control helpers
# =====================================================================
$darkBg = [System.Drawing.Color]::FromArgb(12, 12, 14)
$fieldBg = [System.Drawing.Color]::FromArgb(30, 30, 34)
$soft = [System.Drawing.Color]::FromArgb(215, 215, 220)

function New-Chk($parent, $text, $x, $y, $w) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.SetBounds($x, $y, $w, 24); $c.Font = $fBody; $c.ForeColor = $white; $c.BackColor = $tr
    $parent.Controls.Add($c); return $c
}
function New-Rad($parent, $text, $x, $y, $w) {
    $c = New-Object System.Windows.Forms.RadioButton
    $c.Text = $text; $c.SetBounds($x, $y, $w, 24); $c.Font = $fBody; $c.ForeColor = $white; $c.BackColor = $tr
    $parent.Controls.Add($c); return $c
}
function New-Txt($parent, $x, $y, $w, $text) {
    $c = New-Object System.Windows.Forms.TextBox
    $c.SetBounds($x, $y, $w, 24); $c.Font = $fBody; $c.BackColor = $fieldBg; $c.ForeColor = $white
    $c.BorderStyle = 'FixedSingle'; $c.Text = $text
    $parent.Controls.Add($c); return $c
}

# =====================================================================
#  FILTERKEYS SETTER
# =====================================================================
$script:fkOrig = [SRNative]::GetFK()
$script:fk = @{}
$null = New-Label $pgFk 'FILTERKEYS SETTER' 36 20 700 44 $fBig $white
$null = New-Label $pgFk 'SETTINGS' 40 76 300 22 $fBtn $white
$script:fk['Rad1'] = New-Rad $pgFk 'Ignore quick keystrokes and/or set the repeat rate' 40 106 460
$null = New-Label $pgFk 'Ignore under' 76 142 120 22 $fBody $soft
$script:fk['Wait'] = New-Txt $pgFk 210 140 80 '0'
$null = New-Label $pgFk 'Repeat delay' 76 176 120 22 $fBody $soft
$script:fk['Delay'] = New-Txt $pgFk 210 174 80 '150'
$null = New-Label $pgFk 'Repeat rate' 76 210 120 22 $fBody $soft
$script:fk['Rep'] = New-Txt $pgFk 210 208 80 '1'
foreach ($yy in 142, 176, 210) { $null = New-Label $pgFk 'ms' 298 $yy 40 22 $fBody $gray }
$script:fk['Rad2'] = New-Rad $pgFk 'Ignore keystrokes repeated faster than:' 40 252 460
$script:fk['Bounce'] = New-Txt $pgFk 210 284 80 '0'
$null = New-Label $pgFk 'ms' 298 286 40 22 $fBody $gray

$null = New-Label $pgFk 'FLAGS' 540 76 200 22 $fBtn $white
$fkFlags = @(@('On', 'On', 1), @('Avail', 'Available', 2), @('Hot', 'Use shortcut', 4), @('Confirm', 'Confirm activation', 8), @('Sound', 'Activation sound', 16), @('Status', 'Show status', 32), @('Click', 'Key click', 64))
$yy = 106
foreach ($f in $fkFlags) { $script:fk[$f[0]] = New-Chk $pgFk $f[1] 540 $yy 220; $yy += 28 }
$null = New-Label $pgFk 'WHEN APPLIED' 540 316 200 22 $fBtn $white
$script:fk['Save'] = New-Chk $pgFk 'Save to registry' 540 344 220
$script:fk['Broad'] = New-Chk $pgFk 'Broadcast change' 540 372 220
$script:fk['Save'].Checked = $true; $script:fk['Broad'].Checked = $true

function Load-FK($v) {
    $f = [uint32]$v[0]
    foreach ($x in $fkFlags) { $script:fk[$x[0]].Checked = [bool]($f -band $x[2]) }
    if ([uint32]$v[4] -gt 0) {
        $script:fk['Rad2'].Checked = $true
        $script:fk['Bounce'].Text = [string]$v[4]
        $script:fk['Wait'].Text = '0'; $script:fk['Delay'].Text = '0'; $script:fk['Rep'].Text = '0'
    } else {
        $script:fk['Rad1'].Checked = $true
        $script:fk['Wait'].Text = [string]$v[1]; $script:fk['Delay'].Text = [string]$v[2]; $script:fk['Rep'].Text = [string]$v[3]
        $script:fk['Bounce'].Text = '0'
    }
}

function Apply-FK {
    $flags = [uint32]0
    foreach ($x in $fkFlags) { if ($script:fk[$x[0]].Checked) { $flags = $flags -bor [uint32]$x[2] } }
    $wait = [uint32]0; $delay = [uint32]0; $rep = [uint32]0; $bounce = [uint32]0
    if ($script:fk['Rad2'].Checked) { $bounce = [uint32]$script:fk['Bounce'].Text }
    else { $wait = [uint32]$script:fk['Wait'].Text; $delay = [uint32]$script:fk['Delay'].Text; $rep = [uint32]$script:fk['Rep'].Text }
    $wi = [uint32]0
    if ($script:fk['Save'].Checked) { $wi = $wi -bor 1 }
    if ($script:fk['Broad'].Checked) { $wi = $wi -bor 2 }
    if (-not [SRNative]::SetFK($flags, $wait, $delay, $rep, $bounce, $wi)) { throw 'SystemParametersInfo failed' }
}

$bx = 40
foreach ($d in @(@('CURRENT', 'cur'), @('REGISTRY', 'reg'), @('DEFAULT', 'def'), @('ORIGINAL', 'org'), @('PRESET', 'pre'))) {
    $b = New-Fx $pgFk $d[0] $bx 330 92 36 $fSmall
    $b.Tag = $d[1]
    $b.Add_Click({
        try {
            switch ([string]$this.Tag) {
                'cur' { Load-FK ([SRNative]::GetFK()) }
                'reg' {
                    $k = Get-ItemProperty 'HKCU:\Control Panel\Accessibility\Keyboard Response' -ErrorAction SilentlyContinue
                    if ($k) { Load-FK @([uint32]$k.Flags, [uint32]$k.DelayBeforeAcceptance, [uint32]$k.AutoRepeatDelay, [uint32]$k.AutoRepeatRate, [uint32]$k.BounceTime) }
                }
                'def' { Load-FK @([uint32]126, [uint32]1000, [uint32]1000, [uint32]500, [uint32]0) }
                'org' { Load-FK $script:fkOrig }
                'pre' { Load-FK @([uint32]3, [uint32]0, [uint32]150, [uint32]1, [uint32]0) }
            }
        } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
    })
    $bx += 98
}
$null = New-Label $pgFk 'TEST AREA (click APPLY first)' 40 392 400 22 $fBody $gray
$null = New-Txt $pgFk 40 418 740 ''
$bFkApply = New-Fx $pgFk 'APPLY' 580 524 200 46 $fBtn
$bFkApply.Accent = $true
$bFkApply.Add_Click({
    try { Apply-FK; Toast 'ShadowReaper' 'Applied' 1 }
    catch { Log-Err $_; Toast 'ShadowReaper' 'Failed - check the values' 3 }
})
Load-FK $script:fkOrig

# =====================================================================
#  TCP OPTIMIZER
# =====================================================================
$script:tcp = @{}
$script:tcpBuilt = $false
$script:tcpPanels = @{}
$null = New-Label $pgTcp 'TCP OPTIMIZER' 36 6 500 44 $fBig $white

function New-TPanel {
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds(12, 96, 796, 424); $p.BackColor = $darkBg; $p.Visible = $false
    $pgTcp.Controls.Add($p); return $p
}
$tpGen = New-TPanel; $tpAdv = New-TPanel; $tpBdp = New-TPanel; $tpMtu = New-TPanel
$script:tcpPanels = @{ gen = $tpGen; adv = $tpAdv; bdp = $tpBdp; mtu = $tpMtu }
$tx = 16
foreach ($d in @(@('GENERAL', 'gen'), @('ADVANCED', 'adv'), @('BDP', 'bdp'), @('MTU / LATENCY', 'mtu'))) {
    $b = New-Fx $pgTcp $d[0] $tx 52 180 36 $fSmall
    $b.Tag = $d[1]
    $b.Add_Click({
        $k = [string]$this.Tag
        foreach ($n in $script:tcpPanels.Keys) { $script:tcpPanels[$n].Visible = ($n -eq $k) }
        foreach ($c in $pgTcp.Controls) { if ($c -is [FxButton] -and $c.Tag -in 'gen', 'adv', 'bdp', 'mtu') { $c.Active = ($c.Tag -eq $k); $c.Invalidate() } }
    })
    $tx += 188
}

function New-TRow($parent, [string]$key, [string]$label, $x, $y, $values, [bool]$edit) {
    $null = New-Label $parent $label $x ($y + 3) 195 20 $fSmall $soft
    $script:tcp[$key] = New-Combo $parent ($x + 200) $y 170 $values $edit
}

# --- general ---
$null = New-Label $tpGen 'CONNECTION SPEED' 20 12 300 22 $fBtn $white
$script:tcpSpeedNames = @('56 kbps', '1 Mbps', '5 Mbps', '10 Mbps', '20 Mbps', '30 Mbps', '50 Mbps', '100+ Mbps')
$script:tcpSpeedVals = @(0.056, 1, 5, 10, 20, 30, 50, 100)
$script:tbSpeed = New-Object System.Windows.Forms.TrackBar
$script:tbSpeed.SetBounds(20, 38, 580, 40); $script:tbSpeed.Minimum = 0; $script:tbSpeed.Maximum = 7; $script:tbSpeed.TickFrequency = 1
$script:tbSpeed.BackColor = $darkBg; $script:tbSpeed.Value = 7
$tpGen.Controls.Add($script:tbSpeed)
$script:lblSpeed = New-Label $tpGen '100+ Mbps' 620 46 150 24 $fBtn $white
$script:tbSpeed.Add_ValueChanged({
    $script:lblSpeed.Text = $script:tcpSpeedNames[$script:tbSpeed.Value]
    if ($script:bdp -and $script:bdp['Speed']) { $script:bdp['Speed'].Text = [string]$script:tcpSpeedVals[$script:tbSpeed.Value] }
})
$null = New-Label $tpGen 'NETWORK ADAPTER' 20 92 200 22 $fBtn $white
$script:tcpAd = New-Combo $tpGen 220 90 360 @() $false
$yL = 150
New-TRow $tpGen 'auto' 'TCP Auto-Tuning' 20 $yL @('disabled', 'highlyrestricted', 'restricted', 'normal', 'experimental') $false
New-TRow $tpGen 'cc' 'Congestion Provider' 20 ($yL + 44) @('default', 'ctcp', 'dctcp', 'cubic') $false
New-TRow $tpGen 'rss' 'Receive-Side Scaling' 20 ($yL + 88) @('enabled', 'disabled') $false
New-TRow $tpGen 'rsc' 'Receive Seg. Coalescing' 20 ($yL + 132) @('enabled', 'disabled') $false
New-TRow $tpGen 'chk' 'Checksum Offloading' 410 $yL @('enabled', 'disabled') $false
New-TRow $tpGen 'lso' 'Large Send Offload' 410 ($yL + 44) @('enabled', 'disabled') $false
New-TRow $tpGen 'ts' 'TCP 1323 Timestamps' 410 ($yL + 88) @('enabled', 'disabled') $false
New-TRow $tpGen 'chim' 'Chimney Offload' 410 ($yL + 132) @('disabled', 'enabled', 'automatic') $false

# --- advanced ---
$null = New-Label $tpAdv 'ADVANCED SETTINGS' 20 12 400 22 $fBtn $white
New-TRow $tpAdv 'ecn' 'ECN Capability' 20 56 @('disabled', 'enabled') $false
New-TRow $tpAdv 'heur' 'Window Scaling Heuristics' 20 100 @('disabled', 'enabled') $false
New-TRow $tpAdv 'rto' 'Initial RTO (ms)' 20 144 @('1000', '2000', '3000') $true
New-TRow $tpAdv 'sack' 'Non-SACK RTT Resilience' 20 188 @('disabled', 'enabled') $false
New-TRow $tpAdv 'syn' 'Max SYN Retransmissions' 20 232 @('2', '3', '4') $true
New-TRow $tpAdv 'thr' 'Network Throttling Index' 410 56 @('disabled', '10', '20', '50') $true
New-TRow $tpAdv 'resp' 'System Responsiveness' 410 100 @('0', '10', '20') $true
New-TRow $tpAdv 'ttl' 'Default TTL' 410 144 @('64', '128') $true
New-TRow $tpAdv 'wait' 'TCP Timed Wait Delay' 410 188 @('30', '60', '120') $true
New-TRow $tpAdv 'port' 'Max User Port' 410 232 @('5000', '65534') $true

# --- BDP ---
$script:bdp = @{}
$null = New-Label $tpBdp 'BANDWIDTH-DELAY PRODUCT' 20 12 500 22 $fBtn $white
$null = New-Label $tpBdp 'Connection speed (Mbps)' 20 60 220 22 $fBody $soft
$script:bdp['Speed'] = New-Txt $tpBdp 250 58 100 '100'
$null = New-Label $tpBdp 'Latency (ms)' 20 100 220 22 $fBody $soft
$script:bdp['Lat'] = New-Txt $tpBdp 250 98 100 '30'
$null = New-Label $tpBdp 'Ping host' 20 140 220 22 $fBody $soft
$script:bdp['Host'] = New-Txt $tpBdp 250 138 160 '1.1.1.1'
$script:bdp['Res'] = New-Label $tpBdp '' 20 200 760 26 $fBtn $white
$bBdpPing = New-Fx $tpBdp 'PING' 440 134 110 34 $fSmall
$bBdpCalc = New-Fx $tpBdp 'CALCULATE' 20 250 160 40 $fSmall
$bBdpApply = New-Fx $tpBdp 'APPLY WINDOW' 190 250 180 40 $fSmall
$bBdpApply.Accent = $true

function Calc-Bdp {
    $s = [double]$script:bdp['Speed'].Text; $l = [double]$script:bdp['Lat'].Text
    $bytes = [math]::Round($s * 1000000 / 8 * ($l / 1000))
    $win = [math]::Max(65536, [math]::Ceiling($bytes / 1460) * 1460)
    $script:bdp['Res'].Text = ("BDP {0:N0} bytes   |   TCP window {1:N0} bytes" -f $bytes, $win)
    return [int]$win
}
$bBdpCalc.Add_Click({ try { $null = Calc-Bdp } catch { Log-Err $_; Toast 'ShadowReaper' 'Invalid value' 3 } })
$bBdpPing.Add_Click({
    try {
        Toast 'ShadowReaper' 'Testing...' 0
        $r = Test-Connection -ComputerName $script:bdp['Host'].Text -Count 4 -ErrorAction Stop
        $avg = [math]::Round(($r | Measure-Object ResponseTime -Average).Average)
        $script:bdp['Lat'].Text = [string]$avg
        $null = Calc-Bdp
        Toast 'ShadowReaper' 'Done' 1
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
})
$bBdpApply.Add_Click({
    try {
        $w = Calc-Bdp
        $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters'
        Set-Reg $p 'DefaultReceiveWindow' $w; Set-Reg $p 'DefaultSendWindow' $w
        Toast 'ShadowReaper' 'Applied' 1
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
})

# --- MTU / latency ---
$null = New-Label $tpMtu 'MTU' 20 12 300 22 $fBtn $white
$null = New-Label $tpMtu 'MTU (bytes)' 20 60 200 22 $fBody $soft
$script:tcpMtu = New-Txt $tpMtu 250 58 100 '1500'
$null = New-Label $tpMtu 'Test host' 20 100 200 22 $fBody $soft
$script:tcpMtuHost = New-Txt $tpMtu 250 98 160 '1.1.1.1'
$bMtuFind = New-Fx $tpMtu 'FIND OPTIMAL' 20 160 180 40 $fSmall
$bMtuApply = New-Fx $tpMtu 'APPLY MTU' 210 160 160 40 $fSmall
$bMtuApply.Accent = $true

function Find-Mtu([string]$h) {
    $o = & ping.exe -n 1 -w 1500 $h 2>&1 | Out-String
    if ($o -notmatch 'TTL=') { return 0 }
    for ($s = 1472; $s -ge 1200; $s -= 4) {
        $o = & ping.exe -n 1 -w 1200 -f -l $s $h 2>&1 | Out-String
        if ($o -match 'TTL=') { return ($s + 28) }
        [System.Windows.Forms.Application]::DoEvents()
    }
    return 0
}
$bMtuFind.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try {
        Toast 'ShadowReaper' 'Testing...' 0
        $m = Find-Mtu $script:tcpMtuHost.Text
        if ($m -gt 0) { $script:tcpMtu.Text = [string]$m; Toast 'ShadowReaper' 'Done' 1 } else { Toast 'ShadowReaper' 'Test failed' 3 }
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
    finally { $script:busy = $false }
})
$bMtuApply.Add_Click({
    try {
        if ($script:tcpMtu.Text -notmatch '^\d{3,4}$') { throw 'bad' }
        & netsh.exe interface ipv4 set subinterface $script:tcpAd.Text ("mtu=" + $script:tcpMtu.Text) store=persistent 2>&1 | Out-Null
        Toast 'ShadowReaper' 'Applied' 1
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
})

# --- presets / apply ---
$script:tcpPresets = @{
    default = @{ auto = 'normal'; cc = 'default'; rss = 'enabled'; rsc = 'enabled'; chk = 'enabled'; lso = 'enabled'; ts = 'disabled'; chim = 'disabled'; ecn = 'disabled'; heur = 'disabled'; rto = '1000'; sack = 'disabled'; syn = '2'; thr = '10'; resp = '20'; ttl = '128'; wait = '120'; port = '65534' }
    optimal = @{ auto = 'normal'; cc = 'ctcp'; rss = 'enabled'; rsc = 'disabled'; chk = 'enabled'; lso = 'disabled'; ts = 'disabled'; chim = 'disabled'; ecn = 'disabled'; heur = 'disabled'; rto = '2000'; sack = 'disabled'; syn = '2'; thr = 'disabled'; resp = '0'; ttl = '64'; wait = '30'; port = '65534' }
}

function Read-TcpCurrent {
    $t = Get-NetTCPSetting -SettingName InternetCustom -ErrorAction SilentlyContinue
    if (-not $t) { $t = Get-NetTCPSetting -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $o = Get-NetOffloadGlobalSetting -ErrorAction SilentlyContinue
    $h = @{}
    $h['auto'] = ([string]$t.AutoTuningLevelLocal).ToLower()
    $h['cc'] = ([string]$t.CongestionProvider).ToLower()
    $h['ecn'] = ([string]$t.EcnCapability).ToLower()
    $h['ts'] = ([string]$t.Timestamps).ToLower()
    $h['heur'] = ([string]$t.ScalingHeuristics).ToLower()
    $h['rto'] = [string]$t.InitialRto
    $h['sack'] = ([string]$t.NonSackRttResiliency).ToLower()
    $h['syn'] = [string]$t.MaxSynRetransmissions
    $h['rss'] = ([string]$o.ReceiveSideScaling).ToLower()
    $h['rsc'] = ([string]$o.ReceiveSegmentCoalescing).ToLower()
    $h['chim'] = ([string]$o.Chimney).ToLower()
    $n = $script:tcpAd.Text
    if ($n) {
        $c = Get-NetAdapterChecksumOffload -Name $n -ErrorAction SilentlyContinue
        if ($c -and [string]$c.IpIPv4Enabled -eq 'RxTxEnabled') { $h['chk'] = 'enabled' } else { $h['chk'] = 'disabled' }
        $l = Get-NetAdapterLso -Name $n -ErrorAction SilentlyContinue
        if ($l -and $l.IPv4Enabled) { $h['lso'] = 'enabled' } else { $h['lso'] = 'disabled' }
        $iface = Get-NetIPInterface -InterfaceAlias $n -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($iface) { $script:tcpMtu.Text = [string]$iface.NlMtu }
    }
    $mm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction SilentlyContinue
    if ($mm) {
        if ($mm.NetworkThrottlingIndex -eq -1 -or $mm.NetworkThrottlingIndex -eq 4294967295) { $h['thr'] = 'disabled' } else { $h['thr'] = [string]$mm.NetworkThrottlingIndex }
        $h['resp'] = [string]$mm.SystemResponsiveness
    }
    $tp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -ErrorAction SilentlyContinue
    if ($tp) { $h['ttl'] = [string]$tp.DefaultTTL; $h['wait'] = [string]$tp.TcpTimedWaitDelay; $h['port'] = [string]$tp.MaxUserPort }
    return $h
}

function Load-TcpPreset([string]$name) {
    if ($name -eq 'custom') { return }
    if ($name -eq 'current') { $v = Read-TcpCurrent } else { $v = $script:tcpPresets[$name] }
    foreach ($k in $v.Keys) {
        $c = $script:tcp[$k]
        if ($c -and $null -ne $v[$k]) { $c.Text = [string]$v[$k] }
    }
}

function Apply-Tcp {
    $v = @{}
    foreach ($k in $script:tcp.Keys) { $v[$k] = $script:tcp[$k].Text.Trim().ToLower() }
    $pairs = @(@('autotuninglevel', 'auto'), @('rss', 'rss'), @('rsc', 'rsc'), @('ecncapability', 'ecn'), @('timestamps', 'ts'),
        @('initialRto', 'rto'), @('nonsackrttresiliency', 'sack'), @('maxsynretransmissions', 'syn'), @('chimney', 'chim'))
    foreach ($p in $pairs) {
        $val = $v[$p[1]]
        if ($val) { & netsh.exe int tcp set global ("{0}={1}" -f $p[0], $val) 2>&1 | Out-Null }
    }
    if ($v['heur']) { & netsh.exe int tcp set heuristics $v['heur'] 2>&1 | Out-Null }
    if ($v['cc']) { Set-NetTCPSetting -SettingName InternetCustom -CongestionProvider $v['cc'] -ErrorAction SilentlyContinue }
    $n = $script:tcpAd.Text
    if ($n) {
        if ($v['chk'] -eq 'enabled') { Enable-NetAdapterChecksumOffload -Name $n -ErrorAction SilentlyContinue } elseif ($v['chk']) { Disable-NetAdapterChecksumOffload -Name $n -ErrorAction SilentlyContinue }
        if ($v['lso'] -eq 'enabled') { Enable-NetAdapterLso -Name $n -ErrorAction SilentlyContinue } elseif ($v['lso']) { Disable-NetAdapterLso -Name $n -ErrorAction SilentlyContinue }
        if ($script:tcpMtu.Text -match '^\d{3,4}$') { & netsh.exe interface ipv4 set subinterface $n ("mtu=" + $script:tcpMtu.Text) store=persistent 2>&1 | Out-Null }
    }
    $mmk = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    if ($v['thr'] -eq 'disabled') { [Microsoft.Win32.Registry]::SetValue($mmk, 'NetworkThrottlingIndex', -1, 'DWord') }
    elseif ($v['thr'] -match '^\d+$') { [Microsoft.Win32.Registry]::SetValue($mmk, 'NetworkThrottlingIndex', [int]$v['thr'], 'DWord') }
    if ($v['resp'] -match '^\d+$') { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' ([int]$v['resp']) }
    $tcpk = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    if ($v['ttl'] -match '^\d+$') { Set-Reg $tcpk 'DefaultTTL' ([int]$v['ttl']) }
    if ($v['wait'] -match '^\d+$') { Set-Reg $tcpk 'TcpTimedWaitDelay' ([int]$v['wait']) }
    if ($v['port'] -match '^\d+$') { Set-Reg $tcpk 'MaxUserPort' ([int]$v['port']) }
}

$null = New-Label $pgTcp 'CHOOSE SETTINGS' 20 540 160 24 $fSmall $white
$rx = 170
foreach ($d in @(@('Windows Default', 'default'), @('Current', 'current'), @('Optimal', 'optimal'), @('Custom', 'custom'))) {
    $r = New-Rad $pgTcp $d[0] $rx 538 128
    $r.Tag = $d[1]
    if ($d[1] -eq 'current') { $r.Checked = $true }
    $r.Add_CheckedChanged({ if ($this.Checked) { try { Load-TcpPreset ([string]$this.Tag) } catch {} } })
    $rx += 132
}
$bTcpApply = New-Fx $pgTcp 'APPLY CHANGES' 700 534 108 36 $fSmall
$bTcpApply.Accent = $true
$bTcpApply.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try { Apply-Tcp; Toast 'ShadowReaper' 'Applied - reboot recommended' 1 }
    catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
    finally { $script:busy = $false }
})
$script:tcpAd.Add_SelectionChangeCommitted({ try { Load-TcpPreset 'current' } catch {} })

function Init-Tcp {
    $script:tcpAd.Items.Clear()
    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) { [void]$script:tcpAd.Items.Add($a.Name) }
    $act = Get-ActiveAdapter
    if ($act) { $i = $script:tcpAd.FindStringExact($act.Name); if ($i -ge 0) { $script:tcpAd.SelectedIndex = $i } }
    elseif ($script:tcpAd.Items.Count) { $script:tcpAd.SelectedIndex = 0 }
    Load-TcpPreset 'current'
    $script:tcpBuilt = $true
    $tpGen.Visible = $true
    foreach ($c in $pgTcp.Controls) { if ($c -is [FxButton] -and $c.Tag -in 'gen', 'adv', 'bdp', 'mtu') { $c.Active = ($c.Tag -eq 'gen'); $c.Invalidate() } }
}

# =====================================================================
#  FILE ANALYZER  (rules engine - pure functions)
# =====================================================================
function ConvTo-Val([string]$data) {
    $d = $data.Trim().Trim('"')
    $o = @{ Num = $null; Str = $d }
    try {
        if ($d -match '^0x([0-9a-fA-F]{1,16})$') { $o.Num = [double][Convert]::ToUInt64($matches[1], 16) }
        elseif ($d -match '^-?\d+$') { $o.Num = [double]$d }
    } catch {}
    return $o
}

$script:Rules = @(
    @{ R = 'interfaces\\.+\\tcpackfrequency$'; S = 'good'; T = 'lat'; N = 'Disables delayed ACK'; C = { param($n, $s) $n -ge 1 -and $n -le 255 } },
    @{ R = 'interfaces\\.+\\tcpnodelay$'; S = 'good'; T = 'lat'; N = 'Disables Nagle algorithm'; C = { param($n, $s) $n -eq 0 -or $n -eq 1 } },
    @{ R = 'interfaces\\.+\\tcpdelackticks$'; S = 'good'; T = 'lat'; N = 'Delayed ACK timer'; C = { param($n, $s) $n -ge 0 -and $n -le 6 } },
    @{ R = 'msmq\\parameters\\tcpnodelay$'; S = 'fake'; N = 'MSMQ only - no effect on games' },
    @{ R = 'tcpip\\parameters\\(tcpwindowsize|globalmaxtcpwindowsize|tcp1323opts|sackopts|maxconnectionsperserver|maxconnectionsper1_0server|enablepmtudiscovery|enablepmtubhdetect|tcpmaxdataretransmissions|maxfreetcbs|maxhashtablesize|numtcbtablepartitions|tcpnumconnections|maxfreetwtcbs|synattackprotect|enableconnectionratelimiting)$'; S = 'fake'; N = 'Legacy value - ignored by Windows 10/11 TCP stack' },
    @{ R = 'tcpip\\parameters\\maxuserport$'; S = 'good'; N = 'Ephemeral port limit'; C = { param($n, $s) $n -ge 5000 -and $n -le 65534 } },
    @{ R = 'tcpip\\parameters\\tcptimedwaitdelay$'; S = 'good'; N = 'TIME_WAIT delay'; C = { param($n, $s) $n -ge 30 -and $n -le 300 } },
    @{ R = 'tcpip\\parameters\\defaulttl$'; S = 'good'; N = 'Default TTL (no speed effect)'; C = { param($n, $s) $n -ge 1 -and $n -le 255 } },
    @{ R = 'tcpip\\parameters\\disabletaskoffload$'; S = 'risk'; N = 'Disables NIC offload - raises CPU use' },
    @{ R = 'afd\\parameters\\(defaultreceivewindow|defaultsendwindow)$'; S = 'good'; T = 'lat'; N = 'Socket buffer size'; C = { param($n, $s) $n -ge 4096 -and $n -le 16777216 } },
    @{ R = 'afd\\parameters\\(fastsenddatagramthreshold|fastcopyreceivethreshold|ignorepushbitonreceives|dynamicsendbufferdisable)$'; S = 'good'; N = 'AFD socket tuning' },
    @{ R = 'afd\\parameters\\(buffersize|largebuffersize|mediumbuffersize|smallbuffersize|hugebuffersize|largebufferlistdepth|mediumbufferlistdepth|smallbufferlistdepth|bufferalignment|bufferMultiplier|disableaddresssharing|disablechainedreceive|disabledirectacceptex|disablerawsecurity|transmitworker|priorityboost)$'; S = 'fake'; N = 'Legacy AFD value - no effect on modern Windows' },
    @{ R = 'psched\\nonbesteffortlimit$'; S = 'fake'; N = 'Placebo - 20% reservation myth, harmless' },
    @{ R = 'systemprofile\\networkthrottlingindex$'; S = 'good'; T = 'lat'; N = 'Multimedia network throttling'; C = { param($n, $s) $n -eq 4294967295 -or ($n -ge 1 -and $n -le 70) } },
    @{ R = 'systemprofile\\systemresponsiveness$'; S = 'good'; T = 'lat'; N = 'CPU share for background tasks'; C = { param($n, $s) $n -ge 0 -and $n -le 100 } },
    @{ R = 'tasks\\games\\gpu priority$'; S = 'good'; T = 'lat'; N = 'MMCSS game GPU priority'; C = { param($n, $s) $n -ge 0 -and $n -le 31 } },
    @{ R = 'tasks\\games\\priority$'; S = 'good'; T = 'lat'; N = 'MMCSS game CPU priority'; C = { param($n, $s) $n -ge 1 -and $n -le 8 } },
    @{ R = 'tasks\\games\\scheduling category$'; S = 'good'; T = 'lat'; N = 'MMCSS scheduling'; C = { param($n, $s) $s -match '^(Low|Medium|High)$' } },
    @{ R = 'tasks\\games\\sfio priority$'; S = 'good'; N = 'MMCSS storage priority'; C = { param($n, $s) $s -match '^(Idle|Low|Normal|High)$' } },
    @{ R = 'tasks\\games\\(affinity|background only|clock rate|latency sensitive)$'; S = 'good'; N = 'MMCSS game task value' },
    @{ R = '(priorityseparation)$'; S = 'good'; T = 'lat'; N = 'Foreground CPU quantum'; C = { param($n, $s) $n -ge 0 -and $n -le 63 } },
    @{ R = 'session manager\\kernel\\(disableexceptionchainvalidation|kernelsehopenabled|mitigationoptions|mitigationauditoptions)$'; S = 'risk'; N = 'Weakens exploit protection' },
    @{ R = 'session manager\\kernel\\(globaltimerresolutionrequests|distributetimers|interruptsteeringdisabled|dpcwatchdogprofileoffset|disabletsx)$'; S = 'good'; T = 'lat'; N = 'Kernel timing / interrupt setting' },
    @{ R = 'memory management\\disablepagingexecutive$'; S = 'good'; N = 'Keep kernel in RAM'; C = { param($n, $s) $n -eq 0 -or $n -eq 1 } },
    @{ R = 'memory management\\(largesystemcache|iopagelocklimit|seconddatalevelcache|secondleveldatacache)$'; S = 'fake'; N = 'Server/legacy value - no gain on desktops' },
    @{ R = 'memory management\\featuresettingsoverride(mask)?$'; S = 'risk'; N = 'Disables CPU security mitigations' },
    @{ R = 'graphicsdrivers\\tdrlevel$'; S = 'good'; N = 'GPU timeout recovery'; C = { param($n, $s) $n -ne 0 } },
    @{ R = 'graphicsdrivers\\tdrdelay$'; S = 'good'; N = 'GPU timeout delay'; C = { param($n, $s) $n -ge 2 -and $n -le 60 } },
    @{ R = 'graphicsdrivers\\hwschmode$'; S = 'good'; T = 'lat'; N = 'Hardware GPU scheduling'; C = { param($n, $s) $n -eq 1 -or $n -eq 2 } },
    @{ R = 'irq\d+priority$'; S = 'fake'; N = 'IRQ priority - no effect on modern hardware' },
    @{ R = 'gameconfigstore\\gamedvr_'; S = 'good'; N = 'Game DVR / fullscreen behaviour' },
    @{ R = 'windows\\gamedvr\\allowgamedvr$'; S = 'good'; N = 'Disable Game DVR policy' },
    @{ R = 'gamebar\\'; S = 'good'; N = 'Game Bar / Game Mode setting' },
    @{ R = 'powerthrottling\\powerthrottlingoff$'; S = 'good'; T = 'lat'; N = 'Disable power throttling' },
    @{ R = 'control\\power\\(hibernateenabled|csenabled|hiberfilesizepercent)$'; S = 'good'; N = 'Power setting' },
    @{ R = 'control panel\\mouse\\(mousespeed|mousethreshold1|mousethreshold2|mousesensitivity|smoothmousexcurve|smoothmouseycurve)$'; S = 'good'; T = 'lat'; N = 'Mouse acceleration / curve' },
    @{ R = 'control panel\\keyboard\\(keyboardspeed|keyboarddelay)$'; S = 'good'; N = 'Keyboard repeat' },
    @{ R = 'keyboard response\\'; S = 'risk'; N = 'FilterKeys - can trigger accessibility popups' },
    @{ R = 'ndis\\parameters\\(rssbasecpu|maxnumrsscpus)$'; S = 'good'; N = 'RSS CPU assignment' },
    @{ R = 'prefetchparameters\\(enableprefetcher|enablesuperfetch)$'; S = 'good'; N = 'Prefetch setting'; C = { param($n, $s) $n -ge 0 -and $n -le 3 } },
    @{ R = 'control panel\\desktop\\(menushowdelay|waittokillapptimeout|hungapptimeout|autoendtasks|lowlevelhookstimeout)$'; S = 'good'; N = 'Valid (cosmetic - no FPS effect)' },
    @{ R = 'control\\waittokillservicetimeout$'; S = 'good'; N = 'Valid (shutdown speed only)' }
)

$script:CmdRules = @(
    @{ R = 'bcdedit.*useplatformclock\s+(true|yes|on)'; S = 'risk'; N = 'Forces HPET - usually raises latency' },
    @{ R = 'bcdedit.*(useplatformclock\s+(false|no|off)|deletevalue\s+useplatformclock)'; S = 'good'; T = 'lat'; N = 'Default clock source' },
    @{ R = 'bcdedit.*disabledynamictick\s+(yes|true|on)'; S = 'good'; T = 'lat'; N = 'Disable dynamic tick' },
    @{ R = 'bcdedit.*useplatformtick\s+(yes|true|on)'; S = 'good'; N = 'Platform tick' },
    @{ R = 'bcdedit.*tscsyncpolicy\s+enhanced'; S = 'good'; N = 'TSC sync policy' },
    @{ R = 'bcdedit.*nx\s+alwaysoff'; S = 'risk'; N = 'Disables DEP - security risk' },
    @{ R = 'bcdedit.*(quietboot|bootux|bootmenupolicy|tpmbootentropy|increaseuserva)'; S = 'fake'; N = 'No gameplay effect' },
    @{ R = 'netsh.*autotuninglevel\s*=\s*disabled'; S = 'bad'; N = 'Disabling auto-tuning hurts throughput' },
    @{ R = 'netsh.*autotuninglevel\s*=\s*normal'; S = 'good'; N = 'Default auto-tuning (correct)' },
    @{ R = 'netsh.*(chimney|netdma)'; S = 'fake'; N = 'Removed in Windows 10 1703+' },
    @{ R = 'netsh.*(rss\s*=\s*enabled|rsc\s*=\s*disabled|timestamps\s*=\s*disabled|nonsackrttresiliency\s*=\s*disabled|dca\s*=\s*enabled|initialrto\s*=\s*\d+|congestionprovider\s*=\s*(ctcp|cubic|dctcp)|heuristics\s+disabled|maxsynretransmissions\s*=\s*\d+)'; S = 'good'; T = 'lat'; N = 'Valid TCP global setting' },
    @{ R = 'netsh.*ecncapability'; S = 'good'; N = 'ECN setting' },
    @{ R = 'fsutil.*(disablelastaccess|disable8dot3)'; S = 'good'; N = 'Filesystem overhead reduction' }
)

function Eval-Entry($path, $name, $data) {
    $full = (($path + '\' + $name).ToLower())
    $v = ConvTo-Val ([string]$data)
    foreach ($r in $script:Rules) {
        if ($full -match $r.R) {
            $st = $r.S
            if ($r.C -and $st -eq 'good') {
                $ok = $false
                try { $ok = [bool](& $r.C $v.Num $v.Str) } catch { $ok = $false }
                if (-not $ok) { return @{ St = 'bad'; Note = 'Value out of valid range - ' + $r.N; Cat = '' } }
            }
            $cat = ''; if ($r.T) { $cat = $r.T }
            return @{ St = $st; Note = $r.N; Cat = $cat }
        }
    }
    return @{ St = 'other'; Note = 'Not in rule database'; Cat = '' }
}

function Eval-Cmd([string]$line) {
    $l = $line.ToLower()
    foreach ($r in $script:CmdRules) {
        if ($l -match $r.R) { $cat = ''; if ($r.T) { $cat = $r.T }; return @{ St = $r.S; Note = $r.N; Cat = $cat } }
    }
    return @{ St = 'other'; Note = 'Not in rule database'; Cat = '' }
}

function Short-Hive([string]$p) {
    return ($p -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_CURRENT_USER', 'HKCU' -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU')
}

function Get-Tokens([string]$line) {
    return @([regex]::Matches($line, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
}

function Parse-RegText([string]$text) {
    $out = New-Object System.Collections.ArrayList
    $text = $text -replace '(?m)\\\r?\n\s*', ''
    $cur = $null
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line.Trim()
        if ($l -match '^\[-') { $cur = $null; continue }
        if ($l -match '^\[(.+)\]$') { $cur = $matches[1]; continue }
        if (-not $cur) { continue }
        $name = $null; $data = $null
        if ($l -match '^"((?:[^"\\]|\\.)*)"=(.*)$') { $name = $matches[1] -replace '\\\\', '\'; $data = $matches[2] }
        elseif ($l -match '^@=(.*)$') { $name = '(Default)'; $data = $matches[1] }
        if ($null -eq $name -or $data -eq '-') { continue }
        $val = $data
        if ($data -match '^dword:([0-9a-fA-F]{1,8})$') { $val = [string][Convert]::ToUInt32($matches[1], 16) }
        elseif ($data -match '^"(.*)"$') { $val = $matches[1] -replace '\\\\', '\' }
        elseif ($data -match '^hex') { $val = '(binary)' }
        [void]$out.Add(@{ Kind = 'reg'; Path = $cur; Name = $name; Data = $val })
    }
    return $out
}

function Parse-ScriptText([string]$text) {
    $out = New-Object System.Collections.ArrayList
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l -match '^(rem\b|::|#|@rem\b)') { continue }
        $t = Get-Tokens $l
        $low = @($t | ForEach-Object { $_.ToLower() })
        $ri = -1
        for ($i = 0; $i -lt $low.Count - 1; $i++) { if ($low[$i] -match '^(reg|reg\.exe)$' -and $low[$i + 1] -eq 'add') { $ri = $i + 1; break } }
        if ($ri -ge 0 -and $t.Count -gt $ri + 1) {
            $path = $t[$ri + 1].Trim('"'); $name = '(Default)'; $data = ''
            for ($j = $ri + 2; $j -lt $t.Count; $j++) {
                switch -regex ($low[$j]) {
                    '^/v$' { if ($j + 1 -lt $t.Count) { $name = $t[$j + 1].Trim('"'); $j++ } }
                    '^/d$' { if ($j + 1 -lt $t.Count) { $data = $t[$j + 1].Trim('"'); $j++ } }
                    '^/t$' { $j++ }
                }
            }
            [void]$out.Add(@{ Kind = 'reg'; Path = $path; Name = $name; Data = $data })
            continue
        }
        if ($l -match '(?i)(Set|New)-ItemProperty') {
            $path = ''; $name = ''; $data = ''
            for ($j = 0; $j -lt $t.Count - 1; $j++) {
                switch -regex ($low[$j]) {
                    '^-(literal)?path$' { $path = $t[$j + 1].Trim('"', "'") }
                    '^-name$' { $name = $t[$j + 1].Trim('"', "'") }
                    '^-value$' { $data = $t[$j + 1].Trim('"', "'") }
                }
            }
            if ($path -and $name) { [void]$out.Add(@{ Kind = 'reg'; Path = $path; Name = $name; Data = $data }); continue }
        }
        if ($l -match '(?i)^@?\s*(netsh|bcdedit|fsutil|powercfg|sc|schtasks)\b') { [void]$out.Add(@{ Kind = 'cmd'; Line = ($l -replace '^@', '') }) }
    }
    return $out
}

function Analyze-Text([string]$text, [string]$ext) {
    if ($ext -eq '.reg') { $entries = Parse-RegText $text } else { $entries = Parse-ScriptText $text }
    $rows = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        if ($e.Kind -eq 'reg') {
            $r = Eval-Entry $e.Path $e.Name $e.Data
            $key = (Short-Hive $e.Path) + '\' + $e.Name
            [void]$rows.Add(@{ St = $r.St; Key = $key; Val = [string]$e.Data; Note = $r.Note; Cat = $r.Cat })
        } else {
            $r = Eval-Cmd $e.Line
            [void]$rows.Add(@{ St = $r.St; Key = $e.Line; Val = ''; Note = $r.Note; Cat = $r.Cat })
        }
    }
    $c = @{ good = 0; bad = 0; fake = 0; risk = 0; other = 0; lat = 0 }
    foreach ($r in $rows) { $c[$r.St]++; if ($r.St -eq 'good' -and $r.Cat -eq 'lat') { $c['lat']++ } }
    $recog = $c.good + $c.bad + $c.fake + $c.risk
    $score = $null; $rank = '--'
    if ($recog -gt 0) {
        $score = [int][math]::Max(0, [math]::Min(100, [math]::Round(100 * ($c.good - 1.5 * $c.bad - 2 * $c.risk - 0.75 * $c.fake) / $recog)))
        if ($score -ge 90) { $rank = 'S' } elseif ($score -ge 75) { $rank = 'A' } elseif ($score -ge 60) { $rank = 'B' } elseif ($score -ge 40) { $rank = 'C' } elseif ($score -ge 20) { $rank = 'D' } else { $rank = 'F' }
    }
    return @{ Rows = $rows; Counts = $c; Score = $score; Rank = $rank; Recog = $recog }
}

# =====================================================================
#  helpers for the new pages
# =====================================================================
$script:brHead = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(28, 28, 32))
$script:brWhite = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

function New-Lv($parent, $x, $y, $w, $h, $cols) {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.SetBounds($x, $y, $w, $h); $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $false
    $lv.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 14); $lv.ForeColor = [System.Drawing.Color]::Silver
    $lv.Font = $fSmall; $lv.BorderStyle = 'None'; $lv.HideSelection = $false; $lv.OwnerDraw = $true
    foreach ($c in $cols) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $lv.Add_DrawColumnHeader({ param($s, $e) $e.Graphics.FillRectangle($script:brHead, $e.Bounds); $e.Graphics.DrawString($e.Header.Text, $fSmall, $script:brWhite, ($e.Bounds.X + 5), ($e.Bounds.Y + 5)) })
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    $parent.Controls.Add($lv)
    return $lv
}

function New-AnaPanel {
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds(12, 96, 796, 484); $p.BackColor = $darkBg; $p.Visible = $false
    $pgAna.Controls.Add($p); return $p
}

# =====================================================================
#  FILE ANALYZER page
# =====================================================================
$null = New-Label $pgAna 'FILE ANALYZER' 36 6 500 44 $fBig $white
$apFile = New-AnaPanel; $apNet = New-AnaPanel; $apBench = New-AnaPanel; $apSys = New-AnaPanel
$script:anaPanels = @{ file = $apFile; net = $apNet; bench = $apBench; sys = $apSys }
$ax = 16
foreach ($d in @(@('FILE ANALYZER', 'file'), @('NETWORK MONITOR', 'net'), @('BENCHMARK', 'bench'), @('SYSTEM INFO', 'sys'))) {
    $b = New-Fx $pgAna $d[0] $ax 52 180 36 $fSmall
    $b.Tag = 'a_' + $d[1]
    $b.Add_Click({
        $k = ([string]$this.Tag).Substring(2)
        foreach ($n in $script:anaPanels.Keys) { $script:anaPanels[$n].Visible = ($n -eq $k) }
        foreach ($c in $pgAna.Controls) { if ($c -is [FxButton] -and ([string]$c.Tag).StartsWith('a_')) { $c.Active = ($c.Tag -eq $this.Tag); $c.Invalidate() } }
        if ($k -eq 'sys' -and -not $script:sysLoaded) { Load-SysInfo }
    })
    $ax += 188
}

# ---- tab 1: file analyzer ----
$null = New-Label $apFile 'Scan a .bat / .cmd / .reg / .ps1 tweak file and get a score.' 14 10 330 36 $fSmall $gray
$bBrowse = New-Fx $apFile 'BROWSE FILE' 14 52 250 40 $fBtn
$bBrowse.Accent = $true
$script:anaFileLbl = New-Label $apFile 'No file loaded' 14 98 250 20 $fSmall $gray
$script:anaRank = New-Label $apFile '--' 14 126 250 70 $fTitle $white
$script:anaRank.TextAlign = 'MiddleCenter'
$script:anaScore = New-Label $apFile 'SCORE  --' 14 196 250 22 $fBtn $white
$script:anaScore.TextAlign = 'MiddleCenter'
$null = New-Label $apFile 'ROUGH ESTIMATE' 14 232 250 18 $fSmall $gray
$script:anaImpact = New-Label $apFile '' 14 252 250 70 $fSmall $soft
$script:anaCnt = @{}
$cy = 336
foreach ($c in @(@('good', '[+] Good', 'LightGreen'), @('bad', '[VAL!] Bad value', 'IndianRed'), @('fake', '[FAKE] Junk', 'Gold'), @('risk', '[RISK] Risky', 'OrangeRed'), @('other', '[ ] Other', 'Silver'))) {
    $null = New-Label $apFile $c[1] 14 $cy 170 20 $fSmall ([System.Drawing.Color]::FromName($c[2]))
    $script:anaCnt[$c[0]] = New-Label $apFile '0' 190 $cy 70 20 $fSmall ([System.Drawing.Color]::FromName($c[2]))
    $cy += 26
}
$script:anaLv = New-Lv $apFile 280 10 508 424 @(@('STATUS', 64), @('REGISTRY KEY / COMMAND', 230), @('VALUE', 70), @('SCORE', 46), @('DESCRIPTION', 300))
$bExport = New-Fx $apFile 'EXPORT' 688 442 100 34 $fSmall
$script:anaRows = $null
$stCol = @{ good = 'LightGreen'; bad = 'IndianRed'; fake = 'Gold'; risk = 'OrangeRed'; other = 'Gray' }
$stTxt = @{ good = '[+]'; bad = '[VAL!]'; fake = '[FAKE]'; risk = '[RISK]'; other = '[ ]' }
$stScore = @{ good = '+1'; bad = '-2'; fake = '-1'; risk = '-3'; other = '0' }

function Show-Analysis($res, [string]$file) {
    $script:anaLv.BeginUpdate(); $script:anaLv.Items.Clear()
    $n = 0
    foreach ($r in $res.Rows) {
        if ($n -ge 3000) { break }
        $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList $stTxt[$r.St]
        [void]$it.SubItems.Add([string]$r.Key); [void]$it.SubItems.Add([string]$r.Val); [void]$it.SubItems.Add($stScore[$r.St]); [void]$it.SubItems.Add([string]$r.Note)
        $it.ForeColor = [System.Drawing.Color]::FromName($stCol[$r.St])
        [void]$script:anaLv.Items.Add($it); $n++
    }
    $script:anaLv.EndUpdate()
    $script:anaRows = $res.Rows
    $script:anaFileLbl.Text = [IO.Path]::GetFileName($file)
    $script:anaRank.Text = $res.Rank
    if ($null -ne $res.Score) { $script:anaScore.Text = "SCORE  $($res.Score) / 100" } else { $script:anaScore.Text = 'SCORE  --' }
    foreach ($k in 'good', 'bad', 'fake', 'risk', 'other') { $script:anaCnt[$k].Text = [string]$res.Counts[$k] }
    $lat = $res.Counts.lat
    $il = 'None'; if ($lat -ge 6) { $il = 'Noticeable' } elseif ($lat -ge 3) { $il = 'Minor' } elseif ($lat -ge 1) { $il = 'Very small' }
    $junk = $res.Counts.fake + $res.Counts.bad + $res.Counts.risk
    $conf = 'Low'; if ($res.Recog -ge 10) { $conf = 'Medium' }; if ($res.Recog -ge 25) { $conf = 'High' }
    $script:anaImpact.Text = "Input lag   :  $il`r`nFPS boost   :  mostly none`r`nJunk/risky  :  $junk entries`r`nConfidence  :  $conf"
}

$bBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Tweak files (*.bat;*.cmd;*.reg;*.ps1)|*.bat;*.cmd;*.reg;*.ps1|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq 'OK') {
            $txt = Get-Content -LiteralPath $dlg.FileName -Raw -ErrorAction Stop
            $res = Analyze-Text $txt ([IO.Path]::GetExtension($dlg.FileName).ToLower())
            Show-Analysis $res $dlg.FileName
            Toast 'ShadowReaper' ("Scanned {0} entries" -f $res.Rows.Count) 1
        }
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Could not read file' 3 }
})
$bExport.Add_Click({
    try {
        if (-not $script:anaRows) { Toast 'ShadowReaper' 'Scan a file first' 2; return }
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Text file (*.txt)|*.txt'; $dlg.FileName = 'ShadowReaper_report.txt'
        if ($dlg.ShowDialog() -eq 'OK') {
            $lines = @("ShadowReaper analysis  -  rank $($script:anaRank.Text)  -  $($script:anaScore.Text)", '')
            foreach ($r in $script:anaRows) { $lines += ("{0,-7} {1}  =  {2}   ({3})" -f $stTxt[$r.St], $r.Key, $r.Val, $r.Note) }
            Set-Content -LiteralPath $dlg.FileName -Value $lines -Encoding UTF8
            Toast 'ShadowReaper' 'Report saved' 1
        }
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
})

# ---- tab 2: network monitor ----
$script:nm = @{ Samples = (New-Object System.Collections.ArrayList); Sent = 0; Lost = 0; Running = $false; Busy = $false }
$script:pinger = New-Object System.Net.NetworkInformation.Ping
$null = New-Label $apNet 'LIVE PING MONITOR' 20 12 300 22 $fBtn $white
$null = New-Label $apNet 'Host / server IP' 20 48 140 22 $fBody $soft
$script:nmHost = New-Txt $apNet 160 46 200 '1.1.1.1'
$bNmGo = New-Fx $apNet 'START' 376 42 110 34 $fSmall
$bNmGo.Accent = $true
$bNmDet = New-Fx $apNet 'DETECT FIVEM SERVER' 494 42 200 34 $fSmall
$bNmClr = New-Fx $apNet 'CLEAR' 702 42 80 34 $fSmall
$script:nmGraph = New-Object GraphPanel
$script:nmGraph.SetBounds(20, 96, 756, 250)
$apNet.Controls.Add($script:nmGraph)
$script:nmLbl = @{}
$sx = 20
foreach ($k in 'CURRENT', 'AVERAGE', 'MIN', 'MAX', 'JITTER', 'LOSS') {
    $null = New-Label $apNet $k $sx 366 120 18 $fSmall $gray
    $script:nmLbl[$k] = New-Label $apNet '--' $sx 386 120 34 $fBig $white
    $sx += 126
}
$null = New-Label $apNet 'Tip: use DETECT FIVEM SERVER while connected to a server, or type the server IP yourself.' 20 440 756 20 $fSmall $gray

function Nm-Update {
    $s = $script:nm.Samples
    $ok = @($s | Where-Object { $_ -ge 0 })
    $cur = '--'
    if ($s.Count) { $last = $s[$s.Count - 1]; if ($last -ge 0) { $cur = ('{0} ms' -f [int]$last) } else { $cur = 'LOST' } }
    $script:nmLbl['CURRENT'].Text = $cur
    if ($ok.Count) {
        $m = $ok | Measure-Object -Average -Minimum -Maximum
        $script:nmLbl['AVERAGE'].Text = ('{0} ms' -f [math]::Round($m.Average))
        $script:nmLbl['MIN'].Text = ('{0} ms' -f [int]$m.Minimum); $script:nmLbl['MAX'].Text = ('{0} ms' -f [int]$m.Maximum)
        $j = 0; $cnt = 0
        for ($i = 1; $i -lt $ok.Count; $i++) { $j += [math]::Abs($ok[$i] - $ok[$i - 1]); $cnt++ }
        if ($cnt) { $script:nmLbl['JITTER'].Text = ('{0:0.0} ms' -f ($j / $cnt)) }
    }
    if ($script:nm.Sent) { $script:nmLbl['LOSS'].Text = ('{0:0.0} %' -f (100 * $script:nm.Lost / $script:nm.Sent)) }
}

$script:nmTimer = New-Object System.Windows.Forms.Timer
$script:nmTimer.Interval = 1000
$script:nmTimer.Add_Tick({
    if ($script:nm.Busy) { return }
    $script:nm.Busy = $true
    try {
        $rtt = -1
        try { $r = $script:pinger.Send($script:nmHost.Text.Trim(), 800); if ($r.Status -eq 'Success') { $rtt = [double]$r.RoundtripTime } } catch {}
        $script:nm.Sent++; if ($rtt -lt 0) { $script:nm.Lost++ }
        [void]$script:nm.Samples.Add($rtt)
        if ($script:nm.Samples.Count -gt 600) { $script:nm.Samples.RemoveAt(0) }
        $script:nmGraph.Data.Add([single]$rtt)
        if ($script:nmGraph.Data.Count -gt 60) { $script:nmGraph.Data.RemoveAt(0) }
        $script:nmGraph.Invalidate(); Nm-Update
    } finally { $script:nm.Busy = $false }
})
$bNmGo.Add_Click({
    if ($script:nm.Running) { $script:nmTimer.Stop(); $script:nm.Running = $false; $this.Text = 'START' }
    else { $script:nmTimer.Start(); $script:nm.Running = $true; $this.Text = 'STOP' }
    $this.Invalidate()
})
$bNmClr.Add_Click({
    $script:nm.Samples.Clear(); $script:nm.Sent = 0; $script:nm.Lost = 0; $script:nmGraph.Data.Clear(); $script:nmGraph.Invalidate()
    foreach ($k in $script:nmLbl.Keys) { $script:nmLbl[$k].Text = '--' }
})
$bNmDet.Add_Click({
    try {
        $procs = @(Get-Process | Where-Object { $_.Name -like 'FiveM*' } | ForEach-Object { $_.Id })
        if (-not $procs.Count) { Toast 'ShadowReaper' 'FiveM is not running' 2; return }
        $found = $null
        foreach ($c in @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $procs -contains $_.OwningProcess })) {
            $ra = [string]$c.RemoteAddress
            if ($ra -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1|0\.)') { continue }
            if ($c.RemotePort -eq 30120 -or -not $found) { $found = $ra }
        }
        if ($found) { $script:nmHost.Text = $found; Toast 'ShadowReaper' 'Server found' 1 } else { Toast 'ShadowReaper' 'No server connection found' 2 }
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
})

# ---- tab 3: benchmark ----
$null = New-Label $apBench 'BENCHMARK  (run before and after BOOST to compare)' 20 12 700 22 $fBtn $white
$bBench = New-Fx $apBench 'RUN BENCHMARK' 20 44 220 40 $fBtn
$bBench.Accent = $true
$script:benchLv = New-Lv $apBench 20 100 756 330 @(@('TEST', 250), @('RESULT', 170), @('PREVIOUS RUN', 170), @('CHANGE', 150))
$null = New-Label $apBench 'Ping tests use 12 samples per host. CPU / RAM are short synthetic tests (about 5 seconds total).' 20 440 756 20 $fSmall $gray
$script:benchFile = Join-Path $env:ProgramData 'ShadowReaper\bench.json'

function Run-PingTest([string]$h) {
    $vals = New-Object System.Collections.ArrayList; $lost = 0
    for ($i = 0; $i -lt 12; $i++) {
        try { $r = $script:pinger.Send($h, 800); if ($r.Status -eq 'Success') { [void]$vals.Add([double]$r.RoundtripTime) } else { $lost++ } } catch { $lost++ }
        Pump 60
    }
    $avg = 0; $jit = 0
    if ($vals.Count) { $avg = ($vals | Measure-Object -Average).Average; $d = 0; for ($i = 1; $i -lt $vals.Count; $i++) { $d += [math]::Abs($vals[$i] - $vals[$i - 1]) }; if ($vals.Count -gt 1) { $jit = $d / ($vals.Count - 1) } }
    return @{ Avg = [math]::Round($avg, 1); Jitter = [math]::Round($jit, 1); Loss = [math]::Round(100 * $lost / 12, 1); Ok = ($vals.Count -gt 0) }
}

$bBench.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try {
        Toast 'ShadowReaper' 'Benchmark running...' 0
        $res = [ordered]@{}
        foreach ($h in '1.1.1.1', '8.8.8.8', '9.9.9.9') {
            $p = Run-PingTest $h
            $res["Ping $h (avg ms)"] = $p.Avg; $res["Jitter $h (ms)"] = $p.Jitter; $res["Loss $h (%)"] = $p.Loss
        }
        Pump 50
        $res['CPU single-thread (Mops/s)'] = [math]::Round([Bench]::Cpu(), 1)
        Pump 50
        $res['RAM copy (MB/s)'] = [math]::Round([Bench]::Ram(), 0)
        $q = [SRNative]::QueryTimer()
        $res['Timer resolution (ms)'] = [math]::Round($q[2] / 10000.0, 3)
        $prev = $null
        if (Test-Path $script:benchFile) { try { $prev = Get-Content $script:benchFile -Raw | ConvertFrom-Json } catch {} }
        $script:benchLv.Items.Clear()
        foreach ($k in $res.Keys) {
            $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList $k
            [void]$it.SubItems.Add([string]$res[$k])
            $pv = $null; if ($prev -and $prev.PSObject.Properties[$k]) { $pv = [double]$prev.PSObject.Properties[$k].Value }
            if ($null -ne $pv) {
                [void]$it.SubItems.Add([string]$pv)
                $diff = [double]$res[$k] - $pv
                [void]$it.SubItems.Add(('{0:+0.0;-0.0;0}' -f $diff))
                $lowerBetter = ($k -match 'Ping|Jitter|Loss|Timer')
                if ([math]::Abs($diff) -gt 0.0001) { if (($diff -lt 0) -eq $lowerBetter) { $it.ForeColor = [System.Drawing.Color]::LightGreen } else { $it.ForeColor = [System.Drawing.Color]::IndianRed } }
            } else { [void]$it.SubItems.Add('-'); [void]$it.SubItems.Add('-') }
            [void]$script:benchLv.Items.Add($it)
        }
        $dir = Split-Path $script:benchFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($res | ConvertTo-Json) | Set-Content -Path $script:benchFile -Encoding UTF8
        Toast 'ShadowReaper' 'Benchmark done' 1
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
    finally { $script:busy = $false }
})

# ---- tab 4: system info ----
$script:sysLoaded = $false
$script:sysLv = New-Lv $apSys 20 56 756 410 @(@('ITEM', 220), @('VALUE', 520))
$bSysRef = New-Fx $apSys 'REFRESH' 20 12 140 34 $fSmall
function Add-SysRow($k, $v) { $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList $k; [void]$it.SubItems.Add([string]$v); [void]$script:sysLv.Items.Add($it) }
function Load-SysInfo {
    $script:sysLv.Items.Clear()
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Add-SysRow 'OS' ("{0}  (build {1}, {2})" -f $os.Caption, $os.BuildNumber, $os.OSArchitecture)
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        Add-SysRow 'CPU' ("{0}  -  {1} cores / {2} threads  -  {3} MHz" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.MaxClockSpeed)
        foreach ($g in @(Get-CimInstance Win32_VideoController)) { Add-SysRow 'GPU' ("{0}  -  driver {1}" -f $g.Name, $g.DriverVersion) }
        $mods = @(Get-CimInstance Win32_PhysicalMemory)
        $tot = [math]::Round(($mods | Measure-Object Capacity -Sum).Sum / 1GB)
        $spd = ($mods | Select-Object -First 1).ConfiguredClockSpeed
        Add-SysRow 'RAM' ("{0} GB  in {1} module(s)  -  {2} MHz" -f $tot, $mods.Count, $spd)
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { Add-SysRow 'Disk' ("{0}  -  {1}  -  {2} GB" -f $d.FriendlyName, $d.MediaType, [math]::Round($d.Size / 1GB)) }
        $ad = Get-ActiveAdapter
        if ($ad) { Add-SysRow 'Network adapter' ("{0}  -  {1}  -  {2}  -  driver {3}" -f $ad.Name, $ad.InterfaceDescription, $ad.LinkSpeed, $ad.DriverVersion) }
        $pp = (& powercfg.exe /getactivescheme) | Out-String
        Add-SysRow 'Power plan' ($pp.Trim())
        $q = [SRNative]::QueryTimer()
        Add-SysRow 'Timer resolution' ("current {0} ms  (best {1} ms, default {2} ms)" -f ($q[2] / 10000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture), ($q[1] / 10000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture), ($q[0] / 10000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
        $h = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode
        $hs = 'Default / not set'; if ($h -eq 2) { $hs = 'On' } elseif ($h -eq 1) { $hs = 'Off' }
        Add-SysRow 'Hardware GPU scheduling' $hs
        $gm = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -ErrorAction SilentlyContinue).AutoGameModeEnabled
        $gs = 'Default / not set'; if ($gm -eq 1) { $gs = 'On' } elseif ($gm -eq 0) { $gs = 'Off' }
        Add-SysRow 'Windows Game Mode' $gs
        $fv = 'Not found'; if (Test-Path $script:FiveApp) { $fv = $script:FiveApp }
        Add-SysRow 'FiveM folder' $fv
    } catch { Log-Err $_ }
    $script:sysLoaded = $true
}
$bSysRef.Add_Click({ Load-SysInfo; Toast 'ShadowReaper' 'Refreshed' 0 })

# =====================================================================
#  TIMER RESOLUTION page
# =====================================================================
function Fmt-Ms($u) { return (($u / 10000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + ' ms') }
$null = New-Label $pgTimer 'TIMER RESOLUTION' 36 20 600 44 $fBig $white
$null = New-Label $pgTimer 'Lower value = tighter frame pacing and lower input latency. Takes effect immediately.' 40 66 740 20 $fSmall $gray
$script:tmLbl = @{}
$tx2 = 40
foreach ($k in @(@('MINIMUM RESOLUTION', 'min'), @('MAXIMUM RESOLUTION', 'max'), @('CURRENT RESOLUTION', 'cur'))) {
    $null = New-Label $pgTimer $k[0] $tx2 112 240 18 $fSmall $gray
    $script:tmLbl[$k[1]] = New-Label $pgTimer '--' $tx2 134 240 44 $fBig $white
    $tx2 += 250
}
$bTmMax = New-Fx $pgTimer 'MAXIMUM' 40 214 200 50 $fBtn
$bTmMax.Accent = $true
$bTmDef = New-Fx $pgTimer 'DEFAULT' 250 214 200 50 $fBtn
$null = New-Label $pgTimer 'CUSTOM (ms)' 480 204 120 18 $fSmall $gray
$script:tmTxt = New-Txt $pgTimer 480 226 90 '0.5'
$bTmSet = New-Fx $pgTimer 'SET' 582 220 90 38 $fSmall
$script:tmStatus = New-Label $pgTimer 'ShadowReaper request: none' 40 284 740 22 $fBody $soft

$null = New-Label $pgTimer 'RUN IN BACKGROUND' 40 346 400 22 $fBtn $white
$null = New-Label $pgTimer 'The timer request ends when ShadowReaper closes. Auto-start keeps it active after every login, even with this window closed.' 40 372 740 36 $fSmall $gray
$bTmOn = New-Fx $pgTimer 'ENABLE AUTO-START' 40 416 240 46 $fSmall
$bTmOn.Accent = $true
$bTmOff = New-Fx $pgTimer 'DISABLE AUTO-START' 290 416 240 46 $fSmall
$script:tmAuto = New-Label $pgTimer 'Auto-start: --' 40 474 740 22 $fBody $soft
$null = New-Label $pgTimer 'Windows 11: timer requests are per-process by default. Enabling auto-start also sets GlobalTimerResolutionRequests (reboot required once).' 40 520 740 36 $fSmall $gray

function Refresh-Timer {
    $q = [SRNative]::QueryTimer()
    $script:tmLbl['min'].Text = Fmt-Ms $q[0]; $script:tmLbl['max'].Text = Fmt-Ms $q[1]; $script:tmLbl['cur'].Text = Fmt-Ms $q[2]
}
function Get-TimerTaskState {
    $t = Get-ScheduledTask -TaskName 'ShadowReaper_TimerResolution' -ErrorAction SilentlyContinue
    if ($t) { $script:tmAuto.Text = 'Auto-start: ON  (' + $t.State + ')' } else { $script:tmAuto.Text = 'Auto-start: OFF' }
}
function Set-TimerRes([double]$ms) {
    $q = [SRNative]::QueryTimer()
    $d = [uint32][math]::Round($ms * 10000)
    if ($d -lt $q[1]) { $d = $q[1] }
    if ($d -gt $q[0]) { $d = $q[0] }
    [void][SRNative]::SetTimer($d, $true)
    $script:tmStatus.Text = 'ShadowReaper request: ' + (Fmt-Ms $d) + '  (active while ShadowReaper is open)'
    Refresh-Timer
}
$bTmMax.Add_Click({ try { $q = [SRNative]::QueryTimer(); Set-TimerRes ($q[1] / 10000.0); Toast 'ShadowReaper' 'Applied' 1 } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 } })
$bTmDef.Add_Click({ try { $q = [SRNative]::QueryTimer(); [void][SRNative]::SetTimer($q[0], $false); $script:tmStatus.Text = 'ShadowReaper request: none'; Refresh-Timer; Toast 'ShadowReaper' 'Released' 1 } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 } })
$bTmSet.Add_Click({
    try {
        $v = [double]::Parse($script:tmTxt.Text.Trim().Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
        Set-TimerRes $v; Toast 'ShadowReaper' 'Applied' 1
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Invalid value' 3 }
})
$bTmOn.Add_Click({
    try {
        $dir = Join-Path $env:ProgramData 'ShadowReaper'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir 'timer.ps1'
        $lines = @(
            'Add-Type -TypeDefinition ''using System;using System.Runtime.InteropServices;public static class SRT{[DllImport("ntdll.dll")]public static extern int NtQueryTimerResolution(out uint a,out uint b,out uint c);[DllImport("ntdll.dll")]public static extern int NtSetTimerResolution(uint d,bool s,out uint c);}''',
            '$a=[uint32]0;$b=[uint32]0;$c=[uint32]0',
            '[void][SRT]::NtQueryTimerResolution([ref]$a,[ref]$b,[ref]$c)',
            '[void][SRT]::NtSetTimerResolution($b,$true,[ref]$c)',
            'while($true){Start-Sleep -Seconds 3600}'
        )
        Set-Content -Path $file -Value $lines -Encoding ASCII
        $act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $file + '"')
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $pri = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName 'ShadowReaper_TimerResolution' -Action $act -Trigger $trg -Principal $pri -Settings $set -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName 'ShadowReaper_TimerResolution' -ErrorAction SilentlyContinue
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
        Get-TimerTaskState; Toast 'ShadowReaper' 'Auto-start enabled' 1
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
})
$bTmOff.Add_Click({
    try {
        Stop-ScheduledTask -TaskName 'ShadowReaper_TimerResolution' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'ShadowReaper_TimerResolution' -Confirm:$false -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ShadowReaper*timer.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' -Name 'GlobalTimerResolutionRequests' -ErrorAction SilentlyContinue
        Get-TimerTaskState; Toast 'ShadowReaper' 'Auto-start disabled' 1
    } catch { Log-Err $_; Toast 'ShadowReaper' 'Failed' 3 }
})
$script:tmTick = New-Object System.Windows.Forms.Timer
$script:tmTick.Interval = 500
$script:tmTick.Add_Tick({ if ($pgTimer.Visible) { Refresh-Timer } })
$script:tmTick.Start()


# =====================================================================
#  actions
# =====================================================================
function Init-Ana {
    if (-not ($apFile.Visible -or $apNet.Visible -or $apBench.Visible -or $apSys.Visible)) { $apFile.Visible = $true }
    foreach ($c in $pgAna.Controls) {
        if ($c -is [FxButton] -and ([string]$c.Tag).StartsWith('a_')) {
            $c.Active = (($c.Tag -eq 'a_file' -and $apFile.Visible) -or ($c.Tag -eq 'a_net' -and $apNet.Visible) -or ($c.Tag -eq 'a_bench' -and $apBench.Visible) -or ($c.Tag -eq 'a_sys' -and $apSys.Visible)); $c.Invalidate()
        }
    }
}

function Do-Boost {
    $script:hdr.Text = 'BOOSTING...'
    Set-Progress 0
    Toast 'ShadowReaper' 'Optimizing...' 0
    $steps = @({ Backup-Reg }, { Do-RegImport }, { Do-Tcp }, { Do-Priority }, { Do-FiveMConfig }, { Do-Cache }, { Do-Ram }, { Do-NetRecommended })
    $i = 0
    foreach ($s in $steps) {
        $i++
        $null = Run-Step ("step $i") $s
        Set-Progress ([int](100 * $i / $steps.Count))
        if ($i -eq 2 -or $i -eq 4 -or $i -eq 6) { Toast 'ShadowReaper' ("Applied {0}%" -f [int](100 * $i / $steps.Count)) 1 }
    }
    $script:hdr.Text = 'DONE'
    Toast 'ShadowReaper' 'Done - restart PC for full effect' 1
}

function Invoke-Action([string]$a) {
    if (-not (Test-Licensed)) { Toast 'ShadowReaper' 'License invalid or expired' 3; return }
    if ($script:busy) { Toast 'ShadowReaper' 'Busy - please wait' 2; return }
    $script:busy = $true
    try {
        if ($a -ne 'ana' -and $script:nm.Running) { $script:nmTimer.Stop(); $script:nm.Running = $false; $bNmGo.Text = 'START'; $bNmGo.Invalidate() }
        if ($a -ne 'run') { foreach ($b in $script:sideBtns) { $b.Active = ($b.Tag -eq $a); $b.Invalidate() } }
        switch ($a) {
            'boost'  { Show-Page 'home' }
            'run'    { Show-Page 'home'; Do-Boost }
            'net'    { Show-Page 'net'; if (-not $script:netBuilt) { Init-Net } }
            'fk'     { Show-Page 'fk' }
            'tcpopt' { Show-Page 'tcpopt'; if (-not $script:tcpBuilt) { Init-Tcp } }
            'ana'    { Show-Page 'ana'; Init-Ana }
            'timer'  { Show-Page 'timer'; Refresh-Timer; Get-TimerTaskState }
        }
    }
    catch { Log-Err $_; Toast 'ShadowReaper' 'Something went wrong' 3 }
    finally { $script:busy = $false }
}

foreach ($b in $script:sideBtns) { $b.Add_Click({ Invoke-Action ([string]$this.Tag) }) }

$form.Add_Shown({
    Show-Page 'home'
    $script:sideBtns[0].Active = $true; $script:sideBtns[0].Invalidate()
    try {
        $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $ad = Get-ActiveAdapter
        $script:info.Text = ("{0}   |   {1} GB RAM   |   {2}   |   License: {3}" -f $cpu, $ram, $ad.Name, $script:licInfo)
    } catch {}
    Toast 'ShadowReaper' 'Ready' 1
})

try { [System.Windows.Forms.Application]::Run($form) }
catch { [System.Windows.Forms.MessageBox]::Show('ShadowReaper error: ' + $_.Exception.Message, 'ShadowReaper') | Out-Null }
$ErrorActionPreference = 'Continue'
