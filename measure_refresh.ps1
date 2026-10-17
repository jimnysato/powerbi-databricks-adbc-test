<#
Times full refreshes of the 'orders' table in every open Power BI Desktop model built by build_pbip.py.
Each open model is identified by the driver option in its Power Query source (ODBC, ADBC, ADBC-REST).
Refreshes run one at a time and the order rotates each round, so no variant always goes first.

Usage (Power BI Desktop open with the models already loaded once as warm-up):
  powershell -ExecutionPolicy Bypass -File measure_refresh.ps1 -ListOnly
  powershell -ExecutionPolicy Bypass -File measure_refresh.ps1 -Rounds 6 -Output results\my-run.csv
#>
param([int]$Rounds = 3, [switch]$ListOnly, [string]$Output = 'results\my-run.csv')
$ErrorActionPreference = 'Stop'

# TOM + ADOMD.NET client libraries, downloaded once from nuget.org
$pkgDir = "$env:TEMP\tom_nuget"
foreach ($p in 'Microsoft.AnalysisServices.retail.amd64', 'Microsoft.AnalysisServices.AdomdClient.retail.amd64') {
    if (-not (Test-Path "$pkgDir\$p\lib\net45")) {
        $id = $p.ToLower()
        $v = (Invoke-RestMethod "https://api.nuget.org/v3-flatcontainer/$id/index.json").versions | Where-Object { $_ -notmatch '-' } | Select-Object -Last 1
        New-Item -ItemType Directory -Force $pkgDir | Out-Null
        Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$id/$v/$id.$v.nupkg" -OutFile "$pkgDir\$p.zip" -UseBasicParsing
        Expand-Archive "$pkgDir\$p.zip" -DestinationPath "$pkgDir\$p" -Force
        Remove-Item "$pkgDir\$p.zip"
    }
}
$lib = "$pkgDir\Microsoft.AnalysisServices.retail.amd64\lib\net45"
Add-Type -Path "$lib\Microsoft.AnalysisServices.Core.dll"
Add-Type -Path "$lib\Microsoft.AnalysisServices.Tabular.dll"
Add-Type -Path "$pkgDir\Microsoft.AnalysisServices.AdomdClient.retail.amd64\lib\net45\Microsoft.AnalysisServices.AdomdClient.dll"

function Count-Rows($port) {
    $c = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection "Data Source=localhost:$port"
    $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = "EVALUATE ROW(""n"", COUNTROWS('orders'))"
    $rd = $cmd.ExecuteReader(); $null = $rd.Read(); $n = $rd.GetValue(0); $rd.Close(); $c.Close(); return $n
}

# Find each Desktop instance (msmdsrv.exe) and which driver its model uses
$targets = @{}
$listening = Get-NetTCPConnection -State Listen
foreach ($proc in Get-Process msmdsrv -ErrorAction SilentlyContinue) {
    $port = ($listening | Where-Object OwningProcess -eq $proc.Id | Select-Object -First 1).LocalPort
    $s = New-Object Microsoft.AnalysisServices.Tabular.Server
    $s.Connect("Data Source=localhost:$port")
    if ($s.Databases.Count -gt 0) {
        $t = $s.Databases[0].Model.Tables.Find('orders')
        if ($t) {
            $m = $t.Partitions[0].Source.Expression
            if ($m -match 'Protocol = "rest"') { $targets['ADBC-REST'] = $port }
            elseif ($m -match 'Implementation = "1.0"') { $targets['ODBC'] = $port }
            elseif ($m -match 'Implementation = "2.0"') { $targets['ADBC'] = $port }
        }
    }
    $s.Disconnect()
}
foreach ($k in $targets.Keys) { Write-Output "$k -> port $($targets[$k]) | rows loaded: $(Count-Rows $targets[$k])" }
if ($ListOnly -or $targets.Count -lt 2) { return }

$results = @()
for ($r = 1; $r -le $Rounds; $r++) {
    $names = @($targets.Keys | Sort-Object)
    $k = ($r - 1) % $names.Count
    $order = @($names[$k..($names.Count - 1)]) + @(if ($k -gt 0) { $names[0..($k - 1)] })
    foreach ($drv in $order) {
        $s = New-Object Microsoft.AnalysisServices.Tabular.Server
        $s.Connect("Data Source=localhost:$($targets[$drv])")
        $db = $s.Databases[0].Name
        $tmsl = '{ "refresh": { "type": "full", "objects": [{ "database": "' + $db + '", "table": "orders" }] } }'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = $s.Execute($tmsl)
        $sw.Stop()
        $errors = ($out | ForEach-Object { $_.Messages } | Where-Object { $_ -is [Microsoft.AnalysisServices.XmlaError] } | ForEach-Object { $_.Description }) -join '; '
        $s.Disconnect()
        $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $rows = Count-Rows $targets[$drv]
        Write-Output ("round {0} | {1} | {2} s | {3} rows {4}" -f $r, $drv, $sec.ToString([Globalization.CultureInfo]::InvariantCulture), $rows, $errors)
        $results += [pscustomobject]@{ round = $r; driver = $drv; seconds = $sec.ToString([Globalization.CultureInfo]::InvariantCulture); rows_loaded = $rows; error = $errors }
    }
}
$results | Export-Csv $Output -NoTypeInformation -Encoding UTF8
foreach ($d in ($targets.Keys | Sort-Object)) {
    $v = ($results | Where-Object driver -eq $d | ForEach-Object { [double]::Parse($_.seconds, [Globalization.CultureInfo]::InvariantCulture) }) | Sort-Object
    Write-Output "$d median: $($v[[int][math]::Floor($v.Count/2)]) s  (all: $($v -join ', '))"
}
