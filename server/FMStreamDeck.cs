// FM-Stream Deck (Free Mobile Stream Deck) - servidor web portátil para a rede local, versão executável.
// Mesmo comportamento e mesma API do server.ps1 (painel em /panel).
// Compila com o csc do .NET Framework 4 que já vem no Windows (veja build.bat). C# 5, sem dependências.
// Licença MIT.
//
// Uso: FMStreamDeck.exe [--port 8080] [--obs-port 4455] [--no-firewall] [--remove-firewall] [--no-panel]
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

[assembly: AssemblyTitle("FM-Stream Deck")]
[assembly: AssemblyProduct("FM-Stream Deck")] // precisa ser igual ao nome do projeto (exigência da SignPath)
[assembly: AssemblyDescription("Servidor da rede local do FM-Stream Deck")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

class FMStreamDeck
{
    const string Version = "1.0.0";
    static string baseDir;
    static int port = 8080, obsPort = 4455;
    static bool noFirewall;
    static DateTime started;
    static volatile bool stopNow;
    static TcpListener listener;
    static readonly object sync = new object();
    static readonly Dictionary<string, Client> clients = new Dictionary<string, Client>();
    static readonly List<string> log = new List<string>(); // entradas já em JSON
    static DateTime fwAt = DateTime.MinValue, obsAt = DateTime.MinValue;
    static bool fwWeb, fwObs, obsOk;

    class Client { public DateTime First, Last; public int Count; }

    static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        { ".html", "text/html; charset=utf-8" }, { ".htm", "text/html; charset=utf-8" },
        { ".js", "application/javascript; charset=utf-8" }, { ".css", "text/css; charset=utf-8" },
        { ".json", "application/json; charset=utf-8" }, { ".webmanifest", "application/manifest+json" },
        { ".png", "image/png" }, { ".jpg", "image/jpeg" }, { ".jpeg", "image/jpeg" }, { ".gif", "image/gif" },
        { ".svg", "image/svg+xml" }, { ".ico", "image/x-icon" }, { ".webp", "image/webp" }
    };

    static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        Console.Title = "FM-Stream Deck - servidor";
        baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location).TrimEnd('\\');
        bool removeFirewall = false, noPanel = false;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            if ((a == "--port" || a == "--porta") && i + 1 < args.Length) int.TryParse(args[++i], out port);
            else if ((a == "--obs-port" || a == "--obs-porta") && i + 1 < args.Length) int.TryParse(args[++i], out obsPort);
            else if (a == "--no-firewall" || a == "--sem-firewall") noFirewall = true;
            else if (a == "--remove-firewall" || a == "--remover-firewall") removeFirewall = true;
            else if (a == "--no-panel" || a == "--sem-painel") noPanel = true;
            else if (a == "--help" || a == "-h" || a == "/?")
            {
                Console.WriteLine("FMStreamDeck.exe [--port 8080] [--obs-port 4455] [--no-firewall] [--remove-firewall] [--no-panel]");
                return 0;
            }
        }

        if (removeFirewall)
        {
            Console.WriteLine(RemoveFirewall() ? "Regras do FM-Stream Deck removidas do firewall." : "Não foi possível remover as regras (permissão negada?).");
            Pause();
            return 0;
        }

        for (int p = port; p < port + 11; p++)
        {
            try { listener = new TcpListener(IPAddress.Any, p); listener.Start(); port = p; break; }
            catch (SocketException) { listener = null; }
        }
        if (listener == null)
        {
            Console.WriteLine("Não foi possível abrir as portas " + port + " a " + (port + 10) + ". Use --port com outro número.");
            Pause();
            return 1;
        }
        started = DateTime.Now;
        string sfx = port == 80 ? "" : ":" + port;

        Console.WriteLine();
        Console.WriteLine("  FM-Stream Deck " + Version + " - servidor da rede local");
        Console.WriteLine("  -----------------------------------------------");
        Console.WriteLine();
        Console.WriteLine("  Abra num celular ou tablet da mesma rede:");
        Console.WriteLine();
        List<string[]> ips = LocalIPv4s();
        if (ips.Count == 0) Console.WriteLine("    (nenhuma rede encontrada; confira o Wi-Fi ou o cabo)");
        foreach (string[] ip in ips)
        {
            Console.ForegroundColor = ConsoleColor.Green;
            Console.Write("    http://" + ip[0] + sfx + "/");
            Console.ResetColor();
            Console.WriteLine("   (" + ip[1] + ")");
        }
        Console.WriteLine();
        RefreshFirewall(true);
        if (noFirewall) Console.WriteLine("  Firewall: não verificado (--no-firewall).");
        else if (fwWeb && fwObs) Console.WriteLine("  Firewall: portas " + port + " e " + obsPort + " liberadas para a rede local.");
        else Console.WriteLine("  Firewall: portas ainda não liberadas. Use o botão \"Liberar portas\" no painel.");
        Console.WriteLine("  Painel de gerenciamento (só neste PC): http://localhost" + sfx + "/panel");
        Console.WriteLine("  Deixe esta janela aberta. Para parar, use o painel, feche a janela ou aperte Ctrl+C.");
        Console.WriteLine();
        if (!noPanel) { try { Process.Start("http://localhost" + sfx + "/panel"); } catch (Exception) { } }

        while (!stopNow)
        {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); }
            catch (Exception) { if (stopNow) break; continue; }
            ThreadPool.QueueUserWorkItem(Handle, c);
        }
        Console.WriteLine("  Servidor parado pelo painel.");
        return 0;
    }

    /* ---------------- HTTP ---------------- */

    static void Handle(object state)
    {
        TcpClient client = (TcpClient)state;
        string remote = "?";
        try
        {
            client.ReceiveTimeout = 10000; client.SendTimeout = 10000;
            IPAddress remoteIp = ((IPEndPoint)client.Client.RemoteEndPoint).Address;
            IPAddress localIp = ((IPEndPoint)client.Client.LocalEndPoint).Address;
            remote = remoteIp.ToString();
            NetworkStream ns = client.GetStream();
            string head = ReadHead(ns);
            if (head == null) return;
            string[] lines = head.Split(new[] { "\r\n" }, StringSplitOptions.None);
            string[] first = lines[0].Split(' ');
            if (first.Length < 2) { SendText(ns, 400, "Bad Request", "Requisição inválida", false); return; }
            Dictionary<string, string> hdr = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length; i++)
            {
                int c = lines[i].IndexOf(':');
                if (c > 0) hdr[lines[i].Substring(0, c).Trim()] = lines[i].Substring(c + 1).Trim();
            }
            string method = first[0].ToUpperInvariant(), target = first[1];
            bool headOnly = method == "HEAD";
            int q = target.IndexOf('?');
            string path = q >= 0 ? target.Substring(0, q) : target;
            try { path = Uri.UnescapeDataString(path); } catch (Exception) { }

            // painel e API: só neste PC (loopback) e com Host local (evita DNS rebinding)
            if (path == "/panel" || path == "/panel/" || path.StartsWith("/api/"))
            {
                string host;
                hdr.TryGetValue("Host", out host);
                bool hostOk = host != null && Regex.IsMatch(host, @"^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$", RegexOptions.IgnoreCase);
                if (!IPAddress.IsLoopback(remoteIp) || !hostOk)
                {
                    SendText(ns, 403, "Forbidden", "O painel só pode ser aberto no PC que roda o servidor.", headOnly);
                    Log(remote, method, target, 403);
                    return;
                }
                if (path.StartsWith("/api/"))
                {
                    if (method == "GET" && path == "/api/status") { SendJson(ns, StatusJson()); return; }
                    string x;
                    hdr.TryGetValue("X-FMSD", out x);
                    // ações: só POST com cabeçalho próprio (um site qualquer não consegue enviar sem CORS)
                    if (method != "POST" || x != "1") { SendText(ns, 403, "Forbidden", "Ação não permitida", false); return; }
                    if (path == "/api/firewall/open") { bool ok = !noFirewall && OpenFirewall(); SendJson(ns, "{\"ok\":" + (ok ? "true" : "false") + "}"); Log(remote, method, path, 200); return; }
                    if (path == "/api/firewall/remove") { bool ok = !noFirewall && RemoveFirewall(); SendJson(ns, "{\"ok\":" + (ok ? "true" : "false") + "}"); Log(remote, method, path, 200); return; }
                    if (path == "/api/stop")
                    {
                        SendJson(ns, "{\"ok\":true}");
                        Log(remote, method, path, 200);
                        stopNow = true;
                        try { listener.Stop(); } catch (Exception) { }
                        return;
                    }
                    SendText(ns, 404, "Not Found", "Não encontrado", false);
                    return;
                }
                byte[] panel = FileOrEmbedded(Path.Combine(Path.Combine(baseDir, "server"), "panel.html"), "panel.html");
                if (panel == null) { SendText(ns, 404, "Not Found", "panel.html não encontrado", headOnly); return; }
                Send(ns, 200, "OK", "text/html; charset=utf-8", panel, headOnly, "");
                return;
            }

            if (method != "GET" && !headOnly)
            {
                SendText(ns, 405, "Method Not Allowed", "Método não permitido", false);
                Log(remote, method, target, 405);
                return;
            }
            TouchClient(remote);

            // raiz: abre o deck já apontando para o OBS deste PC (o IP pelo qual o aparelho chegou aqui)
            if (path == "/" || path == "")
            {
                string obsHost = IPAddress.IsLoopback(localIp) ? "localhost" : localIp.ToString();
                Send(ns, 302, "Found", "text/plain; charset=utf-8", new byte[0], true,
                    "Location: /obs-deck.html?host=" + obsHost + "&port=" + obsPort + "\r\n");
                Log(remote, method, target, 302);
                return;
            }

            byte[] body = null;
            string ext = Path.GetExtension(path), type;
            if (Types.TryGetValue(ext, out type) && !path.StartsWith("/server/", StringComparison.OrdinalIgnoreCase))
            {
                string full = null;
                try { full = Path.GetFullPath(Path.Combine(baseDir, path.TrimStart('/').Replace('/', '\\'))); } catch (Exception) { }
                // só arquivos desta pasta (e subpastas), sem sair dela com ../
                if (full != null && full.StartsWith(baseDir + "\\", StringComparison.OrdinalIgnoreCase) && File.Exists(full))
                    body = File.ReadAllBytes(full);
                else if (path.Equals("/obs-deck.html", StringComparison.OrdinalIgnoreCase))
                    body = Embedded("obs-deck.html");
            }
            if (body == null)
            {
                SendText(ns, 404, "Not Found", "Não encontrado", headOnly);
                Log(remote, method, target, 404);
                return;
            }
            Send(ns, 200, "OK", type, body, headOnly, "");
            Log(remote, method, target, 200);
        }
        catch (Exception) { }
        finally { try { client.Close(); } catch (Exception) { } }
    }

    static string ReadHead(NetworkStream ns)
    {
        MemoryStream ms = new MemoryStream();
        byte[] buf = new byte[4096];
        while (ms.Length < 16384)
        {
            int n = ns.Read(buf, 0, buf.Length);
            if (n <= 0) break;
            ms.Write(buf, 0, n);
            string s = Encoding.ASCII.GetString(ms.ToArray());
            int end = s.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (end >= 0) return s.Substring(0, end);
        }
        return null;
    }

    static void Send(NetworkStream ns, int code, string reason, string type, byte[] body, bool headOnly, string extra)
    {
        string h = "HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length +
            "\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\n" + extra + "Connection: close\r\n\r\n";
        byte[] hb = Encoding.ASCII.GetBytes(h);
        ns.Write(hb, 0, hb.Length);
        if (!headOnly && body.Length > 0) ns.Write(body, 0, body.Length);
    }
    static void SendText(NetworkStream ns, int code, string reason, string text, bool headOnly)
    {
        Send(ns, code, reason, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes(text), headOnly, "");
    }
    static void SendJson(NetworkStream ns, string json)
    {
        Send(ns, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json), false, "");
    }

    static byte[] FileOrEmbedded(string file, string resource)
    {
        if (File.Exists(file)) return File.ReadAllBytes(file);
        return Embedded(resource);
    }
    static byte[] Embedded(string name)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (s == null) return null;
            MemoryStream ms = new MemoryStream();
            s.CopyTo(ms);
            return ms.ToArray();
        }
    }

    /* ---------------- estado / painel ---------------- */

    static string J(string s)
    {
        StringBuilder b = new StringBuilder("\"");
        foreach (char c in s ?? "")
        {
            if (c == '"' || c == '\\') b.Append('\\').Append(c);
            else if (c < 0x20) b.Append("\\u").Append(((int)c).ToString("x4"));
            else b.Append(c);
        }
        return b.Append('"').ToString();
    }
    static string Iso(DateTime d) { return J(d.ToString("o", CultureInfo.InvariantCulture)); }

    static void TouchClient(string ip)
    {
        lock (sync)
        {
            Client c;
            if (!clients.TryGetValue(ip, out c)) { c = new Client { First = DateTime.Now }; clients[ip] = c; }
            c.Last = DateTime.Now;
            c.Count++;
        }
    }

    static void Log(string remote, string method, string target, int code)
    {
        lock (sync)
        {
            Console.ForegroundColor = code >= 400 ? ConsoleColor.Yellow : ConsoleColor.DarkGray;
            Console.WriteLine("  [" + DateTime.Now.ToString("HH:mm:ss") + "] " + remote + "  " + method + " " + target + "  " + code);
            Console.ResetColor();
            log.Add("{\"t\":" + Iso(DateTime.Now) + ",\"ip\":" + J(remote) + ",\"method\":" + J(method) + ",\"path\":" + J(target) + ",\"code\":" + code + "}");
            while (log.Count > 60) log.RemoveAt(0);
        }
    }

    static string StatusJson()
    {
        RefreshFirewall(false);
        bool obs = TestObs();
        StringBuilder b = new StringBuilder();
        b.Append("{\"app\":\"FM-Stream Deck\",\"version\":").Append(J(Version)).Append(",\"server\":\"exe\"");
        b.Append(",\"started\":").Append(Iso(started)).Append(",\"uptime\":").Append((int)(DateTime.Now - started).TotalSeconds);
        b.Append(",\"port\":").Append(port).Append(",\"obsPort\":").Append(obsPort);
        b.Append(",\"obsReachable\":").Append(obs ? "true" : "false");
        b.Append(",\"firewallChecked\":").Append(noFirewall ? "false" : "true");
        b.Append(",\"firewall\":{\"web\":").Append(fwWeb ? "true" : "false").Append(",\"obs\":").Append(fwObs ? "true" : "false").Append("}");
        b.Append(",\"urls\":[");
        string sfx = port == 80 ? "" : ":" + port;
        List<string[]> ips = LocalIPv4s();
        for (int i = 0; i < ips.Count; i++)
        {
            if (i > 0) b.Append(',');
            b.Append("{\"ip\":").Append(J(ips[i][0])).Append(",\"iface\":").Append(J(ips[i][1])).Append(",\"url\":").Append(J("http://" + ips[i][0] + sfx + "/")).Append('}');
        }
        b.Append("],\"clients\":[");
        lock (sync)
        {
            bool firstC = true;
            foreach (KeyValuePair<string, Client> kv in clients)
            {
                if ((DateTime.Now - kv.Value.Last).TotalMinutes > 30) continue;
                if (!firstC) b.Append(',');
                firstC = false;
                b.Append("{\"ip\":").Append(J(kv.Key)).Append(",\"local\":").Append(kv.Key == "127.0.0.1" ? "true" : "false")
                    .Append(",\"first\":").Append(Iso(kv.Value.First)).Append(",\"last\":").Append(Iso(kv.Value.Last))
                    .Append(",\"requests\":").Append(kv.Value.Count).Append('}');
            }
            b.Append("],\"log\":[");
            int n = 0;
            for (int i = log.Count - 1; i >= 0 && n < 40; i--, n++)
            {
                if (n > 0) b.Append(',');
                b.Append(log[i]);
            }
        }
        b.Append("]}");
        return b.ToString();
    }

    static bool TestObs()
    {
        lock (sync) { if ((DateTime.Now - obsAt).TotalSeconds < 3) return obsOk; }
        bool ok = false;
        try
        {
            using (TcpClient c = new TcpClient())
            {
                IAsyncResult ar = c.BeginConnect("127.0.0.1", obsPort, null, null);
                if (ar.AsyncWaitHandle.WaitOne(300)) { try { c.EndConnect(ar); ok = true; } catch (Exception) { } }
            }
        }
        catch (Exception) { }
        lock (sync) { obsOk = ok; obsAt = DateTime.Now; }
        return ok;
    }

    static List<string[]> LocalIPv4s()
    {
        List<string[]> list = new List<string[]>();
        foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (UnicastIPAddressInformation ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                string ip = ua.Address.ToString();
                if (ip.StartsWith("169.254.")) continue;
                list.Add(new[] { ip, ni.Name });
            }
        }
        return list;
    }

    /* ---------------- firewall ---------------- */

    static string RuleWeb { get { return "FM-Stream Deck - pagina (TCP " + port + ")"; } }
    static string RuleObs { get { return "FM-Stream Deck - OBS WebSocket (TCP " + obsPort + ")"; } }

    static void RefreshFirewall(bool force)
    {
        if (noFirewall) return;
        lock (sync) { if (!force && (DateTime.Now - fwAt).TotalSeconds < 10) return; }
        bool w = RuleExists(RuleWeb), o = RuleExists(RuleObs);
        lock (sync) { fwWeb = w; fwObs = o; fwAt = DateTime.Now; }
    }

    static bool RuleExists(string name)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("netsh", "advfirewall firewall show rule name=\"" + name + "\"");
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi))
            {
                p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                return p.ExitCode == 0;
            }
        }
        catch (Exception) { return false; }
    }

    // remoteip=localsubnet: só aceita conexões de aparelhos da mesma rede local
    static bool OpenFirewall()
    {
        string cmd =
            "netsh advfirewall firewall delete rule name=\"" + RuleWeb + "\" >nul 2>&1 & " +
            "netsh advfirewall firewall add rule name=\"" + RuleWeb + "\" dir=in action=allow protocol=TCP localport=" + port + " remoteip=localsubnet profile=any >nul & " +
            "netsh advfirewall firewall delete rule name=\"" + RuleObs + "\" >nul 2>&1 & " +
            "netsh advfirewall firewall add rule name=\"" + RuleObs + "\" dir=in action=allow protocol=TCP localport=" + obsPort + " remoteip=localsubnet profile=any >nul";
        bool ok = RunElevated(cmd);
        RefreshFirewall(true);
        return ok && fwWeb && fwObs;
    }

    static bool RemoveFirewall()
    {
        string cmd =
            "netsh advfirewall firewall delete rule name=\"" + RuleWeb + "\" >nul 2>&1 & " +
            "netsh advfirewall firewall delete rule name=\"" + RuleObs + "\" >nul 2>&1";
        bool ok = RunElevated(cmd);
        bool w = RuleExists(RuleWeb), o = RuleExists(RuleObs);
        lock (sync) { fwWeb = w; fwObs = o; fwAt = DateTime.Now; }
        return ok && !w && !o;
    }

    static bool RunElevated(string cmd)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/c " + cmd);
            psi.Verb = "runas";
            psi.UseShellExecute = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process p = Process.Start(psi)) { p.WaitForExit(); }
            return true;
        }
        catch (Win32Exception) { return false; } // usuário recusou o UAC
    }

    static void Pause()
    {
        if (Console.IsInputRedirected) return;
        Console.Write("Aperte Enter para sair.");
        Console.ReadLine();
    }
}
