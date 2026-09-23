# Load test to verify autoscaling: sends many concurrent requests to /health
# and counts how many different replicas answer (min 2 → should rise toward max 5).
param(
    [string]$Url = "https://scanlyed-app.yellowhill-ee7c37ea.swedencentral.azurecontainerapps.io/health",
    [int]$Concurrency = 100,
    [int]$DurationSeconds = 180
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = $Concurrency   # default is 2 in Windows PowerShell → no real parallelism
Add-Type -AssemblyName System.Net.Http
$client   = New-Object System.Net.Http.HttpClient
$replicas = @{}
$end      = (Get-Date).AddSeconds($DurationSeconds)

while ((Get-Date) -lt $end) {
    $tasks = [System.Threading.Tasks.Task[]](1..$Concurrency | ForEach-Object { $client.GetStringAsync($Url) })
    try { [System.Threading.Tasks.Task]::WaitAll($tasks) } catch { }
    foreach ($t in $tasks) {
        if ($t.Status -ne 'RanToCompletion') { continue }
        $name = ($t.Result | ConvertFrom-Json).replica
        $replicas[$name] = [int]$replicas[$name] + 1
    }
    Write-Host ("{0:HH:mm:ss}  distinct replicas so far: {1}" -f (Get-Date), $replicas.Count)
}

$replicas.GetEnumerator() | Sort-Object Name | Format-Table @{n='Replica';e={$_.Name}}, @{n='Responses';e={$_.Value}}