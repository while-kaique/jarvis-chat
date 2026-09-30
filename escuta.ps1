# Jarvis Chat - o passo que PENSA.
# Agendador de Tarefas do Windows, a cada 15 minutos.
# Le o Google Chat + Calendar, decide, e agenda alertas em jarvis.compromissos.
# Nao entrega nada: quem entrega e o dispara.ps1, de 5 em 5 minutos.

$ErrorActionPreference = "Stop"

# --- Acento: o PowerShell 5.1 manda texto para executavel externo usando a
# codificacao antiga do console (Windows-1252/OEM), e todo acento chega como "?"
# do outro lado. As duas linhas abaixo forcam UTF-8 no cano. Sem elas, o alerta
# sai "voc? n?o resolveu" em vez de "voce nao resolveu" com acento.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = New-Object System.Text.UTF8Encoding $false


# a pasta onde este script esta. Nao edite caminho nenhum aqui.
$base   = $PSScriptRoot
$logDir = Join-Path $base "logs"
$lock   = Join-Path $base "run.lock"
# Fila de falhas desta maquina. Quem drena e o proprio cerebro, no passo 1b do
# prompt-escuta.md: a proxima run que rodar transforma isto num aviso no Chat e
# esvazia o arquivo. Por isso nao precisa de credencial de banco aqui.
$falhas = Join-Path $base "falhas.jsonl"

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# Uma linha por falha. ConvertTo-Json cuida das aspas e do acento do texto do erro —
# montar o JSON com concatenacao ja quebrou o arquivo uma vez.
function Anotar-Falha([string]$tipo, [string]$detalhe) {
    $linha = [ordered]@{
        quando  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        run_id  = $runId
        tipo    = $tipo
        detalhe = $detalhe
        log     = Split-Path $log -Leaf
    } | ConvertTo-Json -Compress
    Add-Content -Path $falhas -Value $linha -Encoding utf8
}

# --- lock local: nao adianta nem chamar o claude se a run anterior ainda esta viva.
# O lock no banco (jarvis.tentar_lock) e a segunda linha de defesa.
if (Test-Path $lock) {
    $idade = (Get-Date) - (Get-Item $lock).LastWriteTime
    if ($idade.TotalMinutes -lt 20) {
        Write-Output "abortada: run anterior comecou ha $([int]$idade.TotalMinutes) min e ainda nao terminou"
        exit 0
    }
    Remove-Item $lock -Force
}

$stamp = Get-Date -Format "yyyyMMdd-HHmm"
$sufixo = -join ((48..57) + (97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
$runId = "esc-$stamp-$sufixo"

Set-Content -Path $lock -Value $runId -Encoding utf8
$log = Join-Path $logDir "$stamp.log"

try {
    $prompt = Get-Content (Join-Path $base "prompt-escuta.md") -Raw -Encoding utf8
    # O caminho vai explicito para nao depender do diretorio de trabalho do agente.
    $prompt = $prompt + "`n`n---`n`nSeu run_id desta execucao e: ``$runId``. Use exatamente esse valor em todo p_run_id e no lock."
    $prompt = $prompt + "`n`nO arquivo de falhas do Passo 1b e: ``$falhas``"

    # send_message fica FORA de proposito: o Jarvis nunca fala direto, so agenda.
    $tools = @(
        "mcp__claude_ai_Supabase__execute_sql",
        "mcp__google-workspace__search_messages",
        "mcp__google-workspace__get_messages",
        "mcp__google-workspace__list_spaces",
        "mcp__google-workspace__get_events",
        "Read",
        "Write"
    ) -join ","

    Set-Location $base

    $prompt | & claude -p --model sonnet --allowedTools $tools --permission-mode acceptEdits |
        Tee-Object -FilePath $log

    if ($LASTEXITCODE -ne 0) {
        # Sem internet nao e defeito do Jarvis: a nuvem continua rodando e o vigia do
        # banco pega se ela tambem parar. 30/09: 6 quedas de DNS viraram aviso "alta".
        $saida = Get-Content $log -Raw -ErrorAction SilentlyContinue
        if ($saida -match "ENOTFOUND|ECONNREFUSED|ETIMEDOUT|ECONNRESET|Can't reach the API") {
            Anotar-Falha "sem_internet" "o PC estava sem internet"
        } else {
            Anotar-Falha "saida_erro" "o claude saiu com codigo $LASTEXITCODE"
        }
        Write-Output "FALHOU com codigo $LASTEXITCODE - falha enfileirada"
    }
}
catch {
    $erro = $_.Exception.Message
    Anotar-Falha "excecao" "morreu antes de rodar: $erro"
    Write-Output "ERRO: $erro"
}
finally {
    if (Test-Path $lock) { Remove-Item $lock -Force }
}

# guarda so os ultimos 30 logs
Get-ChildItem $logDir -Filter *.log |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 30 |
    Remove-Item -Force -ErrorAction SilentlyContinue
