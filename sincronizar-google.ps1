# Jarvis Chat - copia a credencial Google do PC para o cofre do banco.
# Agendador de Tarefas, a cada 30 minutos (tarefa "Jarvis Sincroniza Google").
#
# Por que existe: o banco usa uma COPIA da credencial do MCP google-workspace.
# Quando o Google revoga a copia do banco, a do PC continua boa (o MCP renova ou
# voce faz login de novo), e o Calendar do Jarvis ficava parado ate alguem colar a
# nova a mao. Este script empurra a do PC sempre que o refresh_token muda.
#
# Seguranca:
#   - o banco so grava se o Google ACEITAR a credencial (funcao testa antes);
#   - a porta exige um token que so este PC tem, cifrado com DPAPI (so este
#     usuario do Windows abre). O banco guarda so o sha256 dele.
#   - o arquivo do token (sync-google.token) e segredo: fica no .gitignore.
#
# Uso:
#   powershell -File sincronizar-google.ps1 -Configurar   (uma vez: gera o token e agenda)
#   powershell -File sincronizar-google.ps1               (o que o Agendador roda)
# Depois do -Configurar, cole o hash impresso no sql/sincronizar-google.sql e rode no banco.

param([switch]$Configurar)
$ErrorActionPreference = "Stop"

# a pasta onde este script esta. Troque so a conta e as duas linhas do Supabase.
$base      = $PSScriptRoot
# credencial que o MCP google-workspace grava depois do login (um arquivo por conta)
$credFile  = Join-Path $env:USERPROFILE ".google_workspace_mcp\credentials\voce@suaempresa.com.json"
$tokenFile = Join-Path $base "sync-google.token"
$falhas    = Join-Path $base "falhas.jsonl"
$url       = "https://SEU_PROJECT_REF.supabase.co/rest/v1/rpc/jarvis_sincronizar_google"
# chave anon/publicavel do projeto (Settings > API). Quem autoriza e o token do PC.
$anon      = "<sua chave anon do Supabase>"

function Sha256Hex([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString("x2") }) -join ""
}

# Mesma fila do escuta.ps1: o cerebro transforma em aviso no Chat na proxima run.
function Anotar-Falha([string]$detalhe) {
    $linha = [ordered]@{
        quando  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        tipo    = "sincronizar_google"
        detalhe = $detalhe
    } | ConvertTo-Json -Compress
    Add-Content -Path $falhas -Value $linha -Encoding UTF8
}

if ($Configurar) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
    ConvertTo-SecureString $token -AsPlainText -Force | ConvertFrom-SecureString | Set-Content $tokenFile

    $acao = New-ScheduledTaskAction -Execute "wscript.exe" `
        -Argument "`"$base\oculto.vbs`" `"$base\sincronizar-google.ps1`""
    $gatilho = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName "Jarvis Sincroniza Google" -Action $acao -Trigger $gatilho -Force | Out-Null

    Write-Output "Token gerado e tarefa agendada (a cada 30 min)."
    Write-Output "Hash para o SQL: $(Sha256Hex $token)"
    exit 0
}

try {
    if (-not (Test-Path $tokenFile)) { throw "sem token: rode com -Configurar" }
    $seguro = Get-Content $tokenFile | ConvertTo-SecureString
    $token  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro))

    $cred = Get-Content $credFile -Raw | ConvertFrom-Json
    $corpo = @{
        p_token = $token
        p_cred  = @{
            client_id     = $cred.client_id
            client_secret = $cred.client_secret
            refresh_token = $cred.refresh_token
        }
    } | ConvertTo-Json -Compress

    $r = Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" `
        -Headers @{ apikey = $anon; Authorization = "Bearer $anon" } -Body $corpo
    if (-not $r.ok) { throw "banco recusou: $($r.erro) $($r.motivo)" }
} catch {
    Anotar-Falha $_.Exception.Message
    exit 1
}
