# Como instalar o Jarvis Chat

Guia de instalação do zero, na ordem. Se você seguir do 0 ao 8, tem o agente no ar.

**Nada neste repositório contém dados de ninguém.** Todo valor pessoal aparece como
`SEU_SPACE_ID`, `SEU_USER_ID`, `SEU_PROJECT_REF`, `voce@suaempresa.com`. Você descobre os
seus no **Passo 3** e é o único que os conhece.

O detalhe técnico de cada passo — o SQL na íntegra, os porquês, os becos sem saída — está
em [`CONSTRUIR.md`](CONSTRUIR.md). Este arquivo é o roteiro; aquele é a referência.

---

## O que é

Um agente que lê o seu Google Chat e o seu Google Calendar a cada 15 minutos, descobre o
que virou compromisso, e te avisa **na hora certa** num espaço privado do Chat. Cancela o
alerta sozinho quando você muda de ideia, e lembra de assunto de um mês atrás.

```
                 +---------------------------------------------+
  Google Chat -->|  CEREBRO - pensa e agenda                   |
  Google Cal. -->|  a) rotina na nuvem, 1x/hora (o piso)       |
                 |  b) escuta.ps1 local, 15 min (caminho rapido)|
                 +------------------+--------------------------+
                                    |  grava em jarvis.compromissos
                                    v
                 +---------------------------------------------+
  Google Chat <--|  ENTREGA - cron dentro do Supabase, 5 min    |
                 |  posta pelo webhook do espaco. Zero LLM.     |
                 +---------------------------------------------+
```

**O cérebro nunca posta.** Ele só escreve linhas em `jarvis.compromissos` com a hora do
alerta. Quem entrega é o banco. Uma porta de saída só.

---

## Passo 0 — O que você precisa ter

| item | para quê | custo |
|---|---|---|
| Conta Google Workspace (ou Gmail com Chat ativo) | ler Chat e Calendar | — |
| Projeto no [Supabase](https://supabase.com) | a memória e o relógio da entrega | plano free serve |
| [Claude Code](https://claude.com/claude-code) instalado | é ele quem pensa | assinatura |
| Windows com Agendador de Tarefas | o cérebro local de 15 min | opcional* |

\* Opcional mesmo. Sem a máquina Windows o agente funciona só com a rotina na nuvem, de
hora em hora. O script local só existe para dar frescor de 15 min quando o computador
está ligado.

Confira que os dois MCPs respondem:

```bash
claude mcp list 2>&1 | grep -i "google-workspace\|supabase"
```

Se faltar algum, monte pela **seção 1b** (Google) e **1** (Supabase) do `CONSTRUIR.md`.

---

## Passo 1 — O lado do Google

Detalhe completo: **`CONSTRUIR.md`, seção 1b.**

1. No Google Cloud Console, ative as APIs **Google Chat** e **Google Calendar**.
2. Crie uma credencial **OAuth → App para computador**. Guarde `client_id` e
   `client_secret`.
3. Na tela de consentimento, adicione os escopos de Chat e Calendar (lista exata na
   seção 1b.2).
4. Instale o MCP `google-workspace` com essas credenciais e autentique **com a sua conta
   pessoal**, não com uma conta de serviço.

> **A armadilha que pega todo mundo:** o servidor MCP responde por padrão como a conta de
> serviço, e ela **não enxerga** os seus espaços de Chat. Passe sempre
> `user_google_email: "<seu email>"` em toda chamada.

Ao final você tem `~/.google_workspace_mcp/credentials/<seu-email>.json`. Guarde: dali
sai também o `refresh_token` que a nuvem vai usar.

---

## Passo 2 — O espaço de alerta e o webhook

Detalhe completo: **`CONSTRUIR.md`, seção 1c.**

1. No Google Chat, crie um **Espaço** só seu (não serve DM — DM não tem webhook).
2. No espaço: **Apps e integrações → Webhooks → Adicionar webhook**. Nome: `Jarvis`.
3. Copie a URL. Ela tem `key=` e `token=` embutidos e **é a senha do espaço** — quem
   tiver a URL posta ali.

> **Por que webhook e não a API com a sua credencial:** se o agente postar como você, a
> marcação `<users/SEU_ID>` aparece mas **não vibra o celular** — o Chat não notifica
> ninguém das próprias mensagens. Pelo webhook a mensagem vem de outra identidade e a
> notificação chega.

Guarde a URL **no Vault do Supabase**, nunca em arquivo:

```sql
select vault.create_secret(
  '<cole a URL do webhook aqui>',
  'jarvis_chat_webhook',
  'Webhook de entrada do espaco de alertas.');
```

---

## Passo 3 — Descubra os seus 6 valores

Detalhe completo: **`CONSTRUIR.md`, seção 2.** Anote antes de rodar as migrações.

| valor | como achar |
|---|---|
| `email` | o seu |
| `space_alerta` | `mcp__google-workspace__list_spaces` com `page_size: 100`; ache o espaço do passo 2 |
| `self_user_id` | `search_messages` numa janela curta; pegue o `sender` de uma mensagem sua |
| `pessoas` | comece **vazio** (`{}`) — o agente preenche sozinho |
| `spaces_ignorar` | espaços de bot/ruído. **Inclua o próprio `space_alerta`** ou o agente lê os próprios alertas e entra em laço |
| `duracao_horas` | tamanho da sua jornada, para o cálculo de "entrego até amanhã" |

---

## Passo 4 — Monte o banco

Todo o SQL está em **[`sql/00-fundacao/`](sql/00-fundacao/)**. Aplique os arquivos em
ordem numérica, um por vez, no SQL Editor do Supabase:

```
01-schema-tabelas.sql    schema, 11 tabelas, indices
02-funcoes-base.sql      slug, fingerprint, lock, turno, podar
03-escrita.sql           upsert_compromisso e as invariantes
04-leitura.sql           briefing, calendario, tem_trabalho
05-entrega.sql           <- crie o segredo do webhook ANTES deste
06-porta-e-pedidos.sql   jarvis_rpc (so para o cerebro na nuvem)
07-consumo.sql           opcional: quanto cada run gastou
08-seed.sql              <- O UNICO que voce edita
```

O `README.md` daquela pasta traz a ordem, o que cada arquivo depende e as consultas de
conferência. **Não aplique também** as seções 3 a 5 do `CONSTRUIR.md` nem os `sql/*.sql`
datados: aqueles são o histórico comentado, e já estão inteiros na fundação.

Para entender *por que* cada invariante existe, leia as seções 3 a 5 do
[`CONSTRUIR.md`](CONSTRUIR.md) — elas transcrevem as três primeiras migrações com o
raciocínio de cada decisão.

> **Nunca escreva `insert`/`update` na mão** nas tabelas do `jarvis`. Toda escrita passa
> por função — é o que garante deduplicação, citação de origem e cancelamento de zumbi.

---

## Passo 5 — Smoke test. Não pule.

**`CONSTRUIR.md`, seção 7.** Ele pega 90% dos erros antes de qualquer coisa ir pro ar:
gravação idempotente, cálculo da jornada, dedupe por `fingerprint`, cancelamento de zumbi,
busca em português.

Se algum retorno divergir do esperado, **pare e corrija** antes de escrever os scripts.

---

## Passo 6 — A entrega, dentro do banco

Já veio no passo 4: é o `sql/00-fundacao/05-entrega.sql`, que ativa a extensão `http`, cria
`jarvis.postar_webhook()`, `jarvis.entregar()` e `jarvis.vigiar()`, e agenda o `cron.job` de
5 em 5 minutos. O porquê de cada decisão está na **seção 10 do `CONSTRUIR.md`**.

Custo: `jarvis.entregar()` conta os vencidos **antes** de tocar em rede. Nas ~280 execuções
diárias vazias ela sai sem gastar nada.

Confirme que o cron entrou:

```sql
select jobname, schedule, active from cron.job where jobname = 'jarvis-entrega';
```

---

## Passo 7 — O cérebro

Duas metades, e você pode montar só uma.

**a) Na nuvem (o piso — funciona com o computador desligado).**
`CONSTRUIR.md`, seções 10b e 10c. Quatro rotinas de hora em hora, defasadas em 15 min.
Cada uma carrega só um bootstrap curto; as instruções de verdade vivem em `jarvis.prompt`,
para você mudar comportamento com um `update` em vez de editar quatro rotinas.

> Rotina na nuvem tem **mínimo de 1 hora** de intervalo. `*/15` é recusado com
> "cron interval too short". Por isso as quatro defasadas.

**b) Local no Windows (frescor de 15 min).**
`CONSTRUIR.md`, seção 11. Copie `escuta.ps1`, `oculto.vbs` e `prompt-escuta.md` para uma
pasta e registre a tarefa. **Não edite caminho nenhum** — o `escuta.ps1` se localiza
sozinho pelo `$PSScriptRoot`.

```powershell
$base = "<a pasta onde você colocou os arquivos>"
$dur  = New-TimeSpan -Days 3650

$acao = New-ScheduledTaskAction -Execute "wscript.exe" `
  -Argument "`"$base\oculto.vbs`" `"$base\escuta.ps1`""
$gat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration $dur
$cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName "Jarvis Escuta" -Action $acao -Trigger $gat -Settings $cfg -Force
```

Confirme que a repetição pegou (`Register-ScheduledTask` aceita e às vezes descarta):

```powershell
Get-ScheduledTask -TaskName "Jarvis*" | ForEach-Object { $_.Triggers[0].Repetition.Interval }
```

Esperado: `PT15M`.

As duas metades compartilham `jarvis.tentar_lock`: quem chega primeiro roda, o outro
aborta em paz.

---

## Passo 8 — Verificação ponta a ponta

**`CONSTRUIR.md`, seção 12.** O mínimo:

```sql
-- caminho vazio: tem que voltar {"devidos": 0}, instantâneo
select jarvis.entregar('teste');

-- caminho real: cria um vencido e dispara
select jarvis.upsert_compromisso('aviso','Teste de entrega', now() - interval '2 min',
         'teste de instalacao','teste','Teste de ponta a ponta. Pode ignorar.'),
       jarvis.entregar('teste');
```

Esperado: `{"devidos":1,"entregues":1,"erros":0,"via":"webhook"}`, a mensagem no espaço, e
**o celular vibrando**. Rode de novo: tem que voltar `devidos: 0`.

Depois confira **quem** postou. Se aparecer como você, a marcação não notifica — volte ao
passo 2.

---

## Os arquivos deste repositório

| arquivo | o que é |
|---|---|
| `COMO_INSTALAR.md` | este roteiro |
| `CONSTRUIR.md` | a referência técnica completa, com todo o SQL |
| `prompt-escuta.md` | as instruções do cérebro local |
| `prompt-nuvem.md` | as instruções do cérebro na nuvem (fonte de `jarvis.prompt`) |
| `escuta.ps1` | o cérebro local, chamado pelo Agendador |
| `oculto.vbs` | lançador silencioso (esconde a janela sem exigir admin) |
| `sql/00-fundacao/` | **todo o SQL do zero**, em 8 arquivos ordenados |
| `sql/*.sql` | patches incrementais históricos — já inclusos na fundação |
| `OTIMIZAR-CONSUMO.md` | como o agente anota e reduz o próprio gasto |
| `desativado/` | o entregador local antigo, guardado como reserva documentada |

---

## Segurança — leia antes de colocar no ar

1. **O webhook do Chat é uma senha.** Ele mora no Vault do Supabase e só
   `jarvis.postar_webhook()` (security definer) o lê. Nunca em arquivo, nunca no git.
2. **A `service_role` do Supabase nunca sai do banco.** A nuvem fala com o banco por uma
   porta de capacidade (`public.jarvis_rpc`), que só despacha as funções do `jarvis`.
   Variável de ambiente de rotina **não é cofre** — quem usa o ambiente lê.
3. **`send_message` fica fora do allowlist do cérebro, de propósito.** Se ele pudesse
   postar direto, você perderia a deduplicação e a única porta de saída.

---

## Custo

**`CONSTRUIR.md`, seção 15.** O cron do banco é grátis nas execuções vazias. O gasto real
é o modelo, e o `OTIMIZAR-CONSUMO.md` mostra como o próprio agente anota quanto gastou em
cada run.

## Como desmontar

**`CONSTRUIR.md`, seção 16.** Desagende a tarefa, desative o `cron.job`, apague o webhook
no Chat, `drop schema jarvis cascade`.
