# Runs every GPU testbench and prints one line each. Run from the repo root.
$rtl = Get-ChildItem gpu\rtl\*.v | ForEach-Object { $_.FullName }

# wrapper testbenches only work when compiled together with their base testbench
$bases = @{
    tb_wrap4     = 'tb_mem_ctrl_param'
    tb_wrap16    = 'tb_mem_ctrl_param'
    tb_wrap_id7  = 'tb_coreid'
    tb_wrap_id23 = 'tb_coreid'
}

$pass = 0; $bad = 0
foreach ($tb in Get-ChildItem gpu\tb\*.v) {
    $file = $tb.BaseName
    # the top module name is the first "module ..." line in the file
    $top = (Select-String -Path $tb.FullName -Pattern '^\s*module\s+(\w+)' | Select-Object -First 1).Matches[0].Groups[1].Value
    $files = @($tb.FullName)
    if ($bases.ContainsKey($file)) { $files += (Resolve-Path "gpu\tb\$($bases[$file]).v").Path }

    $vvp = Join-Path $env:TEMP "$file.vvp"
    Remove-Item $vvp -ErrorAction SilentlyContinue
    $null = iverilog -g2012 -I gpu\sw -s $top -o $vvp @files $rtl 2>&1

    if (-not (Test-Path $vvp)) {
        Write-Host ("{0,-22} COMPILE ERROR" -f $file) -ForegroundColor Red; $bad++; continue
    }
    $out = vvp $vvp 2>&1 | Out-String
    if ($out -match 'ALL TESTS PASSED') {
        Write-Host ("{0,-22} PASS" -f $file) -ForegroundColor Green; $pass++
    } elseif ($out -match 'FAIL') {
        Write-Host ("{0,-22} FAIL" -f $file) -ForegroundColor Red; $bad++
    } else {
        $last = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' | '
        Write-Host ("{0,-22} NO VERDICT: {1}" -f $file, $last) -ForegroundColor Yellow; $bad++
    }
}
Write-Host ""
Write-Host "$pass passed, $bad not passed"
