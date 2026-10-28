// Last-Signal-Installer fuer SurrounDead: entpackt UE4SS + Last-Signal-Mod nach SurrounDead/Binaries/Win64.
// Bauen: build.cmd (nutzt den csc aus .NET Framework 4, der bei Windows dabei ist).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

static class Game
{
    public const string ShippingExe = "SurrounDead-Win64-Shipping.exe";
    const string Win64Rel = @"SurrounDead\Binaries\Win64";

    // Akzeptiert den Spielordner, SurrounDead\SurrounDead oder direkt Win64.
    public static string ResolveWin64(string dir)
    {
        if (string.IsNullOrWhiteSpace(dir)) return null;
        dir = dir.Trim().Trim('"');
        string[] candidates = {
            dir,
            Path.Combine(dir, Win64Rel),
            Path.Combine(dir, @"Binaries\Win64"),
            Path.Combine(dir, @"steamapps\common\SurrounDead", Win64Rel),
        };
        foreach (string c in candidates)
        {
            try { if (File.Exists(Path.Combine(c, ShippingExe))) return Path.GetFullPath(c); }
            catch (ArgumentException) { }
        }
        return null;
    }

    public static string Detect()
    {
        foreach (string lib in SteamLibraries())
        {
            string win64 = ResolveWin64(Path.Combine(lib, @"steamapps\common\SurrounDead"));
            if (win64 != null) return win64;
        }
        return null;
    }

    static IEnumerable<string> SteamLibraries()
    {
        var roots = new List<string>();
        AddRegistryValue(roots, Registry.CurrentUser, @"Software\Valve\Steam", "SteamPath");
        AddRegistryValue(roots, Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath");
        AddRegistryValue(roots, Registry.LocalMachine, @"SOFTWARE\Valve\Steam", "InstallPath");

        var libs = new List<string>(roots);
        foreach (string root in roots)
        {
            string vdf = Path.Combine(root, @"steamapps\libraryfolders.vdf");
            if (!File.Exists(vdf)) continue;
            foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                libs.Add(m.Groups[1].Value.Replace(@"\\", @"\"));
        }
        return libs;
    }

    static void AddRegistryValue(List<string> list, RegistryKey hive, string key, string name)
    {
        using (RegistryKey k = hive.OpenSubKey(key))
        {
            string v = k == null ? null : k.GetValue(name) as string;
            if (!string.IsNullOrEmpty(v)) list.Add(v.Replace('/', '\\'));
        }
    }

    public static bool IsRunning()
    {
        return Process.GetProcessesByName(Path.GetFileNameWithoutExtension(ShippingExe)).Length > 0;
    }

    // "7656119..." -> "steam.7656119...", "steam.x" und IPs bleiben wie sie sind.
    public static string NormalizeHost(string host)
    {
        host = (host ?? "").Trim();
        if (Regex.IsMatch(host, @"^\d{17}$")) return "steam." + host;
        return host;
    }

    public static string ModFile(string win64, string name)
    {
        return Path.Combine(win64, @"ue4ss\Mods\LastSignal", name);
    }

    // Vor der Umbenennung hiess der Mod "NetTest": Einstellungen von dort uebernehmen, Ordner danach entfernen.
    public static string OldModFile(string win64, string name)
    {
        return Path.Combine(win64, @"ue4ss\Mods\NetTest", name);
    }

    // netmode.txt: "ip" = Verbindung per IP/Portfreigabe, sonst Steam-P2P.
    public static bool ReadIpMode(string win64)
    {
        string file = ModFile(win64, "netmode.txt");
        if (!File.Exists(file)) file = OldModFile(win64, "netmode.txt");
        return File.Exists(file) && File.ReadAllText(file).Trim().ToLowerInvariant() == "ip";
    }

    public static void Install(string win64, string host, bool ipMode, Action<string> log)
    {
        Install(win64, host, ipMode, false, log);
    }

    public static void Install(string win64, string host, bool ipMode, bool removeOtherMods, Action<string> log)
    {
        if (IsRunning()) throw new InvalidOperationException("SurrounDead is still running. Please close the game first.");

        string hostFile = ModFile(win64, "host_ip.txt");
        string oldHost = File.Exists(hostFile) ? File.ReadAllText(hostFile) : null;
        string oldModHost = OldModFile(win64, "host_ip.txt");
        if (oldHost == null && File.Exists(oldModHost)) oldHost = File.ReadAllText(oldModHost);

        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
        using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
        {
            // UE4SS-Mods aus dem Paket (alle anderen Mod-Ordner sind fremd)
            var ownMods = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (ZipArchiveEntry entry in zip.Entries)
            {
                Match m = Regex.Match(entry.FullName.Replace('\\', '/'), @"^ue4ss/Mods/([^/]+)/");
                if (m.Success) ownMods.Add(m.Groups[1].Value);
            }
            ownMods.Add("NetTest");   // alter Name, wird unten entfernt
            if (removeOtherMods) RemoveOtherMods(win64, ownMods, log);

            string root = Path.GetFullPath(win64).TrimEnd('\\') + "\\";
            int files = 0;
            foreach (ZipArchiveEntry entry in zip.Entries)
            {
                string rel = entry.FullName.Replace('/', '\\');
                string target = Path.GetFullPath(Path.Combine(root, rel));
                if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
                if (rel.EndsWith("\\")) { Directory.CreateDirectory(target); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                entry.ExtractToFile(target, true);
                files++;
            }
            log("Installed UE4SS and Last Signal (" + files + " files)");
        }

        host = NormalizeHost(host);
        if (host.Length > 0) File.WriteAllText(hostFile, host + "\r\n");
        else if (oldHost != null) File.WriteAllText(hostFile, oldHost);
        else File.WriteAllText(hostFile, "127.0.0.1\r\n");

        File.WriteAllText(ModFile(win64, "netmode.txt"), (ipMode ? "ip" : "steam") + "\r\n");

        // Spieler brauchen kein UE4SS-Terminal (zeigt sonst das Mod-Log) und kein Neuladen der Mods (Strg+R)
        string ue4ssIni = Path.Combine(win64, @"ue4ss\UE4SS-settings.ini");
        if (File.Exists(ue4ssIni))
        {
            string text = File.ReadAllText(ue4ssIni);
            foreach (string key in new[] { "ConsoleEnabled", "GuiConsoleEnabled", "GuiConsoleVisible", "EnableHotReloadSystem" })
                text = Regex.Replace(text, @"(?m)^(\s*" + key + @"\s*=\s*)\d+", "${1}0");
            File.WriteAllText(ue4ssIni, text);
        }
        // Keine Unreal-Konsole und kein Cheat-Manager fuer Spieler (sonst Konsolenbefehle wie "open <IP>")
        string modsTxt = Path.Combine(win64, @"ue4ss\Mods\mods.txt");
        if (File.Exists(modsTxt))
        {
            string text = File.ReadAllText(modsTxt);
            foreach (string mod in new[] { "ConsoleEnablerMod", "CheatManagerEnablerMod" })
                text = Regex.Replace(text, @"(?m)^(\s*" + mod + @"\s*:\s*)1", "${1}0");
            File.WriteAllText(modsTxt, text);
        }

        // Alten Mod-Ordner "NetTest" entfernen, sonst laedt UE4SS den Mod doppelt (mods.txt kommt neu aus dem Paket)
        string oldDir = Path.GetDirectoryName(OldModFile(win64, "x"));
        if (Directory.Exists(oldDir)) { Directory.Delete(oldDir, true); log("Removed old mod folder NetTest"); }

        // Steam ersetzt sonst das normale Socket-System, dann kann der IpNetDriver nicht lauschen.
        // Wird beim Spielstart gelesen; das Spiel ueberschreibt die Datei beim Beenden, darum nur
        // schreiben, wenn es nicht laeuft (oben geprueft).
        string ini = UserEngineIni();
        SetIniKey(ini, "OnlineSubsystemSteam", "bUseSteamNetworking", ipMode ? "false" : null);
        // UE 5.6 schreibt die Engine.ini oben beim Beenden neu und laesst den Eintrag dabei weg. Die Datei
        // <Spiel>\SurrounDead\Config\UserEngine.ini liest Unreal, schreibt sie aber nie: dort haelt er dauerhaft.
        SetIniKey(GameUserEngineIni(win64), "OnlineSubsystemSteam", "bUseSteamNetworking", ipMode ? "false" : null);
        log("Game network settings updated");
    }

    // Andere Mods verschieben (nicht loeschen) nach <Spiel>\LastSignal_ModBackup\<Zeit>: fremde UE4SS-Mods, Pak-Mods
    // (Paks\~mods, Paks\LogicMods, fremde .pak) und andere Mod-Loader-DLLs neben der exe. Sie liessen sich mit dem
    // Server-Mod nicht vertragen (Abstuerze, andere Spielwerte als der Server).
    static readonly string[] LoaderFiles = { "dinput8.dll", "xinput1_3.dll", "xinput1_4.dll", "version.dll", "winmm.dll",
                                             "dxgi.dll", "d3d11.dll", "UE4SS.dll", "UE4SS-settings.ini" };

    public static void RemoveOtherMods(string win64, HashSet<string> ownMods, Action<string> log)
    {
        string gameDir = Path.GetFullPath(Path.Combine(win64, @"..\..\.."));
        string paks = Path.GetFullPath(Path.Combine(win64, @"..\..\Content\Paks"));
        string backup = Path.Combine(gameDir, @"LastSignal_ModBackup\" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss"));
        int moved = 0;
        Action<string, string> move = (source, name) =>
        {
            string target = Path.Combine(backup, name);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            if (Directory.Exists(source)) Directory.Move(source, target); else File.Move(source, target);
            log("Moved other mod: " + name);
            moved++;
        };

        string mods = Path.Combine(win64, @"ue4ss\Mods");
        if (Directory.Exists(mods))
            foreach (string dir in Directory.GetDirectories(mods))
                if (!ownMods.Contains(Path.GetFileName(dir))) move(dir, @"ue4ss\Mods\" + Path.GetFileName(dir));
        foreach (string name in LoaderFiles)
            if (File.Exists(Path.Combine(win64, name))) move(Path.Combine(win64, name), name);
        if (Directory.Exists(Path.Combine(win64, "Mods"))) move(Path.Combine(win64, "Mods"), "Mods");   // altes UE4SS-Layout
        if (Directory.Exists(paks))
        {
            foreach (string sub in new[] { "~mods", "LogicMods" })
            {
                string dir = Path.Combine(paks, sub);
                if (!Directory.Exists(dir)) continue;
                foreach (string entry in Directory.GetFileSystemEntries(dir)) move(entry, @"Paks\" + sub + @"\" + Path.GetFileName(entry));
            }
            foreach (string file in Directory.GetFiles(paks))
            {
                string name = Path.GetFileName(file);
                if (name.StartsWith("SurrounDead-Windows", StringComparison.OrdinalIgnoreCase) ||
                    name.StartsWith("global.", StringComparison.OrdinalIgnoreCase)) continue;
                string ext = Path.GetExtension(name).ToLowerInvariant();
                if (ext == ".pak" || ext == ".utoc" || ext == ".ucas" || ext == ".sig") move(file, @"Paks\" + name);
            }
        }
        log(moved == 0 ? "No other mods found" : ("Other mods moved to " + backup));
    }

    public static string UserEngineIni()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"SurrounDead\Saved\Config\Windows\Engine.ini");
    }

    // Setzt key=value in [section]; value == null entfernt den Schluessel. Andere Zeilen bleiben unveraendert.
    public static void SetIniKey(string path, string section, string key, string value)
    {
        var lines = new List<string>(File.Exists(path) ? File.ReadAllLines(path) : new string[0]);
        string header = "[" + section + "]";
        int start = lines.FindIndex(l => l.Trim().Equals(header, StringComparison.OrdinalIgnoreCase));
        if (start < 0)
        {
            if (value == null) return;
            if (lines.Count > 0 && lines[lines.Count - 1].Trim().Length > 0) lines.Add("");
            lines.Add(header);
            lines.Add(key + "=" + value);
        }
        else
        {
            int end = start + 1;
            while (end < lines.Count && !lines[end].TrimStart().StartsWith("[")) end++;
            int found = -1;
            for (int i = start + 1; i < end; i++)
                if (lines[i].Split('=')[0].Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) found = i;
            if (value == null) { if (found >= 0) lines.RemoveAt(found); }
            else if (found >= 0) lines[found] = key + "=" + value;
            else
            {
                int insert = end;
                while (insert > start + 1 && lines[insert - 1].Trim().Length == 0) insert--;
                lines.Insert(insert, key + "=" + value);
            }
        }
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllLines(path, lines);
    }

    // <Spiel>\SurrounDead\Config\UserEngine.ini (Konfig-Ebene GameDirUser, wird vom Spiel nie geschrieben)
    public static string GameUserEngineIni(string win64)
    {
        return Path.GetFullPath(Path.Combine(win64, @"..\..\Config\UserEngine.ini"));
    }

    public static void Uninstall(string win64, Action<string> log)
    {
        if (IsRunning()) throw new InvalidOperationException("SurrounDead is still running. Please close the game first.");
        string dll = Path.Combine(win64, "dwmapi.dll");
        string dir = Path.Combine(win64, "ue4ss");
        if (File.Exists(dll)) { File.Delete(dll); log("Removed dwmapi.dll"); }
        if (Directory.Exists(dir)) { Directory.Delete(dir, true); log("Removed UE4SS and Last Signal"); }
        string userIni = GameUserEngineIni(win64);
        if (File.Exists(userIni)) { SetIniKey(userIni, "OnlineSubsystemSteam", "bUseSteamNetworking", null); log("Network setting removed"); }
    }
}

class InstallerForm : Form
{
    readonly TextBox pathBox = new TextBox();
    readonly TextBox hostBox = new TextBox();
    readonly TextBox logBox = new TextBox();
    readonly CheckBox ipBox = new CheckBox();
    readonly CheckBox cleanBox = new CheckBox();
    readonly TextBox chatKeyBox = new TextBox();
    readonly Button installButton = new Button();
    readonly Button uninstallButton = new Button();
    // Adresse der Master-Liste (Serverliste im Spiel), z. B. "http://1.2.3.4:8080". Vor dem Release eintragen.
    // Master-Liste hinter Cloudflare + Nginx Proxy Manager (master/MASTER.md). Erst bauen, wenn die Domain antwortet.
    const string MasterUrl = "https://update.tacticalhardline.com";

    // Farben (dunkel, Akzent orange wie die Namen im Chat)
    static readonly Color Back = Color.FromArgb(21, 23, 28);
    static readonly Color Card = Color.FromArgb(30, 33, 41);
    static readonly Color Field = Color.FromArgb(38, 42, 51);
    static readonly Color TextColor = Color.FromArgb(230, 232, 236);
    static readonly Color Muted = Color.FromArgb(150, 156, 168);
    static readonly Color Accent = Color.FromArgb(224, 122, 31);

    public InstallerForm()
    {
        // Scharf auf hoch aufgeloesten Bildschirmen: Prozess ist DPI-aware (Program.Main), Layout in 96-DPI-Pixeln
        // wird beim Anzeigen hochskaliert
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "Last Signal - Installer";
        ClientSize = new Size(640, 560);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Back;
        ForeColor = TextColor;
        Font = new Font("Segoe UI", 10f);

        // Kopf
        var header = new Panel { Left = 0, Top = 0, Width = 640, Height = 96, BackColor = Card };
        header.Controls.Add(new Label { Text = "LAST SIGNAL", Left = 28, Top = 16, AutoSize = true,
                                        Font = new Font("Segoe UI", 24f, FontStyle.Bold), ForeColor = Accent });
        header.Controls.Add(new Label { Text = "Dedicated servers for SurrounDead  -  installer", Left = 31, Top = 62,
                                        AutoSize = true, ForeColor = Muted });
        header.Controls.Add(new Panel { Left = 0, Top = 93, Width = 640, Height = 3, BackColor = Accent });
        Controls.Add(header);

        AddLabel("Game folder (found automatically)", 28, 116, Muted);
        StyleField(pathBox);
        pathBox.SetBounds(28, 140, 470, 28);
        Controls.Add(pathBox);
        StyleButton(AddButton("Browse...", 508, 139, 104, 30, Browse), Field);

        AddLabel("Chat key", 28, 184, Muted);
        StyleField(chatKeyBox);
        chatKeyBox.SetBounds(28, 208, 150, 28);
        chatKeyBox.Text = "RETURN";
        Controls.Add(chatKeyBox);
        AddLabel("Key name, e.g. RETURN, Y, F2 (can also be changed in game: J > SERVER)", 190, 212, Muted);

        cleanBox.Text = "Remove all other mods (recommended, prevents errors - they are moved to a backup folder)";
        cleanBox.SetBounds(28, 252, 590, 26);
        cleanBox.Checked = true;
        cleanBox.ForeColor = TextColor;
        cleanBox.FlatStyle = FlatStyle.Flat;
        Controls.Add(cleanBox);

        // Koop direkt zu einem Host (Adresse/Steam-Modus) ist gesperrt: Last Signal ist nur fuer Server, beigetreten
        // wird ueber die Serverliste im Spiel. Felder bleiben im Code, sind aber unsichtbar (immer IP-Modus).
        hostBox.Visible = false;
        Controls.Add(hostBox);
        ipBox.Checked = true;
        ipBox.Visible = false;
        Controls.Add(ipBox);

        installButton.Text = "INSTALL";
        installButton.SetBounds(28, 296, 200, 44);
        installButton.Font = new Font("Segoe UI", 12f, FontStyle.Bold);
        installButton.Click += DoInstall;
        StyleButton(installButton, Accent);
        installButton.ForeColor = Color.White;
        Controls.Add(installButton);

        uninstallButton.Text = "Uninstall";
        uninstallButton.SetBounds(240, 296, 130, 44);
        uninstallButton.Click += DoUninstall;
        StyleButton(uninstallButton, Field);
        Controls.Add(uninstallButton);

        logBox.SetBounds(28, 360, 584, 172);
        logBox.Multiline = true;
        logBox.ReadOnly = true;
        logBox.ScrollBars = ScrollBars.Vertical;
        logBox.BackColor = Card;
        logBox.ForeColor = TextColor;
        logBox.BorderStyle = BorderStyle.None;
        logBox.Font = new Font("Consolas", 9.5f);
        Controls.Add(logBox);
        ResumeLayout(false);

        string found = Game.Detect();
        if (found != null)
        {
            pathBox.Text = found;
            Log("Game found: " + found);
            string chatKeyFile = Game.ModFile(found, "chat_key.txt");
            if (File.Exists(chatKeyFile)) chatKeyBox.Text = File.ReadAllText(chatKeyFile).Trim();
        }
        else Log("Game not found automatically. Please choose the SurrounDead folder (Browse...).");
        ActiveControl = installButton;   // sonst ist der Pfad markiert
    }

    void AddLabel(string text, int x, int y, Color color)
    {
        Controls.Add(new Label { Text = text, Left = x, Top = y, AutoSize = true, ForeColor = color });
    }

    Button AddButton(string text, int x, int y, int w, int h, EventHandler click)
    {
        var b = new Button { Text = text, Left = x, Top = y, Width = w, Height = h };
        b.Click += click;
        Controls.Add(b);
        return b;
    }

    static void StyleButton(Button b, Color back)
    {
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.BackColor = back;
        b.ForeColor = TextColor;
        b.Cursor = Cursors.Hand;
    }

    static void StyleField(TextBox t)
    {
        t.BackColor = Field;
        t.ForeColor = TextColor;
        t.BorderStyle = BorderStyle.FixedSingle;
    }

    void Log(string line)
    {
        logBox.AppendText(line + Environment.NewLine);
        Application.DoEvents();
    }

    void Browse(object sender, EventArgs e)
    {
        using (var dlg = new FolderBrowserDialog { Description = "Choose the SurrounDead folder (steamapps\\common\\SurrounDead)" })
        {
            if (dlg.ShowDialog(this) != DialogResult.OK) return;
            string win64 = Game.ResolveWin64(dlg.SelectedPath);
            if (win64 == null) { Log("SurrounDead not found in: " + dlg.SelectedPath); return; }
            pathBox.Text = win64;
            Log("Game folder: " + win64);
        }
    }

    string CheckedWin64()
    {
        string win64 = Game.ResolveWin64(pathBox.Text);
        if (win64 == null) Log("Invalid game folder. Please choose it with \"Browse...\".");
        return win64;
    }

    void DoInstall(object sender, EventArgs e)
    {
        string win64 = CheckedWin64();
        if (win64 == null) return;
        string chatKey = chatKeyBox.Text.Trim().ToUpperInvariant();
        if (chatKey.Length == 0) chatKey = "RETURN";
        if (!Regex.IsMatch(chatKey, @"^[A-Z0-9_]{1,24}$"))
        {
            Log("Please enter the chat key as a name, e.g. RETURN, Y or F2.");
            return;
        }
        installButton.Enabled = uninstallButton.Enabled = false;
        try
        {
            Log("Installing to " + win64 + " ...");
            Game.Install(win64, Game.NormalizeHost(hostBox.Text), ipBox.Checked, cleanBox.Checked, Log);
            if (MasterUrl.Length > 0) File.WriteAllText(Game.ModFile(win64, "master_url.txt"), MasterUrl + "\n");
            File.WriteAllText(Game.ModFile(win64, "chat_key.txt"), chatKey + "\r\n");
            Log("Chat key: " + chatKey);
            Log("");
            Log("Done! Start SurrounDead, load your own save, press J and open the SERVER tab.");
        }
        catch (Exception ex) { Log("Error: " + ex.Message); }
        finally { installButton.Enabled = uninstallButton.Enabled = true; }
    }

    void DoUninstall(object sender, EventArgs e)
    {
        string win64 = CheckedWin64();
        if (win64 == null) return;
        if (MessageBox.Show(this, "Remove UE4SS and Last Signal from\n" + win64 + "?", Text,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        try { Game.Uninstall(win64, Log); Log("Uninstalled."); }
        catch (Exception ex) { Log("Error: " + ex.Message); }
    }
}

static class Program
{
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();

    // Ohne Argumente: Fenster. Zum Testen: --detect | --install <ordner> [host] [--ip] | --uninstall <ordner>
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            // Scharfe Schrift auf hoch aufgeloesten Bildschirmen (sonst skaliert Windows das Fenster unscharf hoch)
            try { SetProcessDPIAware(); } catch (EntryPointNotFoundException) { }
            Application.EnableVisualStyles();
            Application.Run(new InstallerForm());
            return 0;
        }
        try
        {
            if (args[0] == "--detect") { Console.WriteLine(Game.Detect() ?? "nicht gefunden"); return 0; }
            if (args[0] == "--screenshot" && args.Length > 1)
            {
                // Fenster als Bild (Pruefung des Aussehens ohne Bildschirm)
                try { SetProcessDPIAware(); } catch (EntryPointNotFoundException) { }
                Application.EnableVisualStyles();
                using (var form = new InstallerForm { StartPosition = FormStartPosition.Manual, Location = new Point(-5000, -5000), ShowInTaskbar = false })
                {
                    form.Show();
                    Application.DoEvents();
                    using (var bmp = new Bitmap(form.Width, form.Height))
                    {
                        form.DrawToBitmap(bmp, new Rectangle(0, 0, form.Width, form.Height));
                        bmp.Save(args[1]);
                    }
                }
                return 0;
            }
            string win64 = args.Length > 1 ? Game.ResolveWin64(args[1]) : null;
            if (win64 == null) { Console.WriteLine("Spielordner ungueltig"); return 2; }
            bool ip = Array.IndexOf(args, "--ip") >= 0;
            string host = args.Length > 2 && args[2] != "--ip" ? args[2] : "";
            if (args[0] == "--install") Game.Install(win64, host, ip, Array.IndexOf(args, "--clean") >= 0, Console.WriteLine);
            else if (args[0] == "--clean-only")
                Game.RemoveOtherMods(win64, new HashSet<string>(new[] { "LastSignal", "BPModLoaderMod" }, StringComparer.OrdinalIgnoreCase), Console.WriteLine);
            else if (args[0] == "--uninstall") Game.Uninstall(win64, Console.WriteLine);
            else { Console.WriteLine("Unbekannt: " + args[0]); return 2; }
            return 0;
        }
        catch (Exception ex) { Console.WriteLine("Fehler: " + ex.Message); return 1; }
    }
}
