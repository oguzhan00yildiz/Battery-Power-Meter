// Hover panel for the Power Meter tray icon: owner-drawn, follows the Windows light/dark taskbar theme.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PM {
    public class AppRow {
        public string Name = "";
        public double Watts;
        public Icon Icon;
        public string Glyph;   // used when there is no app icon
    }

    public class PanelData {
        public string WattsText = "";
        public double Watts;
        public string Status = "";
        public double Percent;
        public string CapacityText = "";
        public string TimeText = "";
        public bool PluggedIn;
        public bool Charging;
        public string Footer = "";
        public List<AppRow> Apps = new List<AppRow>();
    }

    public class Panel : Form {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        public PanelData Data = new PanelData();
        float s = 1f;
        bool dark = true;
        string glyphFont;
        Point anchor;
        Color Bg, Fg, Fg2, Sep, Track, Accent;

        public Panel() {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            using (var g = CreateGraphics()) s = g.DpiX / 96f;
            glyphFont = FontExists("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
            ApplyTheme();
        }

        public float UiScale { get { return s; } }

        static bool FontExists(string name) { using (var f = new Font(name, 10)) return f.Name == name; }
        static Color C(int rgb) { return Color.FromArgb((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
        int P(float v) { return (int)Math.Round(v * s); }

        public void ApplyTheme() {
            dark = true;
            try {
                var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                if (k != null) { object v = k.GetValue("SystemUsesLightTheme"); if (v is int) dark = (int)v == 0; }
            } catch { }
            if (dark) { Bg = C(0x2C2C2C); Fg = C(0xFFFFFF); Fg2 = C(0xADADAD); Sep = C(0x3F3F3F); Track = C(0x484848); Accent = C(0x60CDFF); }
            else      { Bg = C(0xF3F3F3); Fg = C(0x1B1B1B); Fg2 = C(0x5F5F5F); Sep = C(0xE0E0E0); Track = C(0xD9D9D9); Accent = C(0x005FB8); }
            BackColor = Bg;
        }

        Color WattColor(double w) {
            if (w < 15) return dark ? C(0x6CCB5F) : C(0x0F7B0F);
            if (w < 25) return dark ? C(0xFFB454) : C(0xC25E00);
            return dark ? C(0xFF99A4) : C(0xC42B1C);
        }

        Color BatteryColor(PanelData d) {
            if (d.Charging) return Accent;
            if (d.Percent <= 20) return dark ? C(0xFF99A4) : C(0xC42B1C);
            if (d.Percent <= 40) return dark ? C(0xFFB454) : C(0xC25E00);
            return dark ? C(0x6CCB5F) : C(0x0F7B0F);
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams {
            get {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x80 | 0x8;   // no-activate, tool window, topmost
                cp.ClassStyle |= 0x20000;                // drop shadow
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            int round = 2;   // Windows 11 rounded corners
            try { DwmSetWindowAttribute(Handle, 33, ref round, 4); } catch { }
        }

        public void ShowAt(Point cursor) {
            anchor = cursor;
            ApplyTheme();
            Relayout();
            if (!Visible) Show();
            Invalidate();
        }

        public void Relayout() {
            int h;
            using (var g = CreateGraphics()) h = (int)Math.Ceiling(Render(g, false));
            int w = P(300);
            var wa = Screen.FromPoint(anchor).WorkingArea;
            int x = Math.Max(wa.Left + P(8), Math.Min(anchor.X - w / 2, wa.Right - w - P(8)));
            int y;
            if (anchor.Y >= wa.Bottom) y = wa.Bottom - h - P(12);       // taskbar at the bottom
            else if (anchor.Y < wa.Top) y = wa.Top + P(12);             // taskbar at the top
            else y = Math.Max(wa.Top + P(8), anchor.Y - h - P(16));
            Bounds = new Rectangle(x, y, w, h);
            Invalidate();
        }

        public Bitmap Snapshot() {
            ApplyTheme();
            int h;
            using (var g = CreateGraphics()) h = (int)Math.Ceiling(Render(g, false));
            var bmp = new Bitmap(P(300), h);
            using (var g = Graphics.FromImage(bmp)) { g.Clear(Bg); Render(g, true); }
            return bmp;
        }

        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.Clear(Bg);
            Render(e.Graphics, true);
        }

        void Txt(Graphics g, string t, Font f, Color c, float x, float y) {
            using (var b = new SolidBrush(c)) g.DrawString(t ?? "", f, b, x, y, StringFormat.GenericTypographic);
        }

        void TextRight(Graphics g, string t, Font f, Color c, float right, float y) {
            float w = g.MeasureString(t ?? "", f, 1000, StringFormat.GenericTypographic).Width;
            Txt(g, t, f, c, right - w, y);
        }

        void TextClipped(Graphics g, string t, Font f, Color c, float x, float y, float width) {
            using (var b = new SolidBrush(c))
            using (var sf = new StringFormat(StringFormat.GenericTypographic)) {
                sf.Trimming = StringTrimming.EllipsisCharacter;
                sf.FormatFlags |= StringFormatFlags.NoWrap;
                g.DrawString(t ?? "", f, b, new RectangleF(x, y, width, f.GetHeight(g) + 2), sf);
            }
        }

        void Bar(Graphics g, float x, float y, float w, float h, Color c, double fraction) {
            fraction = Math.Max(0, Math.Min(1, fraction));
            float fw = Math.Max(h, (float)(w * fraction));
            if (fraction <= 0) return;
            using (var path = new GraphicsPath())
            using (var b = new SolidBrush(c)) {
                float r = h;
                path.AddArc(x, y, r, h, 90, 180);
                path.AddArc(x + fw - r, y, r, h, 270, 180);
                path.CloseFigure();
                g.FillPath(b, path);
            }
        }

        void Line(Graphics g, float x, float y, float w) {
            using (var p = new Pen(Sep, Math.Max(1, s))) g.DrawLine(p, x, y, x + w, y);
        }

        // Draws the panel (or only measures it when draw == false) and returns its height in pixels
        float Render(Graphics g, bool draw) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            var d = Data ?? new PanelData();
            float W = P(300), pad = P(16), inner = W - 2 * pad, y = P(14);
            Color wc = WattColor(d.Watts);

            using (var fHeroGlyph = new Font(glyphFont, P(24), GraphicsUnit.Pixel))
            using (var fHero = new Font("Segoe UI Semibold", P(30), GraphicsUnit.Pixel))
            using (var fSub = new Font("Segoe UI", P(12), GraphicsUnit.Pixel))
            using (var fBold = new Font("Segoe UI Semibold", P(13), GraphicsUnit.Pixel))
            using (var fText = new Font("Segoe UI", P(13), GraphicsUnit.Pixel))
            using (var fSmall = new Font("Segoe UI", P(11), GraphicsUnit.Pixel))
            using (var fGlyph = new Font(glyphFont, P(14), GraphicsUnit.Pixel)) {
                // Big number: current power use
                if (draw) {
                    Txt(g, d.PluggedIn ? "" : "", fHeroGlyph, wc, pad, y + P(10));
                    Txt(g, d.WattsText, fHero, wc, pad + P(34), y);
                    Txt(g, d.Status, fSub, Fg2, pad + P(36), y + P(40));
                }
                y += P(66);

                // Battery level bar
                if (draw) {
                    Txt(g, "Battery " + d.Percent.ToString("0") + "%", fBold, Fg, pad, y);
                    TextRight(g, d.CapacityText, fSub, Fg2, pad + inner, y + P(1));
                }
                y += P(22);
                if (draw) {
                    Bar(g, pad, y, inner, P(8), Track, 1.0);
                    Bar(g, pad, y, inner, P(8), BatteryColor(d), Math.Max(0.03, d.Percent / 100.0));
                }
                y += P(18);
                if (draw) {
                    Txt(g, d.Charging ? "" : "", fGlyph, Fg2, pad, y + P(2));
                    Txt(g, d.TimeText, fText, Fg, pad + P(22), y);
                }
                y += P(28);

                if (draw) Line(g, pad, y, inner);
                y += P(12);

                // Per-app estimates
                if (draw) Txt(g, "Estimated power by app", fSmall, Fg2, pad, y);
                y += P(22);
                double max = 0.1;
                foreach (var a in d.Apps) max = Math.Max(max, a.Watts);
                foreach (var a in d.Apps) {
                    if (draw) {
                        if (a.Icon != null) g.DrawIcon(a.Icon, new Rectangle((int)pad, (int)(y + P(1)), P(18), P(18)));
                        else Txt(g, a.Glyph ?? "", fGlyph, Fg2, pad + P(2), y + P(3));
                        float nx = pad + P(28), bw = inner - P(28);
                        TextClipped(g, a.Name, fText, Fg, nx, y, bw - P(60));
                        TextRight(g, a.Watts.ToString("0.0") + " W", fBold, Fg, pad + inner, y);
                        Bar(g, nx, y + P(21), bw, P(3), Track, 1.0);
                        Bar(g, nx, y + P(21), bw, P(3), Accent, a.Watts / max);
                    }
                    y += P(32);
                }
                if (d.Apps.Count == 0) {
                    if (draw) Txt(g, "Collecting data…", fText, Fg2, pad, y);
                    y += P(26);
                }

                y += P(2);
                if (draw) Line(g, pad, y, inner);
                y += P(10);
                if (draw) Txt(g, d.Footer, fSmall, Fg2, pad, y);
                y += P(30);
            }
            return y;
        }
    }
}
