<#
  Converts McCance & Widdowson's Composition of Foods Integrated Dataset
  (CoFID) into the trimmed JSON the food search uses.

  CoFID is published as an Excel workbook under the Open Government Licence
  v3.0, with no API. For a national reference table revised every few years
  that is the right shape: convert it once, ship the result as a static asset,
  and search it locally -- no key, no rate limit, no latency, works offline.

  Usage
    Download "CoFID 2021 – McCance and Widdowson's ..." (.xlsx) from
    https://www.gov.uk/government/publications/composition-of-foods-integrated-dataset-cofid

    Inspect what the script can see, without writing anything:
      .\tools\convert-cofid.ps1 -Xlsx .\CoFID.xlsx -DryRun

    Convert:
      .\tools\convert-cofid.ps1 -Xlsx .\CoFID.xlsx

  Reads the .xlsx directly (it is a zip of XML), so Excel is not required.
  Columns are matched by header text rather than position, because the exact
  layout differs between CoFID editions.
#>

param(
  [Parameter(Mandatory = $true)][string]$Xlsx,
  [string]$Out = "api/data/cofid.json",
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path $Xlsx)) { throw "Workbook not found: $Xlsx" }
$full = (Resolve-Path $Xlsx).Path

function Get-ColIndex([string]$ref) {
  # "BC12" -> zero-based column index
  $letters = ($ref -replace '[0-9]', '')
  $n = 0
  foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
  return $n - 1
}

# CoFID marks values it does not have. Those must become *absent*, never 0 --
# a missing figure counted as zero would flatter every total that uses it.
#   "Tr" = trace, small enough to treat as zero
#   "N"  = not determined,  "" = not present
function Read-Value($raw) {
  if ($null -eq $raw) { return $null }
  $s = ([string]$raw).Trim()
  if ($s -eq '') { return $null }
  if ($s -match '^(N|n)$') { return $null }
  if ($s -match '^(Tr|tr|TR)$') { return 0.0 }
  $s = $s -replace '[^0-9\.\-]', ''      # strip footnote markers
  if ($s -eq '' -or $s -eq '-') { return $null }
  $d = 0.0
  if ([double]::TryParse($s, [ref]$d)) { return $d }
  return $null
}

$zip = [System.IO.Compression.ZipFile]::OpenRead($full)
try {
  # Zip entry names should use '/', but some producers emit '\'. Normalise so
  # the lookups below work either way.
  function EntryName($e) { return ($e.FullName -replace '\\', '/') }

  # ---- shared strings ----
  $shared = @()
  $ssEntry = $zip.Entries | Where-Object { (EntryName $_) -eq 'xl/sharedStrings.xml' }
  if ($ssEntry) {
    $sr = New-Object System.IO.StreamReader($ssEntry.Open())
    [xml]$ssXml = $sr.ReadToEnd(); $sr.Close()
    foreach ($si in $ssXml.sst.si) {
      if ($si.t -is [string]) { $shared += $si.t }
      elseif ($si.t.'#text')  { $shared += $si.t.'#text' }
      elseif ($si.r)          { $shared += (($si.r | ForEach-Object { if ($_.t.'#text') { $_.t.'#text' } else { [string]$_.t } }) -join '') }
      else                    { $shared += '' }
    }
  }
  Write-Host "shared strings: $($shared.Count)"

  # ---- sheet names ----
  $wbEntry = $zip.Entries | Where-Object { (EntryName $_) -eq 'xl/workbook.xml' }
  if (-not $wbEntry) { throw "Not a readable .xlsx: no xl/workbook.xml inside $full" }
  $sr = New-Object System.IO.StreamReader($wbEntry.Open())
  [xml]$wbXml = $sr.ReadToEnd(); $sr.Close()
  $sheetNames = @($wbXml.workbook.sheets.sheet | ForEach-Object { $_.name })

  $sheetEntries = @($zip.Entries | Where-Object { (EntryName $_) -match '^xl/worksheets/sheet\d+\.xml$' } |
    Sort-Object { [int]((EntryName $_) -replace '[^0-9]', '') })

  $best = $null

  for ($si = 0; $si -lt $sheetEntries.Count; $si++) {
    $entry = $sheetEntries[$si]
    $name = if ($si -lt $sheetNames.Count) { $sheetNames[$si] } else { $entry.FullName }

    $sr = New-Object System.IO.StreamReader($entry.Open())
    [xml]$shXml = $sr.ReadToEnd(); $sr.Close()
    $rows = @($shXml.worksheet.sheetData.row)
    if ($rows.Count -lt 5) { continue }

    # Build a grid of the first 40 rows so we can hunt for the header.
    $grid = @{}
    $maxCol = 0
    $limit = [Math]::Min($rows.Count, 40)
    for ($r = 0; $r -lt $limit; $r++) {
      foreach ($c in @($rows[$r].c)) {
        $ci = Get-ColIndex $c.r
        if ($ci -gt $maxCol) { $maxCol = $ci }
        $v = $c.v
        if ($c.t -eq 's' -and $null -ne $v) { $v = $shared[[int]$v] }
        $grid["$r,$ci"] = $v
      }
    }

    # The header row is the one naming a food and a protein column.
    $headerRow = -1
    for ($r = 0; $r -lt $limit; $r++) {
      $joined = ''
      for ($c = 0; $c -le $maxCol; $c++) { $joined += ' ' + [string]$grid["$r,$c"] }
      $j = $joined.ToLower()
      if ($j -match 'food name' -and $j -match 'protein') { $headerRow = $r; break }
    }
    if ($headerRow -lt 0) { continue }

    $headers = @()
    for ($c = 0; $c -le $maxCol; $c++) { $headers += ([string]$grid["$headerRow,$c"]).Trim() }

    function Find-Col([string[]]$hdrs, [string]$pattern) {
      for ($i = 0; $i -lt $hdrs.Count; $i++) {
        if ($hdrs[$i] -and ($hdrs[$i].ToLower() -replace '\s+', ' ') -match $pattern) { return $i }
      }
      return -1
    }

    $cName = Find-Col $headers 'food name'
    $cKcal = Find-Col $headers 'energy.*kcal|kcal'
    $cProt = Find-Col $headers '^protein'
    $cFat  = Find-Col $headers '^fat(\s|\()|total fat'
    $cCarb = Find-Col $headers 'carbohydrate'

    Write-Host ""
    Write-Host "sheet '$name' (header row $($headerRow + 1))"
    Write-Host ("  name=$cName kcal=$cKcal protein=$cProt fat=$cFat carb=$cCarb")

    if ($cName -ge 0 -and $cKcal -ge 0 -and $cProt -ge 0) {
      if (-not $best) {
        $best = [pscustomobject]@{
          Name = $name; Entry = $entry; HeaderRow = $headerRow
          CName = $cName; CKcal = $cKcal; CProt = $cProt; CFat = $cFat; CCarb = $cCarb
          Headers = $headers
        }
      }
    }
  }

  if (-not $best) { throw "Couldn't find a sheet with food name + energy + protein columns. Run with -DryRun and check the output above." }

  Write-Host ""
  Write-Host "using sheet: $($best.Name)"
  Write-Host "  name   <- '$($best.Headers[$best.CName])'"
  Write-Host "  kcal   <- '$($best.Headers[$best.CKcal])'"
  Write-Host "  protein<- '$($best.Headers[$best.CProt])'"
  if ($best.CFat  -ge 0) { Write-Host "  fat    <- '$($best.Headers[$best.CFat])'" }
  if ($best.CCarb -ge 0) { Write-Host "  carb   <- '$($best.Headers[$best.CCarb])'" }

  # ---- read the whole sheet ----
  $sr = New-Object System.IO.StreamReader($best.Entry.Open())
  [xml]$shXml = $sr.ReadToEnd(); $sr.Close()
  $rows = @($shXml.worksheet.sheetData.row)

  $foods = New-Object System.Collections.ArrayList
  $stats = @{ total = 0; kcal = 0; p = 0; c = 0; f = 0 }

  for ($r = $best.HeaderRow + 1; $r -lt $rows.Count; $r++) {
    $cells = @{}
    foreach ($c in @($rows[$r].c)) {
      $ci = Get-ColIndex $c.r
      $v = $c.v
      if ($c.t -eq 's' -and $null -ne $v) { $v = $shared[[int]$v] }
      $cells[$ci] = $v
    }

    $nm = [string]$cells[$best.CName]
    if (-not $nm -or $nm.Trim() -eq '') { continue }
    $kcal = Read-Value $cells[$best.CKcal]
    if ($null -eq $kcal) { continue }        # no energy value, nothing to log

    $stats.total++; $stats.kcal++

    # CoFID is per 100g; the app stores everything per ONE base unit, so
    # divide here and the client never has to remember a divisor.
    $o = [ordered]@{ n = $nm.Trim(); k = [Math]::Round($kcal / 100.0, 5) }

    $p = if ($best.CProt -ge 0) { Read-Value $cells[$best.CProt] } else { $null }
    $c2 = if ($best.CCarb -ge 0) { Read-Value $cells[$best.CCarb] } else { $null }
    $f = if ($best.CFat  -ge 0) { Read-Value $cells[$best.CFat]  } else { $null }
    if ($null -ne $p)  { $o.p = [Math]::Round($p  / 100.0, 5); $stats.p++ }
    if ($null -ne $c2) { $o.c = [Math]::Round($c2 / 100.0, 5); $stats.c++ }
    if ($null -ne $f)  { $o.f = [Math]::Round($f  / 100.0, 5); $stats.f++ }

    [void]$foods.Add($o)
  }

  Write-Host ""
  Write-Host "foods with an energy value : $($stats.total)"
  Write-Host ("  with protein : {0} ({1:P0})" -f $stats.p, ($stats.p / [Math]::Max(1, $stats.total)))
  Write-Host ("  with carbs   : {0} ({1:P0})" -f $stats.c, ($stats.c / [Math]::Max(1, $stats.total)))
  Write-Host ("  with fat     : {0} ({1:P0})" -f $stats.f, ($stats.f / [Math]::Max(1, $stats.total)))

  if ($DryRun) { Write-Host ""; Write-Host "-DryRun: nothing written."; return }

  $payload = [ordered]@{
    source  = 'cofid'
    licence = 'Open Government Licence v3.0'
    note    = 'McCance and Widdowson''s The Composition of Foods Integrated Dataset. Values per one gram.'
    foods   = $foods
  }

  $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location) $Out }
  $dir = Split-Path $outPath -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  ($payload | ConvertTo-Json -Depth 5 -Compress) | Out-File -FilePath $outPath -Encoding utf8 -NoNewline

  $kb = [Math]::Round((Get-Item $outPath).Length / 1KB)
  Write-Host ""
  Write-Host "wrote $outPath  ($kb KB, $($foods.Count) foods)"
}
finally {
  $zip.Dispose()
}
