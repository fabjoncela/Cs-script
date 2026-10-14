# Offline test for rate-limit header capture and response parsing.
# Uses a loopback TCP fixture; no GitHub request is made.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$lines=[IO.File]::ReadAllLines((Join-Path $root 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Launcher PowerShell marker not found.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher syntax error: '+$errors[0].Message)}
foreach($name in @('Set-CafeGitHubRateLimitDisplay','Update-CafeGitHubRateLimitFromHeaders','Invoke-CafeGitHubRestMethod')){
    $definition=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($definition.Count -ne 1){throw ('Missing or duplicate helper: '+$name)}
    Invoke-Expression $definition[0].Extent.Text
}
$serverSource=@'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class TestCafeRateLimitHttpServer : IDisposable {
    private readonly TcpListener listener;
    private readonly Thread worker;
    public string Url { get; private set; }
    public int RequestCount { get; private set; }
    public TestCafeRateLimitHttpServer() {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Url = "http://127.0.0.1:" + port + "/fixture";
        worker = new Thread(Serve);
        worker.IsBackground = true;
        worker.Start();
    }
    private void Serve() {
        try {
            using (TcpClient client = listener.AcceptTcpClient())
            using (NetworkStream stream = client.GetStream()) {
                client.ReceiveTimeout = 5000;
                byte[] buffer = new byte[4096];
                int read = stream.Read(buffer, 0, buffer.Length);
                if (read <= 0) return;
                RequestCount++;
                byte[] body = Encoding.UTF8.GetBytes("{\"ok\":true,\"count\":1}");
                string headers = "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/json; charset=utf-8\r\n" +
                    "X-RateLimit-Remaining: 42\r\n" +
                    "X-RateLimit-Limit: 60\r\n" +
                    "X-RateLimit-Reset: 1792000000\r\n" +
                    "X-RateLimit-Resource: core\r\n" +
                    "Content-Length: " + body.Length + "\r\nConnection: close\r\n\r\n";
                byte[] head = Encoding.ASCII.GetBytes(headers);
                stream.Write(head, 0, head.Length);
                stream.Write(body, 0, body.Length);
                stream.Flush();
            }
        } catch (ObjectDisposedException) { }
          catch (SocketException) { }
    }
    public void Dispose() {
        listener.Stop();
        if (worker.IsAlive) worker.Join(1000);
    }
}
'@
Add-Type -TypeDefinition $serverSource -Language CSharp
$script:GitHubRateLimitSnapshot=$null
$script:GitHubRateLimitLabel=$null
$server=New-Object TestCafeRateLimitHttpServer
try{
    $result=Invoke-CafeGitHubRestMethod -Uri $server.Url -Headers @{'Accept'='application/json';'User-Agent'='CafeLauncher-Test'} -TimeoutSec 5
    if(-not $result.ok -or $result.count -ne 1){throw 'The API wrapper did not parse the existing response body.'}
    if($script:GitHubRateLimitSnapshot.Remaining -ne 42 -or $script:GitHubRateLimitSnapshot.Limit -ne 60 -or
       -not $script:GitHubRateLimitSnapshot.CheckedAt){
        throw 'The API wrapper did not capture GitHub rate-limit response headers.'
    }
    if($server.RequestCount -ne 1){throw 'Rate-limit display must not make a separate HTTP request.'}
}finally{$server.Dispose()}
Write-Host 'PASS: the existing REST response supplies the displayed quota; one HTTP request only.'
