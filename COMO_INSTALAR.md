# Como instalar o Jarvis Chat

Guia de instalação do zero, na ordem. Se você seguir do 0 ao 8, tem o agente no ar.

**Nada neste repositório contém dados de ninguém.** Todo valor pessoal aparece como
`SEU_SPACE_ID`, `SEU_USER_ID`, `SEU_PROJECT_REF`, `SEU_PROJECT_NUMBER`,
`voce@suaempresa.com`. Você descobre os seus no **Passo 3** (e o número do projeto Google
no **Passo 6b**) e é o único que os conhece.

O detalhe técnico de cada passo — o SQL na íntegra, os porquês, os becos sem saída — está
em [`CONSTRUIR.md`](CONSTRUIR.md). Este arquivo é o roteiro; aquele é a referência.

---

## O que é

Um agente que lê o seu Google Chat e o seu Google Calendar a cada 15 minutos, descobre o
que virou compromisso, e te avisa **na hora certa** num espaço privado do Chat. Cancela o
alerta sozinho quando você muda de ideia, e lembra de assunto de um mês atrás.

```
                 +----------------------------------------------+
  Google Chat -->|  CEREBRO - pensa e agenda, a cada 15 min     |
  Google Cal. -->|  a) 4 rotinas na nuvem, :07 :22 :37 :52      |
   (lidos pelo   |     -> 15 min mesmo com o PC desligado       |
    banco)       |  b) escuta.ps1 local, 15 min (redundancia)   |
                 +------------------+---------------------------+
                                    |  grava em jarvis.compromissos
                                    v
                 +----------------------------------------------+
  Google Chat <--|  ENTREGA - cron dentro do Supabase, 5 min    |
                 |  posta como o app "Jarvis", com botoes;      |
                 |  webhook do espaco como reserva. Zero LLM.   |
                 +----------------------------------------------+
```

**O cérebro nunca posta.** Ele só escreve linhas em `jarvis.compromissos` com a hora do
alerta. Quem entrega é o banco. Uma porta de saída só.

**O cérebro nunca toca em credencial.** Quem lê o Chat e o Calendar é o banco, com a
credencial do Google guardada no Vault. As rotinas pedem o resultado por função.

---

## Passo 0 — O que você precisa ter

| item | para quê | custo |
|---|---|---|
| Conta Google Workspace (ou Gmail com Chat ativo) | ler Chat e Calendar, e hospedar o app de Chat | — |
| Projeto no [Supabase](https://supabase.com) | a memória, o relógio da entrega e as Edge Functions | plano free serve |
| [Claude Code](https://claude.com/claude-code) instalado | é ele quem pensa | assinatura |
| Windows com Agendador de Tarefas | cérebro local + sincronizar a credencial do Google | opcional* |
| Um host que sirva HTML (Cloudflare Workers, Deno Deploy…) | a página do botão por link | opcional** |

\* Opcional mesmo. As quatro rotinas na nuvem, defasadas em 15 min, já dão a cadência de
15 minutos com o computador desligado. O script local é redundância e caminho rápido. O
que você perde sem Windows é o `sincronizar-google.ps1`, que mantém a credencial do Vault
em dia sozinho — sem ele, quando o Google revogar a credencial, você cola a nova à mão.

\*\* Só é usada quando o aviso sai pelo webhook de reserva, cujo botão é um link. Pelo app
de Chat o clique não abre página nenhuma.

Confira que os dois MCPs respondem:

```bash
claude mcp list 2>&1 | grep -i "google-workspace\|supabase"
```

Se faltar algum, monte pela **seção 1b** (Google) e **1** (Supabase) do `CONSTRUIR.md`.

---

## Passo 1 — O lado do Google

Detalhe completo: **`CONSTRUIR.md`, seção 1b.**

1. No Google Cloud Console, ative as APIs **Google Chat**, **Google Calendar** e
   **People** (a People é o que troca `users/123…` pelo nome da pessoa).
2. Crie uma credencial **OAuth → App para computador**. Guarde `client_id` e
   `client_secret`.
3. Na tela de consentimento, adicione os escopos de Chat e Calendar (lista exata na
   seção 1b.4).
4. Instale o MCP `google-workspace` com essas credenciais e autentique **com a sua conta
   pessoal**, não com uma conta de serviço.

> **A armadilha que pega todo mundo:** o servidor MCP responde por padrão como a conta de
> serviço, e ela **não enxerga** os seus espaços de Chat. Passe sempre
> `user_google_email: "<seu email>"` em toda chamada.

Ao final você tem `~/.google_workspace_mcp/credentials/<seu-email>.json`. Guarde: dali
sai o `refresh_token` que vai para o Vault no Passo 4 — é com ele que o banco lê o seu Chat
e a sua agenda.

---

## Passo 2 — O espaço de alerta e o webhook

Detalhe completo: **`CONSTRUIR.md`, seção 1c.**

1. No Google Chat, crie um **Espaço** só seu (não serve DM — DM não tem webhook nem app).
2. No espaço: **Apps e integrações → Webhooks → Adicionar webhook**. Nome: `Jarvis`.
3. Copie a URL. Ela tem `key=` e `token=` embutidos e **é a senha do espaço** — quem
   tiver a URL posta ali.

O webhook é a **reserva**: o caminho principal é o app de Chat do Passo 6b. Monte os dois —
o banco tenta o app e, se ele falhar, cai no webhook. O aviso chegar importa mais que o
botão.

> **Por que outra identidade e não a API com a sua credencial:** se o agente postar como
> você, a marcação `<users/SEU_ID>` aparece mas **não vibra o celular** — o Chat não
> notifica ninguém das próprias mensagens. Pelo app ou pelo webhook a mensagem vem de
> outra identidade e a notificação chega.

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
| `pessoas` | comece **vazio** (`{}`) — o agente preenche sozinho, e o banco completa pela People API |
| `spaces_ignorar` | espaços de bot/ruído. **Inclua o próprio `space_alerta`** ou o agente lê os próprios alertas e entra em laço |
| `duracao_horas` | tamanho da sua jornada, para o cálculo de "entrego até amanhã" |

---

## Passo 4 — Monte o banco

Todo o SQL está em **[`sql/00-fundacao/`](sql/00-fundacao/)**. Aplique **todos os arquivos
daquela pasta, em ordem numérica**, um por vez, no SQL Editor do Supabase. A tabela com o
que cada arquivo traz, do que depende e qual é o único que você edita (o seed, com os
valores do Passo 3) está no `README.md` da própria pasta — ela cresce quando o sistema
cresce, então confie nela, não numa lista copiada para cá.

**Antes de aplicar, crie os dois segredos do Google no Vault:**

```sql
-- 1. a URL do webhook (feito no Passo 2)

-- 2. a credencial OAuth do Passo 1, tirada do arquivo do MCP
select vault.create_secret(
  '{"client_id":"<...>","client_secret":"<...>","refresh_token":"<...>"}',
  'jarvis_google_chat',
  'Credencial OAuth do Google: o banco le Chat, Calendar e People com ela.');
```

O `jarvis_google_chat` **é obrigatório**: desde 24/09/2026 os dois cérebros leem o Chat por
`jarvis.chat_ler`, que usa essa credencial via `jarvis.token_google()`. Sem ela o agente
não lê nada.

O `README.md` da fundação traz também as consultas de conferência. **Não aplique
também** as seções 3 a 5 do `CONSTRUIR.md` nem os `sql/*.sql` datados: aqueles são o
histórico comentado, e já estão inteiros na fundação. As exceções, que se aplicam à parte,
estão na tabela de arquivos no fim deste roteiro.

Para entender *por que* cada invariante existe, leia as seções 3 a 5 do
[`CONSTRUIR.md`](CONSTRUIR.md) — elas transcrevem as três primeiras migrações com o
raciocínio de cada decisão — e as seções 19 em diante, com o que mudou depois.

> **Nunca escreva `insert`/`update` na mão** nas tabelas do `jarvis`. Toda escrita passa
> por função — é o que garante deduplicação, citação de origem e cancelamento de zumbi.

---

## Passo 5 — Smoke test. Não pule.

**`CONSTRUIR.md`, seção 7.** Ele pega 90% dos erros antes de qualquer coisa ir pro ar:
gravação idempotente, cálculo da jornada, dedupe por `fingerprint`, cancelamento de zumbi,
busca em português.

Confira também que o banco lê o seu Chat:

```sql
select jsonb_build_object('espacos', r->'espacos_total', 'ativos', r->'espacos_ativos',
                          'msgs', r->'quantas', 'erro', r->'erro')
  from (select jarvis.chat_ler(now() - interval '2 hours') r) x;
```

Tem que voltar número de espaços e nenhum `erro`. `sem credencial do Google` = volte ao
Passo 4.

Se algum retorno divergir do esperado, **pare e corrija** antes de escrever os scripts.

---

## Passo 6 — A entrega, dentro do banco

Já veio no passo 4: a fundação ativa a extensão `http`, cria `jarvis.entregar()` e
`jarvis.vigiar()`, e agenda o `cron.job` de 5 em 5 minutos. O porquê de cada decisão está
na **seção 10 do `CONSTRUIR.md`**.

Custo: `jarvis.entregar()` conta os vencidos **antes** de tocar em rede. Nas ~280 execuções
diárias vazias ela sai sem gastar nada.

Confirme que o cron entrou:

```sql
select jobname, schedule, active from cron.job where jobname like 'jarvis%';
```

Até o Passo 6b terminar, os avisos saem pelo webhook, só com texto. Já funciona.

---

## Passo 6b — O app "Jarvis" e os botões (recomendado)

Detalhe completo, com os becos sem saída: **`CONSTRUIR.md`, seção 20.**

O app é o que faz o botão do aviso resolver **dentro do Chat**, sem abrir aba: o card se
atualiza para "✅ Resolvido às 13h42 · desfazer". Pelo webhook, o botão só pode ser link.

1. **Publique as três Edge Functions, todas com `--no-verify-jwt`.** Quem chama não é
   usuário do Supabase: o `chat-app` confere a assinatura do Google, o `resolver` é
   autorizado pelo token aleatório do aviso, e o `chat-post` por um token interno do
   banco. Antes, troque `SEU_PROJECT_NUMBER` em `edge/chat-app.ts` (item 2).

   ```bash
   # a CLI espera supabase/functions/<nome>/index.ts
   for f in chat-app chat-post resolver; do
     mkdir -p supabase/functions/$f && cp edge/$f.ts supabase/functions/$f/index.ts
     supabase functions deploy $f --no-verify-jwt --project-ref SEU_PROJECT_REF
   done
   ```

2. **Crie o app no Google Cloud** (pode ser um projeto novo, `SEU_PROJETO_GCP`). Ative a
   **Google Chat API** nele e anote o **número do projeto** (`SEU_PROJECT_NUMBER`, na tela
   inicial do projeto). Em *Google Chat API → Configuração*: nome `Jarvis`, participa de
   espaços, **URL do endpoint HTTP** =
   `https://SEU_PROJECT_REF.supabase.co/functions/v1/chat-app` para todos os gatilhos,
   visível só para você, erros no Logging.
3. **Crie uma conta de serviço** no mesmo projeto, baixe a chave JSON, guarde no Vault e
   **apague o arquivo**:

   ```sql
   select vault.create_secret('<conteudo do JSON da chave>', 'jarvis_chat_sa',
          'Chave da conta de servico do app Jarvis.');
   -- token interno banco -> chat-post: nasce aqui e nunca sai do banco
   select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
          'jarvis_chat_post_token', 'Token interno para a Edge chat-post.');
   ```

4. **Diga ao banco onde está o app** e ligue o caminho:

   ```sql
   insert into jarvis.estado (chave, valor) values ('chat_app', jsonb_build_object(
     'nome', 'Jarvis', 'projeto_id', 'SEU_PROJETO_GCP', 'numero_projeto', 'SEU_PROJECT_NUMBER',
     'endpoint', 'https://SEU_PROJECT_REF.supabase.co/functions/v1/chat-app'))
   on conflict (chave) do update set valor = excluded.valor;

   update jarvis.estado set valor = valor || '{"via_app": true}' where chave = 'config';
   ```

5. **Adicione o app ao espaço de alertas:** no espaço, *Apps e integrações → Adicionar
   apps → Jarvis* (o nome pode levar alguns minutos para aparecer na busca). Teste:

   ```sql
   select jarvis.postar_como_app(jsonb_build_object('text', 'teste do app'));
   ```

   `{"ok": true, …}` e a mensagem no espaço. `403 … not a member of this space` quer dizer
   que a credencial funcionou e só falta o item 5.

6. **O teste que manda em tudo:** a marcação do aviso postado pelo app **tem que vibrar o
   celular**. Se não vibrar, volte `via_app` para `false` — o webhook continua.

**A página do botão por link (opcional).** Quando o aviso cai no webhook, o botão vira
link para uma página. Ela **não pode morar no Supabase**: as Edge Functions devolvem toda
resposta como `text/plain`, e o navegador mostra o código em vez da página. Hospede
`app-resolver/src/index.ts` num host que sirva HTML (troque `SEU_PROJECT_REF` nele) e
aponte o banco para ela:

```sql
update jarvis.estado set valor = valor || '{"resolver_url": "https://seu-dominio.exemplo.com/"}'
 where chave = 'config';
```

O mapa de qual botão aparece em qual tipo de aviso está em `PLANO-BOTOES.md` e mora em
`jarvis.categorias.botoes` — mudar um botão é um `update`, não um deploy.

---

## Passo 7 — O cérebro

Duas metades. A nuvem sozinha basta; o local é redundância.

**a) Na nuvem (o principal — 15 min com o computador desligado).**
`CONSTRUIR.md`, seções 10b e 10c. Quatro rotinas de hora em hora, em `:07`, `:22`, `:37` e
`:52`: juntas dão a cadência de 15 minutos. Cada uma carrega só um bootstrap curto; as
instruções de verdade vivem em `jarvis.prompt`, para você mudar comportamento com um
`update` em vez de editar quatro rotinas.

> Rotina na nuvem tem **mínimo de 1 hora** de intervalo. `*/15` é recusado com
> "cron interval too short". Por isso as quatro defasadas.

O ambiente da nuvem **não leva credencial do Google nenhuma**. O Chat vem de
`jarvis.chat_ler` e o Calendar de `jarvis.calendario`, os dois pelo banco. Se você seguiu
uma versão antiga deste guia e pôs `GOOGLE_CHAT_*` nas variáveis do ambiente, apague.

**b) Local no Windows (redundância e caminho rápido).**
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
aborta em paz. Se o PC cair sem internet, a falha local é descartada calada; ela só vira
aviso quando a nuvem também não rodou depois dela (seção 9 do `CONSTRUIR.md`).

**c) Credencial do Google sempre em dia (Windows, recomendado).**
O banco usa uma *cópia* da credencial do MCP. Quando o Google revoga a cópia, o Calendar e
o Chat param até alguém colar a nova. O `sincronizar-google.ps1` empurra a do PC para o
Vault a cada 30 min, e o banco só aceita se o Google aprovar a credencial antes.

1. Edite no topo do script o seu email, o `SEU_PROJECT_REF` e a chave anon.
2. `powershell -File sincronizar-google.ps1 -Configurar` — gera o token do PC (cifrado, só
   o seu usuário do Windows abre), agenda a tarefa e imprime um hash.
3. Cole o hash em `sql/sincronizar-google.sql` e rode no SQL Editor.

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

Esperado: `devidos: 1`, `entregues: 1`, `erros: 0`, a mensagem no espaço, e **o celular
vibrando**. Rode de novo: tem que voltar `devidos: 0`.

Depois confira **quem** postou: o app "Jarvis" (ou, na reserva, o webhook "Jarvis"). Se
aparecer como você, a marcação não notifica — volte ao passo 2. Com o app, clique num botão
do aviso: o card tem que se atualizar no lugar, sem abrir aba.

---

## Os arquivos deste repositório

| arquivo | o que é |
|---|---|
| `COMO_INSTALAR.md` | este roteiro |
| `CONSTRUIR.md` | a referência técnica completa, com os porquês |
| `prompt-escuta.md` | as instruções do cérebro local |
| `prompt-nuvem.md` | as instruções do cérebro na nuvem (fonte de `jarvis.prompt`) |
| `escuta.ps1` | o cérebro local, chamado pelo Agendador |
| `oculto.vbs` | lançador silencioso (esconde a janela sem exigir admin) |
| `sincronizar-google.ps1` | mantém a credencial do Google no Vault em dia (tarefa de 30 min) |
| `sql/00-fundacao/` | **todo o SQL do zero**, em arquivos numerados — tabela no `README.md` da pasta |
| `sql/sincronizar-google.sql` | a porta do banco para o `sincronizar-google.ps1` — **aplique à parte**, com o seu hash |
| `sql/gasto-painel.sql` | a função que o painel de gasto lê — aplique à parte, se for usar o painel |
| `sql/verbos-calendar.sql` | os verbos de escrita no Calendar (criar, remarcar, responder) — à parte |
| `sql/*.sql` datados | patches incrementais históricos, com o porquê — já inclusos na fundação |
| `edge/chat-app.ts` | Edge Function que recebe o clique no botão do app e devolve o card atualizado |
| `edge/chat-post.ts` | Edge Function que posta como o app (assina com a chave da conta de serviço) |
| `edge/resolver.ts` | Edge Function (só JSON) por trás do botão por link |
| `app-resolver/` | a página do botão por link, para hospedar fora do Supabase |
| `jarvis-gasto/` | painel local: quanto o Jarvis gastou hoje, por hora, e nos últimos 7/30 dias |
| `PLANO-BOTOES.md` | qual botão aparece em cada tipo de aviso, e por quê |
| `OTIMIZAR-CONSUMO.md` | como o agente anota e reduz o próprio gasto |
| `desativado/` | o entregador local antigo, guardado como reserva documentada |

---

## Segurança — leia antes de colocar no ar

1. **O webhook do Chat é uma senha.** Ele mora no Vault do Supabase e só a função de
   postagem (security definer) o lê. Nunca em arquivo, nunca no git. O mesmo vale para a
   credencial do Google (`jarvis_google_chat`) e a chave do app (`jarvis_chat_sa`).
2. **A `service_role` do Supabase nunca sai do banco.** A nuvem fala com o banco por uma
   porta de capacidade (`public.jarvis_rpc`), que só despacha as funções do `jarvis`.
   Variável de ambiente de rotina **não é cofre** — quem usa o ambiente lê. Por isso ela
   não leva credencial nenhuma, nem do Google.
3. **`send_message` fica fora do allowlist do cérebro, de propósito.** Se ele pudesse
   postar direto, você perderia a deduplicação e a única porta de saída.
4. **`--no-verify-jwt` nas Edge Functions não é porta aberta.** Cada uma tem a sua trava:
   assinatura do Google conferida (`chat-app`), token aleatório de 18 caracteres por aviso
   (`resolver`), token interno que nunca saiu do banco (`chat-post`).
5. **O painel de gasto é local.** A chave publicável vai no `jarvis-gasto/config.js`, que
   está no `.gitignore`. Se o seu projeto Supabase é compartilhado com outros sistemas,
   leia a seção de segurança do `jarvis-gasto/README.md` antes de publicar a página.

---

## Custo

**`CONSTRUIR.md`, seção 15.** O cron do banco é grátis nas execuções vazias. O gasto real
é o modelo: o `OTIMIZAR-CONSUMO.md` mostra como o próprio agente anota quanto gastou em
cada run, e o painel `jarvis-gasto/` mostra isso hora a hora.

## Como desmontar

**`CONSTRUIR.md`, seção 16.** Desagende as tarefas do Windows (`Jarvis Escuta` e
`Jarvis Sincroniza Google`), desative as rotinas na nuvem e os `cron.job` do Jarvis, apague
as Edge Functions, tire o app do espaço (ou apague o projeto Google dele), apague o webhook
no Chat, `drop schema jarvis cascade`.
