# Jarvis Chat - o passo que ENTREGA.
# Agendador de Tarefas do Windows, a cada 5 minutos.
#
# Por que 5 min: para acertar "10 min antes da reuniao das 10:30". O escuta.ps1,
# de 15 em 15 min, cairia em 10:15 e 10:30 e erraria a hora.
#
# Por que quase nao custa: a checagem e PowerShell puro num arquivo local. Nas
# ~280 execucoes/dia em que nada venceu, o script sai em meio segundo sem chamar
# nada. So quando tem alerta de verdade (umas 5 a 10 vezes por dia) ele chama
# `claude -p` com Haiku e um prompt de 3 linhas, usando o mesmo MCP que o resumo
# das 7h ja usa. Nenhuma credencial nova, nenhum webhook.

$ErrorActionPreference = "Stop"

# --- Acento: o PowerShell 5.1 manda texto para executavel externo usando a
# codificacao antiga do console (Windows-1252/OEM), e todo acento chega como "?"
# do outro lado. As duas linhas abaixo forcam UTF-8 no cano. Sem elas, o alerta
# sai "voc? n?o resolveu" em vez de "voce nao resolveu" com acento.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = New-Object System.Text.UTF8Encoding $false


$base    = Split-Path $PSScriptRoot -Parent
$espelho = Join-Path $base "alertas-pendentes.json"
$fila    = Join-Path $base "disparados.jsonl"   # handoff: o escuta.ps1 drena isto
$ledger  = Join-Path $base "entregues.log"     # dedupe proprio; ninguem mais mexe
$avisos  = Join-Path $base "avisos-urgentes.jsonl"
$logDir  = Join-Path $base "logs"

# Destino unico, por decisao: tudo cai no espaco pessoal.
$spaceAlerta     = "spaces/SEU_SPACE_ID"
$spaceAlertaNome = "Alertas do Jarvis"

# Alerta que passou mais que isso da hora nao sai: avisar de reuniao que comecou
# ha 2h e pior que calar. O jarvis.podar() marca esses como expirado.
$toleranciaMin = 90

$agora = (Get-Date).ToUniversalTime()

# --------------------------------------------------- ja entreguei? (dedupe)
# Ledger proprio de proposito: o disparados.jsonl e esvaziado pelo escuta.ps1, e
# se uma run dele morresse no meio o alerta sairia duas vezes.
$jaEntregues = @{}
if (Test-Path $ledger) {
    foreach ($linha in (Get-Content $ledger -Encoding utf8)) {
        $id = ($linha -split "`t")[0]
        if ($id) { $jaEntregues[$id] = $true }
    }
}

# ------------------------------------------------------------ o que venceu
$aPostar = New-Object System.Collections.ArrayList
if (Test-Path $espelho) {
    $bruto = Get-Content $espelho -Raw -Encoding utf8
    if ($bruto -and $bruto.Trim().Length -gt 2) {
        try { $alertas = $bruto | ConvertFrom-Json } catch { $alertas = @() }
        foreach ($a in $alertas) {
            if ($jaEntregues.ContainsKey([string]$a.id)) { continue }
            try { $quando = ([datetime]$a.alerta_em_utc).ToUniversalTime() } catch { continue }
            if ($quando -gt $agora) { continue }
            $atrasoMin = [int]($agora - $quando).TotalMinutes
            if ($atrasoMin -gt $toleranciaMin) { continue }

            $texto = $a.mensagem
            if ($atrasoMin -gt 12) {
                $texto = $texto + "`n_(atrasado $atrasoMin min - a maquina estava fora do ar)_"
            }
            [void]$aPostar.Add([pscustomobject]@{ id = [string]$a.id; texto = $texto; atraso = $atrasoMin })
        }
    }
}

# avisos de falha do proprio Jarvis (sem id: entrega e esquece)
$avisosTexto = New-Object System.Collections.ArrayList
if (Test-Path $avisos) {
    foreach ($linha in (Get-Content $avisos -Encoding utf8)) {
        if ($linha.Trim().Length -lt 3) { continue }
        try { [void]$avisosTexto.Add(($linha | ConvertFrom-Json).mensagem) } catch { }
    }
}

# O caso normal, ~280x por dia: nada vencido, sai sem gastar nada.
if ($aPostar.Count -eq 0 -and $avisosTexto.Count -eq 0) { exit 0 }

# ------------------------------------------------------------------ postar
# Uma mensagem por alerta (cada uma tem sua propria hora e seu proprio assunto).
# Os avisos de falha vao juntos numa ultima mensagem.
$blocos = New-Object System.Collections.ArrayList
foreach ($item in $aPostar) { [void]$blocos.Add($item.texto) }
if ($avisosTexto.Count -gt 0) { [void]$blocos.Add(($avisosTexto -join "`n")) }

$listaJson = ($blocos | ConvertTo-Json -Compress -Depth 3)
if ($blocos.Count -eq 1) { $listaJson = "[$listaJson]" }

$prompt = @"
Poste as mensagens abaixo no Google Chat, no espaco $spaceAlerta ("$spaceAlertaNome").

Use mcp__google-workspace__send_message, UMA chamada por item da lista, passando
sempre user_google_email: "voce@suaempresa.com" (o default do MCP e outra conta).

Poste o texto EXATAMENTE como esta. Nao reescreva, nao resuma, nao acrescente nada,
nao comente. Ele ja foi escrito para ser lido assim.

Lista (JSON):
$listaJson

Ao final imprima apenas: postadas <n> de $($blocos.Count).
"@

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$stamp = Get-Date -Format "yyyyMMdd-HHmm"
$log = Join-Path $logDir "disparo-$stamp.log"

Set-Location $base
$prompt | & claude -p --model claude-haiku-4-5-20251001 `
    --allowedTools "mcp__google-workspace__send_message" `
    --permission-mode acceptEdits | Tee-Object -FilePath $log
$codigo = $LASTEXITCODE

if ($codigo -ne 0) {
    # Nao marca nada como entregue: a proxima rodada de 5 min tenta de novo,
    # e a tolerancia de 90 min da margem de sobra.
    Write-Output "FALHOU (codigo $codigo) - nada marcado, tenta de novo em 5 min"
    exit 1
}

# --------------------------------------------------- anotar o que saiu
$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
foreach ($item in $aPostar) {
    [System.IO.File]::AppendAllText($ledger, "$($item.id)`t$ts`n", [System.Text.Encoding]::UTF8)
    $linha = '{"id": ' + $item.id + ', "disparado_em": "' + $ts + '", "nota": "atraso ' + $item.atraso + ' min"}'
    [System.IO.File]::AppendAllText($fila, $linha + "`n", [System.Text.Encoding]::UTF8)
}
if ($avisosTexto.Count -gt 0) { Set-Content -Path $avisos -Value "" -Encoding utf8 }

# ledger nao cresce sem fim
if (Test-Path $ledger) {
    $linhas = @(Get-Content $ledger -Encoding utf8)
    if ($linhas.Count -gt 500) {
        $linhas | Select-Object -Last 300 | Set-Content -Path $ledger -Encoding utf8
    }
}

# guarda so os ultimos 40 logs de disparo
Get-ChildItem $logDir -Filter "disparo-*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 40 |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Output "entregues: $($aPostar.Count) alerta(s), $($avisosTexto.Count) aviso(s)"
