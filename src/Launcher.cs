// Tiny launcher: starts PowerMeter.ps1 hidden, so shortcuts and Windows startup can run it without a console window.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher {
    [STAThread]
    static void Main() {
        string dir = Path.GetDirectoryName(Application.ExecutablePath);
        string ps1 = Path.Combine(dir, "PowerMeter.ps1");
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        try {
            var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = dir;
            Process.Start(psi);
        } catch (Exception e) {
            MessageBox.Show("Power Meter could not start:\n" + e.Message, "Power Meter");
        }
    }
}
