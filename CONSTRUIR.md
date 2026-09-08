# Como construir o Jarvis Chat do zero

Guia técnico completo, escrito para um agente (Claude Code) executar passo a passo.
Siga na ordem. Não pule o smoke test do passo 7 — ele pega 90% dos erros antes de
qualquer coisa ir pro ar.

**Se você é humano e só quer instalar, comece pelo [`COMO_INSTALAR.md`](COMO_INSTALAR.md).**
Este arquivo é a referência de detalhe, para quando algo não bater.

---

## 0. O que você vai construir

Um agente que escuta o Google Chat e o Google Calendar de uma pessoa a cada 15 minutos,
identifica o que virou compromisso, e entrega um alerta **na hora certa** num espaço de
Chat privado dela. Também cancela sozinho o alerta quando a pessoa muda de ideia, e
mantém memória de longo prazo dos assuntos para poder decidir sobre coisa de um mês atrás.

```
                 +---------------------------------------------+
  Google Chat -->|  CEREBRO  - pensa e agenda                  |
  Google Cal. -->|  a) rotina na nuvem, 1x/hora (o piso)       |
                 |  b) escuta.ps1 local, 15 min (caminho rapido)|
                 |  os dois compartilham um lock               |
                 +------------------+--------------------------+
                                    |  grava em jarvis.compromissos
                                    v
                 +---------------------------------------------+
  Google Chat <--|  ENTREGA - cron dentro do Supabase, 5 min    |
                 |  jarvis.entregar() + jarvis.vigiar()         |
                 |  posta pelo webhook do espaco. Zero LLM.     |
                 +---------------------------------------------+
```

**Por que a entrega mora no banco.** É o único relógio que acerta o minuto e não depende
de máquina ligada. Um tick de 15 min cai em 10:15 e 10:30 — nunca acerta "10 min antes da
reunião das 10:30". E não custa nada: `jarvis.entregar()` conta os vencidos antes de tocar
em rede, então nas ~280 execuções diárias vazias ela sai sem gastar.

**Por que o cérebro é duplo.** Rotina na nuvem tem **mínimo de 1 hora** de intervalo — o
servidor recusa `*/15` com "cron interval too short". Então: a nuvem é o piso que funciona
com o computador desligado, e o script local dá 15 min de frescor quando ele está ligado.
`jarvis.tentar_lock` arbitra: quem chega primeiro roda, o outro aborta em paz.

**O cérebro nunca posta.** `send_message` fica fora do allowlist de propósito. Tudo que
precisa chegar à pessoa é uma linha em `jarvis.compromissos` com `alerta_em_utc`. Uma
porta de saída só, e deduplicação de graça pelo `fingerprint`. "Avisa agora" =
`alerta_em_utc` igual a `now()`, entregue em no máximo 5 minutos.

---

## 1. Pré-requisitos

Confira cada um antes de escrever qualquer coisa. Se algum falhar, pare e resolva.

Se algum **não existir ainda**, monte pela **seção 1b** (lado do Google: APIs, cliente
OAuth, MCP) e pela **1c** (o webhook do espaço). Elas trazem os comandos.

**1.1 — MCP `google-workspace` conectado, com escopo de Chat e Calendar.**

```bash
claude mcp list 2>&1 | grep -i "google-workspace\|supabase"
```

As duas linhas precisam terminar em `✔ Connected`. O `google-workspace` é o pacote
`workspace-mcp` (via `uvx`) e precisa das ferramentas `chat`, `calendar` e `contacts`
habilitadas. Se `chat` não estiver na linha de `--tools`, o agente não lê nada.

**1.2 — A conta certa autenticada no MCP.**

Este é o erro que já custou uma tarde neste projeto. O MCP `workspace-mcp` responde por
padrão como uma conta de serviço (aqui, `conta-servico@suaempresa.com`), e essa conta **não enxerga
os espaços pessoais** da pessoa. Toda chamada precisa de `user_google_email` explícito.
Verifique que a conta do usuário final está autenticada:

```bash
ls "C:/Users/SEU_USUARIO/.google_workspace_mcp/credentials/"
```

Precisa existir um `<email-da-pessoa>.json`. Se não existir, use
`mcp__google-workspace__start_google_auth` com o email dela.

**1.3 — Projeto Supabase acessível pelo MCP.**

```
mcp__claude_ai_Supabase__list_projects
```

Anote o `id` do projeto (aqui: `SEU_PROJECT_REF`). Pode reaproveitar um projeto
existente — nada vai no schema `public`.

**1.4 — `claude` no PATH do PowerShell.**

```powershell
(Get-Command claude).Source
```

**1.5 — Permissão para registrar tarefa agendada.** Tarefa do usuário atual não precisa de
admin. `Register-ScheduledTask` sem `-User SYSTEM` funciona.

**1.6 — A People API do Google ativa** no projeto GCP que atende o MCP. Sem ela, os
autores das mensagens voltam como `users/1234567890` em vez do nome. Não é bloqueante (há
uma tabela de nomes como rede), mas a qualidade do alerta cai muito.

---

## 1b. O lado do Google, do zero

A seção 1 confere se isto já existe. Esta seção é o que fazer quando **não** existe. Tudo
aqui é uma vez por máquina/conta, e é a parte que mais custou tempo neste projeto.

### 1b.1 — Projeto no Google Cloud e as três APIs

O projeto GCP que atende este agente é o mesmo que atende o MCP `google-workspace`. Aqui
ele é o número `SEU_PROJECT_NUMBER` (o prefixo do client id).

Ative **três** APIs — sem elas as chamadas voltam com `403 SERVICE_DISABLED`:

| API | para que | o que quebra sem ela |
|---|---|---|
| Google Chat API | ler espaços e mensagens, postar | tudo |
| Google Calendar API | a agenda que o banco busca | `jarvis.calendario` volta vazia |
| People API | trocar `users/123…` pelo nome | o alerta diz "users/1078…" em vez de "Ana" |

Pelo console: **APIs e serviços → Biblioteca**, busque cada uma, **Ativar**. Se tiver
`gcloud` logado na conta certa, é uma linha:

```bash
gcloud services enable chat.googleapis.com calendar-json.googleapis.com \
  people.googleapis.com --project=<numero-ou-id-do-projeto>
```

A Chat API foi ativada em 31/08/2026 e **antes disso a REST não respondia nada** — o erro
de permissão parecia trava de administrador e não era; era a API desligada. Confira isto
antes de culpar o Workspace.

### 1b.2 — Tela de consentimento e o cliente OAuth

**Tela de consentimento OAuth**: tipo **Interno** (a conta é do Workspace da sua empresa, então
não há revisão do Google). Nos escopos, adicione os de Chat e Calendar — a lista completa
que este agente usa está em 1b.4.

**Credencial**: APIs e serviços → Credenciais → Criar credenciais → **ID do cliente OAuth**
→ tipo **App para computador**. Guarde o `client_id` e o `client_secret`.

Tipo "App para computador" e não "Aplicativo da Web" porque o `workspace-mcp` abre um
servidor de retorno em `http://localhost` para receber o código. É também o motivo do
`OAUTHLIB_INSECURE_TRANSPORT=1` no passo seguinte: sem ele a biblioteca recusa um retorno
em `http://` e o login nunca fecha.

### 1b.3 — Registrar o MCP `google-workspace`

Um comando, uma vez, com escopo de usuário (vale para todos os projetos):

```bash
claude mcp add google-workspace --scope user \
  --env GOOGLE_OAUTH_CLIENT_ID="<client id>.apps.googleusercontent.com" \
  --env GOOGLE_OAUTH_CLIENT_SECRET="<client secret>" \
  --env USER_GOOGLE_EMAIL="conta-servico@suaempresa.com" \
  --env OAUTHLIB_INSECURE_TRANSPORT="1" \
  -- "C:/Users/SEU_USUARIO/AppData/Roaming/Python/Python314/Scripts/uvx.exe" \
     workspace-mcp --single-user --tools drive sheets gmail calendar docs chat contacts
```

Detalhes que não são decorativos:

- **`chat` e `calendar` na lista de `--tools`.** Se `chat` não estiver ali, o servidor sobe
  normalmente e simplesmente não tem as ferramentas de Chat. Nada avisa.
- **`uvx` por caminho absoluto.** `uvx` não está no PATH do PowerShell nesta máquina;
  registrar como `uvx workspace-mcp` dá servidor que nunca conecta.
- **`--single-user`** faz o servidor responder como `USER_GOOGLE_EMAIL`. Veja a armadilha
  em 1b.5.

Confira: `claude mcp list` tem que mostrar `google-workspace … ✔ Connected`.

### 1b.4 — Autenticar a conta da pessoa (não só a conta de serviço)

```
mcp__google-workspace__start_google_auth  com user_google_email = voce@suaempresa.com
```

Ele devolve uma URL, a pessoa aprova no navegador, e o servidor grava
`C:/Users/SEU_USUARIO/.google_workspace_mcp/credentials/<email>.json`. Esse arquivo é a fonte de
tudo: tem `refresh_token`, `client_id`, `client_secret` e a lista de escopos.

Os escopos que este agente precisa ver ali dentro:

```
https://www.googleapis.com/auth/chat.messages
https://www.googleapis.com/auth/chat.messages.readonly
https://www.googleapis.com/auth/chat.spaces
https://www.googleapis.com/auth/chat.spaces.readonly
https://www.googleapis.com/auth/calendar
https://www.googleapis.com/auth/calendar.events
https://www.googleapis.com/auth/contacts.readonly
```

**Este arquivo é também de onde sai o `GOOGLE_CHAT_REFRESH_TOKEN` do cérebro na nuvem**
(seção 10c) e o segredo `jarvis_google_chat` do Vault. Não precisa de OAuth Playground nem
de script próprio: o refresh token já está aqui, com escopo de Chat, e é de longa duração.

### 1b.5 — A armadilha que custou uma tarde

Com `--single-user`, o servidor responde por padrão como `conta-servico@suaempresa.com`. Essa conta
**não enxerga os espaços pessoais** do dono: `list_spaces` volta uma lista curta e
plausível, sem o espaço de alerta, e nada dá erro. Toda chamada de Chat ou Calendar tem que
levar `user_google_email` explícito com o email dele.

Regra prática: se uma listagem de espaços voltar sem `spaces/SEU_SPACE_ID`, você está
falando como a conta errada.

---

## 1c. O webhook do espaço de alerta

A entrega não usa OAuth: usa um **webhook de entrada** criado dentro do próprio espaço do
Google Chat. É uma URL com `key=` e `token=` embutidos, sem renovação, sem token para
expirar.

### 1c.1 — Criar (na interface do Chat)

1. Abra o espaço no Google Chat (`chat.google.com`, espaço **Alertas do Jarvis**).
2. Clique no **nome do espaço**, no cabeçalho — abre o menu do espaço.
3. **Apps e integrações**.
4. **Webhooks → Adicionar webhook** (ou "Gerenciar webhooks", se já existir algum).
5. Nome: `Jarvis`. É este nome que aparece como autor da mensagem, com o selo `App`, e é
   por isso que a mensagem não é confundida com uma dele. Avatar é opcional (URL de imagem).
6. **Salvar** e **copiar a URL**.

Três coisas que barram este caminho:

- **Só existe em Espaço.** Mensagem direta não tem webhook. Se o alerta fosse numa DM, não
  haveria essa porta.
- **O Workspace precisa permitir webhooks** (o admin pode desligar apps no Chat). Aqui está
  liberado — o espaço `Erros/Dúvidas Docs` já usava um antes deste projeto.
- **Quem cria precisa ser membro com permissão de gerenciar apps** no espaço.

### 1c.2 — Guardar no cofre do banco

A URL é credencial. Ela nunca aparece no prompt do agente, nem em arquivo do projeto: mora
no Vault do Supabase e só `jarvis.postar_webhook()` (security definer) a lê.

```sql
select vault.create_secret(
  'https://chat.googleapis.com/v1/spaces/SEU_SPACE_ID/messages?key=…&token=…',
  'jarvis_chat_webhook',
  'Webhook de entrada do espaco Alertas do Jarvis. Usado pela entrega para que a marcacao do dono gere notificacao.');
```

Para trocar a URL depois (webhook apagado e recriado):

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'jarvis_chat_webhook'),
  '<URL nova>');
```

Confira sem imprimir o segredo:

```sql
select name, description from vault.secrets where name like 'jarvis%';
```

Devem existir dois: `jarvis_chat_webhook` e `jarvis_google_chat` (o JSON de OAuth do
caminho reserva).

### 1c.3 — Por que webhook, e não a API com a credencial dele

Já está na seção 10, mas o motivo cabe aqui também porque é o que decide o desenho: postando
com a credencial da própria pessoa, a marcação `<users/ID>` **aparece na mensagem e não
notifica o celular** — o Google não notifica alguém de uma mensagem que ele mesmo mandou.
Pelo webhook a mensagem vem de outra identidade ("Jarvis"), e a marcação vibra.

⚠️ **Risco aberto, de 01/09/2026:** existe um webhook do Google Chat em claro dentro de
`painel-interno/workflows_n8n/alerta_gastos.json` (espaço `spaces/SEU_SPACE_ID_2`), com `key` e
`token`. Quem tem o arquivo pode postar naquele espaço. Não repita o padrão, e vale apagar
aquele webhook e recriar.

---

## 2. Descoberta: os 6 valores que você precisa achar

Não invente nenhum destes. Descubra e anote antes de rodar as migrações — eles vão para o
`seed` do passo 7.

| valor | como achar |
|---|---|
| `email` | o email da pessoa. Aqui: `voce@suaempresa.com` |
| `space_alerta` | espaço privado onde o alerta é entregue. `mcp__google-workspace__list_spaces` com `page_size: 100`, procure um espaço só dela. Aqui: `spaces/SEU_SPACE_ID` ("Alertas do Jarvis") |
| `self_user_id` | o id dela no Chat, para saber quais mensagens são dela. `search_messages` numa janela curta e ache o `sender` de uma mensagem que ela escreveu. Aqui: `users/SEU_USER_ID` |
| `pessoas` | mapa id → nome dos colegas. Comece vazio (`{}`): o agente preenche sozinho conforme as pessoas aparecem nas conversas |
| `spaces_ignorar` | espaços de bot/ruído que só contam se citarem a pessoa pelo nome. Aqui: alertas automáticos, relatórios, avisos gerais. **Inclua sempre o próprio `space_alerta`** — se não incluir, o agente lê os próprios alertas como se fossem conversa e entra em laço |
| `duracao_horas` | jornada da pessoa, para o cálculo de "entrego até amanhã". Aqui: 6 (estágio), com margem de 10 min |

Sobre o **turno**: o alerta de prazo sem hora cai no fim da jornada do dia. A jornada é
descoberta, não configurada: `inicio` = primeira mensagem que ela mandou no Chat naquele
dia, `fim_alerta` = `inicio + (duracao_horas - margem)`. Com 6h e 10 min de margem, dá
+5h50. Validado aqui: primeira mensagem 09:03 → alerta 14:53.

---

## 3. Migração 1 — o schema

`apply_migration`, nome `jarvis_chat_memoria_remota`.

Duas decisões que importam e não são cosméticas: **schema próprio** (o `public` deste
projeto tem 150+ tabelas, e um schema fora dos schemas expostos no PostgREST não é
alcançável pela anon key, o que resolve RLS sem escrever policy nenhuma); e **quatro
camadas com orçamento de tamanho declarado**, que é o que impede o banco de lotar.

> Nota de fidelidade: no build original a coluna `mensagem_alerta` e o tipo `aviso`
> vieram em migrações posteriores. Aqui já estão no `create`, para quem constrói do zero
> chegar direto no estado final.

```sql
create schema if not exists jarvis;
comment on schema jarvis is 'Memoria do agente Jarvis Chat. Escuta Google Chat + Calendar a cada 15 min e agenda alertas.';

-- ---------------------------------------------------------------- camada 0: cru
create table jarvis.mensagens (
  id           bigserial primary key,
  space_id     text        not null default 'desconhecido',
  space_nome   text,
  autor_id     text        not null default 'desconhecido',
  autor_nome   text,
  texto        text        not null,
  create_time  timestamptz not null,
  is_dono    boolean     not null default false,
  cortado      boolean     not null default false,
  coletado_em  timestamptz not null default now(),
  tsv tsvector generated always as (to_tsvector('portuguese', coalesce(texto, ''))) stored,
  constraint mensagens_unicas unique (space_id, autor_id, create_time)
);
comment on table jarvis.mensagens is 'Conversa crua. Vive 7 dias e e apagada por jarvis.podar(). O que tem consequencia migra para compromissos/assuntos.';
comment on column jarvis.mensagens.cortado is 'true quando o texto veio truncado em 100 chars pelo search_messages do MCP.';

create index mensagens_tsv_idx         on jarvis.mensagens using gin (tsv);
create index mensagens_create_time_idx on jarvis.mensagens (create_time desc);
create index mensagens_dono_idx      on jarvis.mensagens (create_time) where is_dono;

-- ------------------------------------------------- camada 1: o que gera alerta
create table jarvis.compromissos (
  id                bigserial primary key,
  tipo              text not null check (tipo in ('reuniao','prazo','promessa','pergunta_aberta','mencao','conflito','aviso')),
  titulo            text not null,
  descricao         text,
  quando_utc        timestamptz,
  alerta_em_utc     timestamptz not null,
  mensagem_alerta   text,
  space_origem      text,
  space_origem_nome text,
  status            text not null default 'pendente'
                    check (status in ('pendente','disparado','cancelado','cumprido','expirado')),
  fingerprint       text not null unique,
  origem_texto      text not null,
  origem_msg_time   timestamptz,
  origem_autor      text,
  calendar_event_id text,
  cancelado_motivo  text,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  disparado_em      timestamptz,
  constraint origem_nao_vazia check (length(btrim(origem_texto)) > 0)
);
comment on table jarvis.compromissos is 'Duravel, sem prazo de validade de 24h. Uma linha por coisa que merece alerta.';
comment on column jarvis.compromissos.tipo is
  'reuniao/prazo/promessa = agenda pro futuro. pergunta_aberta/mencao/conflito/aviso = alerta_em = agora, chega no proximo tick de 5 min.';
comment on column jarvis.compromissos.origem_texto is 'Citacao literal da mensagem/evento que originou. Obrigatoria: sem citacao o agente nao cria (anti-alucinacao).';
comment on column jarvis.compromissos.mensagem_alerta is 'Texto pronto, escrito pelo LLM na hora de agendar. Quem entrega nao tem LLM.';

create index compromissos_pendentes_idx on jarvis.compromissos (alerta_em_utc) where status = 'pendente';
create index compromissos_status_idx    on jarvis.compromissos (status, atualizado_em desc);
create unique index compromissos_cal_idx on jarvis.compromissos (calendar_event_id) where calendar_event_id is not null;

-- ------------------------------------------- camada 2: memoria longa (assuntos)
create table jarvis.assuntos (
  id            bigserial primary key,
  chave         text not null unique,
  titulo        text not null,
  resumo        text not null,
  pessoas       text[] not null default '{}',
  spaces        text[] not null default '{}',
  primeira_vez  timestamptz not null default now(),
  ultima_vez    timestamptz not null default now(),
  mencoes       integer not null default 1,
  aberto        boolean not null default true,
  atualizado_em timestamptz not null default now(),
  tsv tsvector generated always as (
    to_tsvector('portuguese',
      coalesce(titulo, '') || ' ' || coalesce(resumo, '') || ' ' || replace(coalesce(chave, ''), '-', ' '))
  ) stored,
  constraint resumo_com_teto check (length(resumo) <= 1200)
);
comment on table jarvis.assuntos is 'Memoria de longo prazo: 1 linha por assunto, resumo REESCRITO (nunca anexado) com teto de 1200 chars. E daqui que sai contexto de coisa conversada 28 dias atras.';

create index assuntos_tsv_idx        on jarvis.assuntos using gin (tsv);
create index assuntos_ultima_vez_idx on jarvis.assuntos (ultima_vez desc);
create index assuntos_abertos_idx    on jarvis.assuntos (ultima_vez desc) where aberto;

-- ------------------------------------------- camada 3: log das decisoes
create table jarvis.eventos (
  id             bigserial primary key,
  ts             timestamptz not null default now(),
  compromisso_id bigint references jarvis.compromissos(id) on delete set null,
  acao           text not null check (acao in ('criou','atualizou','cancelou','disparou','cumpriu','expirou','ignorou','erro')),
  motivo         text,
  antes          jsonb,
  depois         jsonb,
  run_id         text
);
comment on table jarvis.eventos is 'Append-only, 180 dias. Guarda o historico de "era amanha, virou sexta" -- o agente le isso antes de decidir de novo.';

create index eventos_ts_idx          on jarvis.eventos (ts desc);
create index eventos_compromisso_idx on jarvis.eventos (compromisso_id);

-- ------------------------------------------------------ camada 4: estado
create table jarvis.estado (
  chave         text primary key,
  valor         jsonb not null,
  atualizado_em timestamptz not null default now()
);
comment on table jarvis.estado is 'watermark (ate onde ja leu), turno (inicio/fim da jornada de hoje), pessoas (id->nome), ruido (spaces a ignorar), lock, heartbeat, config.';
```

**Sobre a coluna `is_dono`:** é o nome dela neste build. Se estiver construindo para
outra pessoa, pode renomear, mas então renomeie **em todas as funções e no prompt**. Mais
seguro deixar como está e tratar como "é a própria pessoa".

---

## 4. Migração 2 — as funções de escrita

`apply_migration`, nome `jarvis_chat_funcoes`.

Estas funções são a API do agente. O prompt **nunca** escreve `insert`/`update` na mão.
Isso não é preferência de estilo: os invariantes que o LLM não pode furar (citação
obrigatória, deduplicação, teto de caracteres, histórico automático) moram aqui, onde
não dependem de o modelo lembrar da regra.

```sql
-- ------------------------------------------------------------------ utilitarios
create or replace function jarvis.slug(p_txt text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             lower(translate(coalesce(p_txt, ''),
               'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
               'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')),
             '[^a-z0-9]+', '-', 'g'),
           '^-+|-+$', '', 'g')
$$;

-- Dedupe: mesma coisa dita de dois jeitos cai no mesmo fingerprint.
-- Hora arredondada para 5 min para tolerar "10:30" vs "10h30".
create or replace function jarvis.fingerprint(p_tipo text, p_titulo text, p_quando timestamptz)
returns text language sql immutable as $$
  select p_tipo || ':' || left(jarvis.slug(p_titulo), 60) || ':' ||
         coalesce(
           to_char(to_timestamp(round(extract(epoch from p_quando) / 300) * 300)
                     at time zone 'UTC', 'YYYYMMDD"T"HH24MI'),
           'semdata')
$$;

-- ------------------------------------------------------- gravar conversa crua
create or replace function jarvis.gravar_mensagens(p_msgs jsonb)
returns jsonb language plpgsql as $$
declare v_novas int;
begin
  insert into jarvis.mensagens
    (space_id, space_nome, autor_id, autor_nome, texto, create_time, is_dono, cortado)
  select coalesce(nullif(m->>'space_id', ''), 'desconhecido:' || coalesce(m->>'space_nome', '?')),
         m->>'space_nome',
         coalesce(nullif(m->>'autor_id', ''), 'desconhecido'),
         m->>'autor_nome',
         m->>'texto',
         (m->>'create_time')::timestamptz,
         coalesce((m->>'is_dono')::boolean, false),
         coalesce((m->>'cortado')::boolean, false)
    from jsonb_array_elements(coalesce(p_msgs, '[]'::jsonb)) m
   where coalesce(btrim(m->>'texto'), '') <> ''
     and (m->>'create_time') is not null
  on conflict on constraint mensagens_unicas do nothing;
  get diagnostics v_novas = row_count;
  return jsonb_build_object('novas', v_novas, 'recebidas', jsonb_array_length(coalesce(p_msgs, '[]'::jsonb)));
end $$;

-- ------------------------------------------------- criar / atualizar compromisso
create or replace function jarvis.upsert_compromisso(
  p_tipo              text,
  p_titulo            text,
  p_alerta_em         timestamptz,
  p_origem_texto      text,
  p_run_id            text,
  p_mensagem_alerta   text default null,
  p_quando            timestamptz default null,
  p_descricao         text default null,
  p_space_origem      text default null,
  p_space_origem_nome text default null,
  p_origem_msg_time   timestamptz default null,
  p_origem_autor      text default null,
  p_calendar_event_id text default null
) returns jsonb language plpgsql as $$
declare
  v_fp    text;
  v_antes jarvis.compromissos;
  v_id    bigint;
  v_mudou boolean;
begin
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: compromisso sem citacao literal nao entra (anti-alucinacao)';
  end if;

  -- Evento de calendario tem identidade propria: remarcar atualiza a MESMA linha
  -- em vez de criar uma segunda.
  v_fp := case
            when p_calendar_event_id is not null then 'cal:' || p_calendar_event_id
            else jarvis.fingerprint(p_tipo, p_titulo, coalesce(p_quando, p_alerta_em))
          end;

  select * into v_antes from jarvis.compromissos where fingerprint = v_fp;

  if not found then
    insert into jarvis.compromissos
      (tipo, titulo, descricao, quando_utc, alerta_em_utc, space_origem, space_origem_nome,
       fingerprint, origem_texto, origem_msg_time, origem_autor, calendar_event_id, mensagem_alerta)
    values
      (p_tipo, p_titulo, p_descricao, p_quando, p_alerta_em, p_space_origem, p_space_origem_nome,
       v_fp, p_origem_texto, p_origem_msg_time, p_origem_autor, p_calendar_event_id, p_mensagem_alerta)
    returning id into v_id;

    insert into jarvis.eventos (compromisso_id, acao, motivo, depois, run_id)
    values (v_id, 'criou', p_titulo,
            jsonb_build_object('tipo', p_tipo, 'quando', p_quando, 'alerta_em', p_alerta_em), p_run_id);

    return jsonb_build_object('acao', 'criou', 'id', v_id, 'fingerprint', v_fp);
  end if;

  v_mudou := (coalesce(v_antes.quando_utc,    'epoch'::timestamptz) <> coalesce(p_quando,    'epoch'::timestamptz))
          or (coalesce(v_antes.alerta_em_utc, 'epoch'::timestamptz) <> coalesce(p_alerta_em, 'epoch'::timestamptz))
          or (coalesce(v_antes.titulo, '')    <> coalesce(p_titulo, ''))
          or (coalesce(v_antes.descricao, '') <> coalesce(p_descricao, v_antes.descricao, ''));

  -- Cancelado/cumprido so ressuscita se a HORA mudou (foi remarcado de verdade).
  -- Sem isso o agente reabriria a cada 15 min o que a pessoa acabou de cancelar.
  if v_antes.status in ('cancelado', 'cumprido')
     and coalesce(v_antes.quando_utc, 'epoch'::timestamptz) = coalesce(p_quando, 'epoch'::timestamptz) then
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', 'estava ' || v_antes.status || ' e a hora nao mudou');
  end if;

  if not v_mudou and v_antes.status = 'pendente' then
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', 'pendente');
  end if;

  update jarvis.compromissos set
    titulo          = p_titulo,
    descricao       = coalesce(p_descricao, descricao),
    quando_utc      = p_quando,
    alerta_em_utc   = p_alerta_em,
    mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
    origem_texto    = p_origem_texto,
    origem_msg_time = coalesce(p_origem_msg_time, origem_msg_time),
    -- remarcado ou reaberto volta a valer
    status          = case when v_mudou then 'pendente' else status end,
    disparado_em    = case when v_mudou then null else disparado_em end,
    cancelado_motivo = case when v_mudou then null else cancelado_motivo end,
    atualizado_em   = now()
  where id = v_antes.id
  returning id into v_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, antes, depois, run_id)
  values (v_id, 'atualizou',
          case when v_antes.status = 'cancelado' then 'remarcado depois de cancelado' else 'dados mudaram' end,
          jsonb_build_object('titulo', v_antes.titulo, 'quando', v_antes.quando_utc,
                             'alerta_em', v_antes.alerta_em_utc, 'status', v_antes.status),
          jsonb_build_object('titulo', p_titulo, 'quando', p_quando,
                             'alerta_em', p_alerta_em, 'status', 'pendente'),
          p_run_id);

  return jsonb_build_object('acao', 'atualizou', 'id', v_id, 'fingerprint', v_fp,
                            'status_antes', v_antes.status);
end $$;

-- ---------------------------------------------------------------- cancelar / cumprir
create or replace function jarvis.encerrar_compromisso(
  p_id bigint, p_status text, p_motivo text, p_run_id text
) returns jsonb language plpgsql as $$
declare v_antes jarvis.compromissos;
begin
  if p_status not in ('cancelado', 'cumprido', 'expirado') then
    raise exception 'status invalido para encerrar: %', p_status;
  end if;
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'motivo obrigatorio: a pessoa precisa saber POR QUE cancelou';
  end if;

  select * into v_antes from jarvis.compromissos where id = p_id;
  if not found then
    return jsonb_build_object('acao', 'nada', 'nota', 'id inexistente');
  end if;
  if v_antes.status = p_status then
    return jsonb_build_object('acao', 'nada', 'id', p_id, 'nota', 'ja estava ' || p_status);
  end if;

  update jarvis.compromissos
     set status = p_status, cancelado_motivo = p_motivo, atualizado_em = now()
   where id = p_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, antes, depois, run_id)
  values (p_id,
          case p_status when 'cancelado' then 'cancelou' when 'cumprido' then 'cumpriu' else 'expirou' end,
          p_motivo,
          jsonb_build_object('status', v_antes.status, 'quando', v_antes.quando_utc),
          jsonb_build_object('status', p_status), p_run_id);

  return jsonb_build_object('acao', p_status, 'id', p_id, 'titulo', v_antes.titulo,
                            'era_status', v_antes.status);
end $$;

-- ------------------------------------------------- memoria longa: assunto
create or replace function jarvis.upsert_assunto(
  p_chave text, p_titulo text, p_resumo text,
  p_pessoas text[] default '{}', p_spaces text[] default '{}',
  p_aberto boolean default true
) returns jsonb language plpgsql as $$
declare v_resumo text; v_novo boolean;
begin
  -- teto de 1200 chars aplicado aqui, nao confiado ao LLM: e o que impede lotar
  v_resumo := left(btrim(coalesce(p_resumo, '')), 1200);
  if v_resumo = '' then
    raise exception 'resumo vazio para o assunto %', p_chave;
  end if;

  insert into jarvis.assuntos (chave, titulo, resumo, pessoas, spaces, aberto)
  values (jarvis.slug(p_chave), p_titulo, v_resumo,
          coalesce(p_pessoas, '{}'), coalesce(p_spaces, '{}'), p_aberto)
  on conflict (chave) do update set
    titulo        = excluded.titulo,
    resumo        = excluded.resumo,   -- REESCRITO, nunca anexado
    pessoas       = (select array_agg(distinct p) from unnest(jarvis.assuntos.pessoas || excluded.pessoas) p where p is not null),
    spaces        = (select array_agg(distinct s) from unnest(jarvis.assuntos.spaces  || excluded.spaces)  s where s is not null),
    ultima_vez    = now(),
    mencoes       = jarvis.assuntos.mencoes + 1,
    aberto        = excluded.aberto,
    atualizado_em = now();

  select mencoes = 1 into v_novo from jarvis.assuntos where chave = jarvis.slug(p_chave);
  return jsonb_build_object('chave', jarvis.slug(p_chave), 'novo', v_novo, 'chars', length(v_resumo));
end $$;

-- Busca por relevancia SEM LLM e SEM embedding: full-text em portugues.
-- O truque do OR: strip(to_tsvector) devolve 'a' 'b' 'c'; trocar espaco por ' | '
-- vira uma tsquery de OR valida. (plainto_/websearch_ fazem AND e devolveriam vazio.)
create or replace function jarvis.assuntos_relevantes(p_texto text, p_limite int default 8)
returns table (chave text, titulo text, resumo text, pessoas text[], ultima_vez timestamptz, mencoes int, rank real)
language plpgsql stable as $$
declare v_q tsquery;
begin
  begin
    v_q := replace(strip(to_tsvector('portuguese', coalesce(p_texto, '')))::text, ' ', ' | ')::tsquery;
  exception when others then
    v_q := null;
  end;
  if v_q is null then
    return query
      select a.chave, a.titulo, a.resumo, a.pessoas, a.ultima_vez, a.mencoes, 0::real
        from jarvis.assuntos a where a.aberto
       order by a.ultima_vez desc limit p_limite;
    return;
  end if;
  return query
    select a.chave, a.titulo, a.resumo, a.pessoas, a.ultima_vez, a.mencoes,
           ts_rank(a.tsv, v_q) as rank
      from jarvis.assuntos a
     where a.tsv @@ v_q
     order by rank desc, a.ultima_vez desc
     limit p_limite;
end $$;
```

---

## 5. Migração 3 — o ciclo da run

`apply_migration`, nome `jarvis_chat_ciclo_da_run`.

**Atenção a uma armadilha de sintaxe que quebrou este arquivo na primeira tentativa:**
em `to_char`, texto literal dentro da máscara se escapa com aspas duplas (`'"T"'`), não
com aspas simples escapadas. Se precisar de uma palavra no meio de uma data formatada,
concatene fora do `to_char`.

```sql
-- --------------------------------------------------------------------- lock
create or replace function jarvis.tentar_lock(p_run_id text, p_minutos int default 20)
returns jsonb language plpgsql as $$
declare v_lock jsonb;
begin
  select valor into v_lock from jarvis.estado where chave = 'lock' for update;
  if v_lock ? 'expira_utc' and (v_lock->>'expira_utc') is not null
     and (v_lock->>'expira_utc')::timestamptz > now() then
    return jsonb_build_object('ok', false, 'dono', v_lock->>'run_id', 'expira', v_lock->>'expira_utc');
  end if;
  update jarvis.estado
     set valor = jsonb_build_object('run_id', p_run_id,
                                    'expira_utc', to_char(now() + make_interval(mins => p_minutos), 'YYYY-MM-DD"T"HH24:MI:SSOF')),
         atualizado_em = now()
   where chave = 'lock';
  return jsonb_build_object('ok', true, 'run_id', p_run_id);
end $$;

create or replace function jarvis.soltar_lock(p_run_id text)
returns jsonb language plpgsql as $$
begin
  update jarvis.estado
     set valor = '{"run_id": null, "expira_utc": null}'::jsonb, atualizado_em = now()
   where chave = 'lock' and (valor->>'run_id' = p_run_id or valor->>'run_id' is null);
  return jsonb_build_object('ok', true);
end $$;

-- ------------------------------------------------------- jornada do dia
-- inicio = primeira mensagem que a pessoa mandou hoje. fim_alerta = inicio + 5h50.
create or replace function jarvis.definir_turno(p_ref timestamptz default now())
returns jsonb language plpgsql as $$
declare
  v_dia date; v_inicio timestamptz; v_cfg jsonb;
  v_dur numeric; v_marg numeric; v_fim timestamptz; v_out jsonb;
begin
  select valor into v_cfg from jarvis.estado where chave = 'turno';
  v_dur  := coalesce((v_cfg->>'duracao_horas')::numeric, 6);
  v_marg := coalesce((v_cfg->>'margem_min')::numeric, 10);
  v_dia  := (p_ref at time zone 'America/Sao_Paulo')::date;

  select min(create_time) into v_inicio
    from jarvis.mensagens
   where is_dono
     and (create_time at time zone 'America/Sao_Paulo')::date = v_dia;

  if v_inicio is null then
    v_out := jsonb_build_object('data', v_dia, 'inicio_utc', null, 'fim_alerta_utc', null,
                                'duracao_horas', v_dur, 'margem_min', v_marg,
                                'nota', 'a pessoa ainda nao falou nada hoje; sem ancora de turno');
  else
    v_fim := v_inicio + make_interval(mins => (v_dur * 60 - v_marg)::int);
    v_out := jsonb_build_object('data', v_dia,
                                'inicio_utc', to_char(v_inicio, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                'fim_alerta_utc', to_char(v_fim, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                'inicio_brt', to_char(v_inicio at time zone 'America/Sao_Paulo', 'HH24:MI'),
                                'fim_alerta_brt', to_char(v_fim at time zone 'America/Sao_Paulo', 'HH24:MI'),
                                'duracao_horas', v_dur, 'margem_min', v_marg);
  end if;

  update jarvis.estado set valor = v_out, atualizado_em = now() where chave = 'turno';
  return v_out;
end $$;

-- ------------------------------------------------------------------- briefing
-- UMA chamada devolve tudo que o prompt precisa, com teto de tamanho em CADA lista.
-- E isto que impede o prompt de inflar rodando 96x por dia.
create or replace function jarvis.briefing(p_texto_novo text default '', p_top int default null)
returns jsonb language plpgsql stable as $$
declare v_cfg jsonb; v_top int; v_out jsonb;
begin
  select valor into v_cfg from jarvis.estado where chave = 'config';
  v_top := coalesce(p_top, (v_cfg->>'top_assuntos')::int, 8);

  select jsonb_build_object(
    'agora_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'agora_brt', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI'),
    'config',    v_cfg,
    'watermark', (select valor from jarvis.estado where chave = 'watermark'),
    'turno',     (select valor from jarvis.estado where chave = 'turno'),
    'pessoas',   (select valor from jarvis.estado where chave = 'pessoas'),
    'ruido',     (select valor->'spaces_ignorar' from jarvis.estado where chave = 'ruido'),

    'pendentes', coalesce((
      select jsonb_agg(x order by x->>'alerta_em_utc')
        from (
          select jsonb_build_object(
                   'id', c.id, 'tipo', c.tipo, 'titulo', c.titulo,
                   'quando_brt',    to_char(c.quando_utc    at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                   'alerta_em_brt', to_char(c.alerta_em_utc at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                   'alerta_em_utc', to_char(c.alerta_em_utc, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                   'atrasado', c.alerta_em_utc < now(),
                   'space', c.space_origem_nome,
                   'origem', left(c.origem_texto, 160),
                   'cal', c.calendar_event_id
                 ) as x
            from jarvis.compromissos c
           where c.status = 'pendente'
             and c.alerta_em_utc < now() + interval '21 days'
           order by c.alerta_em_utc
           limit 60
        ) s), '[]'::jsonb),

    'mudancas_recentes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ts_brt', to_char(e.ts at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'acao', e.acao, 'compromisso_id', e.compromisso_id,
               'motivo', left(coalesce(e.motivo, ''), 120))
             order by e.ts desc)
        from (select * from jarvis.eventos where ts > now() - interval '7 days'
              order by ts desc limit 25) e), '[]'::jsonb),

    'assuntos_relevantes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'chave', r.chave, 'titulo', r.titulo, 'resumo', r.resumo,
               'pessoas', r.pessoas, 'mencoes', r.mencoes,
               'ultima_vez_brt', to_char(r.ultima_vez at time zone 'America/Sao_Paulo', 'DD/MM')))
        from jarvis.assuntos_relevantes(p_texto_novo, v_top) r), '[]'::jsonb),

    'silencio_dele', coalesce((
      select jsonb_agg(jsonb_build_object(
               'space', m.space_nome, 'de', coalesce(m.autor_nome, m.autor_id),
               'quando_brt', to_char(m.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'texto', left(m.texto, 200)) order by m.create_time desc)
        from jarvis.mensagens m
       where not m.is_dono
         and m.texto like '%?%'
         and m.create_time > now() - interval '3 days'
         and m.create_time < now() - make_interval(hours => coalesce((v_cfg->>'silencio_pergunta_horas')::int, 4))
         and not exists (
               select 1 from jarvis.mensagens r
                where r.space_id = m.space_id and r.is_dono and r.create_time > m.create_time)
       limit 15), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $$;

-- ---------------------------------------- consulta auxiliar (diagnostico)
create or replace function jarvis.alertas_proximos(p_horas int default 48)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'fingerprint', c.fingerprint,
           'tipo', c.tipo,
           'titulo', c.titulo,
           'alerta_em_utc', to_char(c.alerta_em_utc, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
           'quando_brt', to_char(c.quando_utc at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
           'mensagem', coalesce(
             c.mensagem_alerta,
             '*' || c.titulo || '*' ||
             coalesce(' - ' || to_char(c.quando_utc at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ''))
         ) order by c.alerta_em_utc), '[]'::jsonb)
    from jarvis.compromissos c
   where c.status = 'pendente'
     and c.alerta_em_utc < now() + make_interval(hours => p_horas)
$$;

-- Vestigial: existia para reconciliar um entregador externo que anotava em arquivo.
-- Hoje a entrega mora no banco e marca 'disparado' na mesma transacao. Mantida caso
-- algum dia um entregador de fora volte a existir.
create or replace function jarvis.marcar_disparados(p_disparos jsonb, p_run_id text)
returns jsonb language plpgsql as $$
declare v_n int := 0; d jsonb;
begin
  for d in select * from jsonb_array_elements(coalesce(p_disparos, '[]'::jsonb)) loop
    update jarvis.compromissos
       set status = 'disparado',
           disparado_em = coalesce((d->>'disparado_em')::timestamptz, now()),
           atualizado_em = now()
     where id = (d->>'id')::bigint and status = 'pendente';
    if found then
      v_n := v_n + 1;
      insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
      values ((d->>'id')::bigint, 'disparou',
              coalesce(d->>'nota', 'postado por entregador externo'), p_run_id);
    end if;
  end loop;
  return jsonb_build_object('marcados', v_n);
end $$;

-- ----------------------------------------------------------------------- poda
create or replace function jarvis.podar(p_run_id text default null)
returns jsonb language plpgsql as $$
declare v_msgs int; v_evt int; v_exp int; v_tol int;
begin
  select coalesce((valor->>'tolerancia_atraso_min')::int, 90) into v_tol
    from jarvis.estado where chave = 'config';

  -- expira o que passou tanto da hora que avisar agora seria pior que calar
  with venc as (
    update jarvis.compromissos
       set status = 'expirado', atualizado_em = now(),
           cancelado_motivo = 'venceu sem ninguem ver (maquina fora do ar?)'
     where status = 'pendente'
       and alerta_em_utc < now() - make_interval(mins => v_tol)
    returning id, titulo
  )
  insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
  select id, 'expirou', 'passou ' || v_tol || ' min da hora do alerta', p_run_id from venc;
  get diagnostics v_exp = row_count;

  delete from jarvis.mensagens where create_time < now() - interval '7 days';
  get diagnostics v_msgs = row_count;

  delete from jarvis.eventos where ts < now() - interval '180 days';
  get diagnostics v_evt = row_count;

  return jsonb_build_object('mensagens_apagadas', v_msgs, 'eventos_apagados', v_evt,
                            'compromissos_expirados', v_exp);
end $$;

-- ------------------------------------------------------------- fechar a run
-- O watermark SO avanca aqui. Run que morreu no meio nao avanca e a proxima
-- reprocessa a janela inteira.
create or replace function jarvis.fechar_run(p_run_id text, p_ate timestamptz, p_resultado jsonb)
returns jsonb language plpgsql as $$
begin
  update jarvis.estado
     set valor = jsonb_build_object('ultimo_ok_iso', to_char(p_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'run_id', p_run_id),
         atualizado_em = now()
   where chave = 'watermark';

  update jarvis.estado
     set valor = jsonb_build_object('ultima_run_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'run_id', p_run_id, 'resultado', p_resultado),
         atualizado_em = now()
   where chave = 'heartbeat';

  perform jarvis.soltar_lock(p_run_id);
  return jsonb_build_object('ok', true, 'watermark', to_char(p_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'));
end $$;
```

---

## 5b. As migracoes seguintes

> **Para instalar, use [`sql/00-fundacao/`](sql/00-fundacao/).** Aquela pasta e o estado
> atual do banco em 8 arquivos ordenados — schema, funcoes, entrega, porta e seed —
> e inclui tudo que as 17 migracoes abaixo fizeram. As secoes 3 a 5 deste arquivo
> transcrevem as tres primeiras migracoes com o raciocinio de cada decisao: leia para
> **entender**, aplique a pasta para **montar**. Nao faca os dois.

As migracoes 1 a 3 estao acima na integra porque sao a fundacao: schema, invariantes e o
ciclo da run. As seguintes nunca foram transcritas aqui — eram ~20 KB de SQL que iriam
divergir da realidade no primeiro ajuste. O efeito colateral disso era que o Passo 6 do
`COMO_INSTALAR.md` mandava criar `jarvis.entregar()` sem dar o codigo, e ninguem conseguia
instalar; a pasta `sql/00-fundacao/` existe para tapar exatamente esse furo.

Na ordem em que foram aplicadas:

| migracao | o que traz |
|---|---|
| `jarvis_chat_memoria_remota` | schema e as 5 tabelas (secao 3) |
| `jarvis_chat_funcoes` | invariantes de escrita (secao 4) |
| `jarvis_chat_ciclo_da_run` | lock, turno, briefing, poda, fechar_run (secao 5) |
| `jarvis_chat_tipo_aviso` | o tipo `aviso`, para o agente contar o que fez |
| `jarvis_entrega_remota_extensoes` | extensao `http` e o slot do segredo no Vault |
| `jarvis_entrega_remota_funcoes` | `token_google`, `postar_chat`, `entregar` |
| `jarvis_entrega_cron_5min` | o `cron.job` de 5 minutos |
| `jarvis_porta_capacidade` | `jarvis.credencial` e `public.jarvis_rpc` |
| `jarvis_guardar_google_no_cofre` | `guardar_google` (abandonada, ver secao 10b) |
| `jarvis_mencionar_no_alerta` | a marcacao `<users/ID>` no texto |
| `jarvis_atraso_honesto_e_tolerancia_por_tipo` | nota de atraso so quando houve atraso |
| `jarvis_rotulos_tipo_e_prioridade` | `jarvis.rotulo` e a coluna `prioridade` |
| `jarvis_entrega_por_webhook_com_rotulo` | `postar_webhook` e a escolha do caminho |
| `jarvis_vigia_do_cerebro` | `jarvis.vigiar` |
| `jarvis_prompt_da_nuvem_no_banco` | tabela `jarvis.prompt` |
| `jarvis_calendario_pelo_banco` | `jarvis.calendario` e a porta atualizada |
| `jarvis_entrega_em_lote` | vários vencidos viram uma mensagem só |

Para reconstruir num projeto novo **nao siga esta lista** — o historico de migracoes vive
no projeto Supabase de quem construiu, e voce nao tem acesso a ele. Aplique
`sql/00-fundacao/` na ordem numerica. A lista acima serve para saber *quando* cada peca
entrou e por que. Para inspecionar uma funcao especifica no ar,
`select pg_get_functiondef('jarvis.entregar(text)'::regprocedure)`.

## 6. Seed do estado

> Prefira **`sql/00-fundacao/08-seed.sql`**, que e este seed atualizado e comentado. O
> bloco abaixo cria 7 chaves; sao **9** as necessarias. Faltam `visto` e `ultima_entrega`,
> e a falta e silenciosa: `fechar_run` e `entregar` fazem `update` nelas, e um `update` em
> linha inexistente nao da erro — so nao grava. Sem `visto`, `tem_trabalho` acha que nada
> mudou desde a run anterior e o cerebro nunca trabalha.

`execute_sql`. **Troque os valores pelos que você descobriu no passo 2.**

O `pessoas` abaixo é só exemplo de formato. **Comece com `{}`** e deixe o agente
preencher sozinho — ele tem instrução para isso no passo 7 do prompt.

```sql
insert into jarvis.estado (chave, valor) values
('watermark', '{"ultimo_ok_iso": null, "nota": "null = primeira run le as ultimas 24h"}'::jsonb),
('turno',     '{"data": null, "inicio_utc": null, "fim_alerta_utc": null, "duracao_horas": 6, "margem_min": 10}'::jsonb),
('heartbeat', '{"ultima_run_utc": null, "run_id": null, "resultado": null}'::jsonb),
('lock',      '{"run_id": null, "expira_utc": null}'::jsonb),
('config',    '{"space_alerta": "spaces/SEU_SPACE_ID", "space_alerta_nome": "Alertas do Jarvis", "self_user_id": "users/SEU_USER_ID", "email": "voce@suaempresa.com", "antecedencia_reuniao_min": 10, "antecedencia_prazo_min": 20, "tolerancia_atraso_min": 90, "silencio_pergunta_horas": 4, "top_assuntos": 8}'::jsonb),
('ruido',     '{"spaces_ignorar": ["Nome de um espaco barulhento", "Outro espaco so de robo"], "nota": "so entra se citarem a pessoa pelo nome; o proprio space_alerta deve estar aqui"}'::jsonb),
('pessoas',   '{
  "users/SEU_USER_ID": "Seu Nome (voce)",
  "users/000000000000000000001": "Colega Exemplo Um",
  "users/000000000000000000002": "Colega Exemplo Dois"
}'::jsonb)
on conflict (chave) do nothing
returning chave;
```

Precisa devolver 7 linhas.

---

## 7. Smoke test do banco — **não pule**

Rode os 4 blocos abaixo em sequência. Cada um tem um resultado esperado explícito. Se
qualquer um divergir, corrija antes de escrever os scripts.

**7.1 — gravação idempotente e cálculo da jornada**

```sql
select jarvis.gravar_mensagens('[
  {"space_id":"spaces/TESTE","space_nome":"Espaco de Teste","autor_id":"users/SEU_USER_ID","autor_nome":"dono","texto":"bom dia, hoje eu entrego o relatorio de CTR ate amanha","create_time":"2026-09-01T11:05:00-03:00","is_dono":true},
  {"space_id":"spaces/TESTE","space_nome":"Espaco de Teste","autor_id":"users/000000000000000000002","autor_nome":"Colega","texto":"dono, voce viu o dashboard de CTR? preciso da resposta hoje","create_time":"2026-09-01T11:20:00-03:00","is_dono":false},
  {"space_id":"spaces/TESTE","space_nome":"Espaco de Teste","autor_id":"users/SEU_USER_ID","autor_nome":"dono","texto":"marquei reuniao 10h30 pra falar do funil reverso","create_time":"2026-09-01T09:03:00-03:00","is_dono":true}
]'::jsonb) as gravou,
jarvis.gravar_mensagens('[
  {"space_id":"spaces/TESTE","space_nome":"Espaco de Teste","autor_id":"users/SEU_USER_ID","autor_nome":"dono","texto":"marquei reuniao 10h30 pra falar do funil reverso","create_time":"2026-09-01T09:03:00-03:00","is_dono":true}
]'::jsonb) as regravou_igual,
jarvis.definir_turno('2026-09-01T14:00:00-03:00'::timestamptz) as turno;
```

Esperado: `gravou.novas = 3`; `regravou_igual.novas = 0` (o `unique` segurou);
`turno.inicio_brt = "09:03"` e `turno.fim_alerta_brt = "14:53"` (09:03 + 5h50).

**7.2 — criar, repetir, remarcar, prazo "até amanhã"**

```sql
select
  jarvis.upsert_compromisso('reuniao','Funil reverso','2026-09-01T10:20:00-03:00'::timestamptz,
    'marquei reuniao 10h30 pra falar do funil reverso','teste-1',
    'Opa, reuniao *Funil reverso* em 10 min (10:30).', '2026-09-01T10:30:00-03:00'::timestamptz,
    null,'spaces/TESTE','Espaco de Teste',null,'dono','evt_abc123') as a_criou,
  jarvis.upsert_compromisso('reuniao','Funil reverso','2026-09-01T10:20:00-03:00'::timestamptz,
    'marquei reuniao 10h30 pra falar do funil reverso','teste-2', null,
    '2026-09-01T10:30:00-03:00'::timestamptz,
    null,'spaces/TESTE','Espaco de Teste',null,'dono','evt_abc123') as b_repetiu,
  jarvis.upsert_compromisso('reuniao','Funil reverso','2026-09-01T14:50:00-03:00'::timestamptz,
    'remarquei pra 15h','teste-3', null, '2026-09-01T15:00:00-03:00'::timestamptz,
    null,'spaces/TESTE','Espaco de Teste',null,'dono','evt_abc123') as c_remarcou,
  jarvis.upsert_compromisso('prazo','Relatorio de CTR','2026-09-01T14:53:00-03:00'::timestamptz,
    'hoje eu entrego o relatorio de CTR ate amanha','teste-4',
    'Voce disse que entrega o *relatorio de CTR* ate amanha. Seu turno acaba em 10 min.',
    '2026-09-02T18:00:00-03:00'::timestamptz,null,'spaces/TESTE','Espaco de Teste') as d_prazo;
```

Esperado, nesta ordem: `criou` (id 1) → `inalterado` (**mesmo id 1**) →
`atualizou` (**ainda id 1**, não um id novo) → `criou` (id 2).

Se `c_remarcou` devolver um id novo, o `p_calendar_event_id` não está chegando e cada
remarcação vai gerar um alerta duplicado.

**7.3 — a regra do zumbi cancelado (o teste mais importante)**

```sql
select
  jarvis.encerrar_compromisso(1,'cancelado','a pessoa escreveu "cancela a reuniao do funil, fica pra semana que vem"','teste-5') as e_cancelou,
  jarvis.upsert_compromisso('reuniao','Funil reverso','2026-09-01T14:50:00-03:00'::timestamptz,
    'marquei reuniao 10h30 pra falar do funil reverso','teste-6', null,
    '2026-09-01T15:00:00-03:00'::timestamptz,null,'spaces/TESTE','Espaco de Teste',
    null,'dono','evt_abc123') as f_nao_ressuscita,
  jarvis.upsert_compromisso('reuniao','Funil reverso','2026-09-08T10:20:00-03:00'::timestamptz,
    'reagendei o funil pra terca que vem 10h30','teste-7', null,
    '2026-09-08T10:30:00-03:00'::timestamptz,null,'spaces/TESTE','Espaco de Teste',
    null,'dono','evt_abc123') as g_ressuscita,
  jarvis.upsert_assunto('funil-reverso','Funil reverso de vagas',
    'Projeto de analise do funil reverso. Ana pediu o dashboard de CTR em 01/09. Reuniao remarcada de 01/09 10h30 para 08/09 10h30.',
    array['dono','Ana'], array['Espaco de Teste']) as h_assunto;
```

Esperado: `cancelado` → `inalterado` com nota `"estava cancelado e a hora nao mudou"` →
`atualizou` com `status_antes: "cancelado"` → assunto `novo: true`.

O `f_nao_ressuscita` é o que impede o agente de reabrir a cada 15 minutos exatamente o que
a pessoa acabou de cancelar — porque a mensagem original ("marquei reunião 10h30")
continua no histórico e vai ser lida de novo na próxima janela.

**7.4 — guarda anti-alucinação, briefing, e limpeza**

```sql
do $$
begin
  begin
    perform jarvis.upsert_compromisso('prazo','Coisa inventada', now(), '   ', 'teste-8');
    raise notice 'FALHOU: deixou criar sem citacao';
  exception when others then
    raise notice 'OK guarda funcionou: %', sqlerrm;
  end;
end $$;

select jsonb_pretty(jarvis.briefing('reuniao funil reverso relatorio CTR dashboard'));

delete from jarvis.eventos where run_id like 'teste-%';
delete from jarvis.compromissos where space_origem = 'spaces/TESTE';
delete from jarvis.mensagens where space_id = 'spaces/TESTE';
delete from jarvis.assuntos where chave = 'funil-reverso';
update jarvis.estado set valor = '{"data": null, "inicio_utc": null, "fim_alerta_utc": null, "duracao_horas": 6, "margem_min": 10}'::jsonb where chave = 'turno';

select (select count(*) from jarvis.mensagens) as msgs,
       (select count(*) from jarvis.compromissos) as compromissos,
       (select count(*) from jarvis.assuntos) as assuntos,
       (select count(*) from jarvis.eventos) as eventos;
```

Esperado: o `notice` diz `OK guarda funcionou`; o briefing traz `pendentes`,
`assuntos_relevantes` com o funil-reverso, `turno` preenchido; e os 4 contadores voltam a
zero no final.

---

## 8. Os dois prompts do cérebro

São dois arquivos, com a mesma lógica e fontes de dados diferentes:

- **`prompt-escuta.md`** — o cérebro local. Lê Chat e Calendar pelo MCP `google-workspace`
  e o banco pelo MCP do Supabase. Copie literalmente, trocando o email da pessoa e o id do
  projeto.
- **`prompt-nuvem.md`** — o cérebro da nuvem. Lê o Chat pela API REST (credenciais do
  ambiente), o Calendar pelo conector, e o banco pela porta `jarvis_rpc`. Este é a fonte
  de edição da tabela `jarvis.prompt`; depois de mudar o arquivo, suba o corpo para o
  banco.

Estrutura dos dois, para você entender o que não pode sair:

| passo | o que faz | por que existe |
|---|---|---|
| 1 | lock + watermark + config + `now()` | lê **desde o watermark**, nunca "últimos 15 min" |
| 2 | ler o Chat, **uma** varredura | são ~291 espaços; varrer um por um dá 291 chamadas |
| 3 | ler o Calendar, 14 dias | o card de convite no Chat é pouco confiável |
| 4 | gravar cru + turno + briefing + podar, numa chamada | um round-trip só |
| 5 | decidir: 8 situações | é o miolo |
| 6 | reescrever assuntos + registrar gente nova | a memória longa |
| 7 | `fechar_run` | só aqui o watermark avança; a entrega não depende do cérebro |

Três coisas no prompt que parecem detalhe e não são:

1. **`p_ate` do `fechar_run` tem que ser o `now()` do passo 1**, não o horário do fim da
   run. Mensagem que chegou enquanto a run rodava precisa entrar na próxima janela.
2. **`p_origem_texto` é citação literal e obrigatória.** A função recusa vazio. A regra no
   prompt é: se não consegue apontar a frase exata, não crie — está adivinhando.
3. **Em `p_texto_novo` do briefing vão as palavras das mensagens novas concatenadas.** É
   isso que faz a busca full-text achar o assunto antigo relacionado. Sem isso a memória
   longa existe mas nunca é consultada.

---

## 9. `escuta.ps1`

Copie de `escuta.ps1` nesta pasta. Pontos que não são estilo:

- **`--model sonnet`**, não Opus. Roda 96x/dia.
- **`send_message` fica FORA do `--allowedTools`.** Não é esquecimento. O cérebro não fala;
  ele agenda. Se você adicionar, perde a deduplicação e ganha dois caminhos de entrega.
- **Lock de arquivo antes de chamar o `claude`**, com janela de 20 minutos. A primeira run
  (janela de 24h) levou ~17 minutos; em regime leva 2 a 4. O lock no banco é a segunda
  linha de defesa, não a primeira — não adianta pagar uma chamada para descobrir que
  outra run está viva.
- **PowerShell 5.1**: sem `&&`, sem `??`, sem ternário. Use `if/else`.
- **Falha enfileira uma linha em `falhas.jsonl`**, e quem drena é a *próxima run* do
  cérebro, no Passo 1b do `prompt-escuta.md`: ela junta tudo num `aviso` e esvazia o
  arquivo. É de propósito que o script não fale com o banco — assim não existe token do
  Supabase no disco desta máquina.
- **Duas redes, não uma.** O `falhas.jsonl` pega a falha isolada, que se cura sozinha na
  run seguinte e some sem rastro. O `jarvis.vigiar()` pega o caso grave — nenhuma run
  rodando há mais de 45 min, quando não há quem drene o arquivo. Uma não cobre a outra.
- Rotação em 30 logs.

```powershell
$tools = @(
    "mcp__claude_ai_Supabase__execute_sql",
    "mcp__google-workspace__search_messages",
    "mcp__google-workspace__get_messages",
    "mcp__google-workspace__list_spaces",
    "mcp__google-workspace__get_events",
    "Read",
    "Write"
) -join ","

$prompt | & claude -p --model sonnet --allowedTools $tools --permission-mode acceptEdits |
    Tee-Object -FilePath $log
```

---

## 10. A entrega, dentro do banco

Três funções, todas `security definer` e sem permissão para `anon`:

- **`jarvis.postar_webhook(texto)`** — o caminho preferido. Lê a URL do webhook do Vault
  (segredo `jarvis_chat_webhook`) e faz um POST. Sem autenticação, sem token para renovar.
- **`jarvis.postar_chat(space, texto, token)`** — reserva, via OAuth. Precisa de
  `jarvis.token_google()`, que troca o refresh token do Vault por um token de acesso.
- **`jarvis.entregar(origem)`** — a que o cron chama. Escolhe webhook se existir (e então
  nem renova token), monta o rótulo, e marca `status='disparado'` na mesma transação da
  seleção. É isso que garante uma entrega por compromisso, sem janela de corrida.

**Entrega em lote.** Tudo que vence no mesmo tique sai numa **mensagem só**, com um
cabeçalho `*N avisos agora*` e um aviso por bloco, separados por linha em branco. Dois
avisos legítimos chegando em sequência no celular são lidos como mensagem repetida —
foi o que aconteceu em 02/09. O lote é cortado em dois lugares: quando muda a prioridade
(o `alta` não viaja junto com rotina, senão o vermelho se dilui) e quando o texto passa
de 3.500 caracteres (o Chat corta em 4.096). Com um único vencido a mensagem é idêntica
à de antes — sem cabeçalho. Se o POST falhar, o lote inteiro continua `pendente` e volta
no tique seguinte; nenhum item é marcado.

**Por que webhook e não OAuth, mesmo tendo os dois:** postando com a credencial da pessoa,
a mensagem sai **como ela**, e o Google Chat não notifica ninguém das próprias mensagens —
a marcação `<users/ID>` aparecia mas não vibrava o celular. Pelo webhook a mensagem sai
como outra identidade, e a marcação notifica de verdade.

**Use `http` e não `pg_net`.** O fluxo é "renova o token E ENTÃO posta". `pg_net` é
assíncrono: cada chamada devolve um id para consultar depois, o que quebraria a entrega em
dois ticks. `http` é síncrono e ao volume disto (5 a 10 posts/dia) não custa nada.

**Não construa um poster próprio lendo o arquivo de credencial.** Foi tentado neste build
e barrado por classificador de segurança — a forma é indistinguível de um script que rouba
credencial. Era desnecessário: o webhook dispensa credencial.

```sql
select cron.schedule('jarvis-entrega', '*/5 * * * *',
  $$select jarvis.vigiar('cron'), jarvis.entregar('cron')$$);
```

### O rótulo visual

`jarvis.rotulo(tipo, prioridade)` é a **fonte única** do catálogo — mora no banco, não no
prompt, para o modelo não poder inventar emoji novo nem trocar o significado de um.

📅 `reuniao` · ⏳ `prazo` · 🤝 `promessa` · ❓ `pergunta_aberta` · 👀 `mencao` ·
⚡ `conflito` · ℹ️ `aviso` — com 🔴 na frente quando `prioridade = 'alta'`, e esses furam
a fila de entrega.

Duas decisões que impedem virar sopa de emoji: **um** emoji por tipo, sempre na primeira
posição; e prioridade com **dois níveis só**, marcando apenas o urgente — marcar "baixa
prioridade" não informa nada e gasta a atenção, e três níveis é onde o modelo chuta. O
prompt tem instrução explícita de **não escrever emoji** no texto: se escrever, sai duplo.

### O vigia

`jarvis.vigiar()` roda no mesmo cron. É o único lugar de onde se pode notar que o cérebro
morreu, porque é o que nunca dorme. Cria um `aviso` de prioridade alta quando o
`heartbeat` passa de 45 min sem sinal (dias de semana), ou quando houve 3+ falhas de
postagem em 2 horas (token revogado, webhook apagado).

Três travas contra spam: só entre 8h e 22h (fora disso a pessoa não age e o aviso queima),
fingerprint por hora (no máximo 1 aviso por hora de apagão), e silêncio no fim de semana.

## 10b. O cérebro na nuvem — e os tres limites da plataforma

Sao **quatro** rotinas `RemoteTrigger` horarias, defasadas: `:07`, `:22`, `:37`, `:52`.
Modelo Sonnet, ambiente com as credenciais de Chat, conector do Supabase anexado.

**Limite 1 — intervalo minimo de 1 HORA.** O servidor recusa `*/15 * * * *` com
`cron interval too short`. O contorno e a defasagem: cada rotina respeita o limite, e
juntas dao a cadencia de 15 minutos. Mesmo custo total (96 execucoes/dia).

Isso so e sustentavel porque **as instrucoes moram em `jarvis.prompt`**, no banco, e o
gatilho de cada rotina tem so um bootstrap de ~800 caracteres que busca o corpo. As quatro
leem o mesmo texto: mudar o comportamento e um `update`, nao editar quatro rotinas. Se o
prompt estivesse dentro do gatilho, seriam quatro lugares para manter em sincronia — e e
so questao de tempo até divergirem. A fonte de edicao e `prompt-nuvem.md`.

**Limite 2 — o proxy de saida do sandbox tem allowlist.** `googleapis.com` passa; o host
do Supabase e recusado com `403 connect_rejected`. Uma run inteira morreu nisso.

O contorno: **trafego de conector MCP nao passa por esse proxy** — vai por
`mcp-proxy.anthropic.com`, que esta na lista de excecoes do proprio proxy. Entao a rotina
fala com o banco por `mcp__Supabase__execute_sql`, nunca por curl ou urllib. Nenhuma
mudanca de configuracao foi necessaria.

**Limite 3 — os conectores de Chat e Calendar do Google dao erro de permissao** dentro da
rotina (`chatmcp.googleapis.com` e `calendarmcp.googleapis.com`; o app nao esta liberado no
Workspace). E o ambiente da rotina so tem credencial de **Chat**.

- Chat: lido pela API REST classica com `GOOGLE_CHAT_*` do ambiente. O desenho que torna
  viavel: `GET /v1/spaces?pageSize=1000` traz `lastActiveTime` por espaco; filtrando pela
  janela, ~291 espacos caem para menos de 10, lidos em paralelo com threads.
- Calendar: **o banco busca**, por `jarvis.calendario(dias)`, usando a credencial do cofre
  (que tem escopo de Calendar). O cerebro pede `rpc("calendario", {"dias": 14})` e recebe
  os eventos ja em BRT, com `event_id`, link do Meet e participantes.

O padrao do limite 3 e o mais reutilizavel deste projeto: **quando o agente precisa de uma
credencial que ele nao deve carregar, mova a CAPACIDADE para onde a credencial ja mora, em
vez de mover a credencial para onde o agente esta.** Tentar o contrario foi barrado tres
vezes — duas por classificador e uma pela propria rotina, que recusou executar e mandou
notificacao. As tres recusas estavam certas.

### A porta `jarvis_rpc`

`public.jarvis_rpc(p_token, p_fn, p_args)`. Chamavel com a chave publicavel, exige um token
proprio cujo **hash** mora em `jarvis.credencial`, e despacha so para uma lista fixa de
operacoes. Nao aceita SQL nem nome de tabela.

A alternativa descartada foi a `service_role` key no ambiente da rotina: ela da acesso
total ao projeto, que aqui tem 150+ tabelas de outros sistemas. Token da porta vazado
significa "mexeram no meu Jarvis"; service_role vazada significa "leram tudo".

Note que a rotina tem o MCP do Supabase, que por si so alcanca o banco inteiro. A porta
continua valendo por outro motivo: ela e a **API do agente**, e garante os invariantes
(citacao obrigatoria, dedupe, teto de 1200 caracteres, historico) que o prompt nao pode
furar nem por engano.

### Os cinco cerebros e o lock

Quatro na nuvem e um local. Todos chamam `jarvis.tentar_lock` primeiro. **Abortar por lock
tomado e o comportamento correto, nao erro** — o prompt diz isso explicitamente, senao o
modelo trata como falha, insiste, e voce ganha trabalho duplicado.

## 10c. Criar o ambiente e as quatro rotinas — os comandos

A seção 10b explica o desenho e os limites. Esta é a parte operacional: o que clicar, o que
colar, e o comando de criação.

### O ambiente de nuvem

As rotinas rodam num **ambiente de nuvem** da conta do Claude. Este projeto usa o ambiente
`Default` (`env_01BHtejRkqFuNictopwsJ6n1`).

Onde mexer: `claude.ai/code` → no compositor, o **chip do ambiente** (ao lado de
"Selecionar repositório") → **Nuvem** → `Default`, ou **Adicionar ambiente em nuvem**.

O diálogo tem quatro campos (conferido em 02/09/2026):

| campo | o que é | o que usar aqui |
|---|---|---|
| **Nome** | rótulo do ambiente | `Default` |
| **Acesso à rede** | Nenhum / **Confiável** (recomendado) / Completo / Personalizado | `Confiável` |
| **Variáveis de ambiente** | texto em formato `.env` | as três `GOOGLE_CHAT_*` |
| **Script de configuração** | bash que roda antes da sessão | vazio |

**As três variáveis:**

```
GOOGLE_CHAT_CLIENT_ID=<client id>.apps.googleusercontent.com
GOOGLE_CHAT_CLIENT_SECRET=<client secret>
GOOGLE_CHAT_REFRESH_TOKEN=<refresh_token>
```

As três saem do mesmo lugar: o cliente OAuth da seção 1b.2 e o arquivo
`~/.google_workspace_mcp/credentials/voce@suaempresa.com.json` (campo `refresh_token`).
O prompt na nuvem troca o refresh token por um token de acesso em
`https://oauth2.googleapis.com/token` e lê o Chat pela REST.

⚠️ **O próprio diálogo avisa: as variáveis são visíveis para qualquer pessoa que use o
ambiente. Não é cofre.** É por isso que só a credencial de Chat mora ali — que no pior caso
significa "alguém lê e posta no Chat dele" — e nunca a `service_role` do Supabase, que
significaria "alguém leu 150 tabelas de outros sistemas". A credencial de Calendar também
não entra: quem tem escopo de Calendar é o cofre do banco (limite 3 da seção 10b).

**Sobre "Acesso à rede".** `Confiável` é o nível que barra o host do Supabase com
`403 connect_rejected` — o limite 2. Existe uma saída de configuração que a seção 10b não
menciona porque não foi usada: o nível **Personalizado** aceita uma lista de domínios
permitidos, e `SEU_PROJECT_REF.supabase.co` ali resolveria o bloqueio. **Continue em
`Confiável`**: falar com o banco pelo conector MCP já funciona, e abrir a rede do ambiente
por conveniência troca uma restrição útil por nada. A alternativa fica registrada para o dia
em que algo precisar de um host que não tenha conector.

### O gatilho das quatro rotinas

Cada rotina carrega só um **bootstrap**: quem ela é, como falar com o banco, e o token da
porta. As instruções de verdade vêm de `jarvis.prompt`. É o que permite mudar comportamento
com um `update` em vez de editar quatro rotinas.

Bootstrap das rotinas `:22`, `:37` e `:52` (935 caracteres, o modelo a copiar):

~~~text
Você é o cérebro do Jarvis, o agente de alertas do Seu Nome (voce@suaempresa.com). Ninguém acompanha esta execução — vá até o fim.

Suas instruções completas moram no banco do próprio agente, para poderem ser atualizadas sem mexer nesta rotina. Busque-as e siga.

Use a ferramenta `mcp__Supabase__execute_sql` no projeto `SEU_PROJECT_REF`:

```sql
select public.jarvis_rpc('<TOKEN DA PORTA>', 'prompt');
```

Esse token é a credencial de capacidade deste agente — as instruções explicam como usá-lo nas demais chamadas.

Leia o campo `corpo` inteiro e execute do início ao fim. Ele diz onde você está rodando, como falar com o banco, e as regras que você não pode furar.

Se voltar `{"erro": "token invalido"}`, ou se o conector do Supabase não estiver disponível, **pare e imprima isso**. Sem as instruções não improvise: decisão errada aqui gera alerta falso no Chat dele.
~~~

`<TOKEN DA PORTA>` é o token em claro de `public.jarvis_rpc` — 64 caracteres hex. **O banco
guarda só o hash**, então ele não é recuperável por SQL. Para ler o que está em uso:
`RemoteTrigger` com `action: "get"` em qualquer uma das quatro. Se for rotacionado, as quatro
precisam ser atualizadas juntas.

### O comando de criação

Uma chamada por rotina, mudando só `name` e `cron_expression`:

```
RemoteTrigger  action: "create"  body:
{
  "name": "Jarvis — cérebro :07",
  "cron_expression": "7 * * * *",
  "enabled": true,
  "persist_session": false,
  "session_request": {
    "environment_id": "env_01BHtejRkqFuNictopwsJ6n1",
    "config": {
      "model": "claude-sonnet-5",
      "allowed_tools": ["preset:default", "Bash", "Read", "Write", "TodoWrite"]
    },
    "events": [
      { "payload": { "type": "user",
                     "message": { "role": "user", "content": "<o bootstrap acima>" } } }
    ]
  },
  "mcp_connections": [
    { "name": "Supabase", "transport_type": "http",
      "url": "https://mcp.supabase.com/mcp",
      "connector_uuid": "51ccbfef-b934-43cb-9141-24e358308c6d" }
  ]
}
```

As quatro, hoje:

| rotina | cron | id |
|---|---|---|
| Jarvis — cérebro :07 | `7 * * * *` | `trig_016HYVtYu6Q4LCNzyLTuLc7T` |
| Jarvis — cérebro :22 | `22 * * * *` | `trig_01GjgZQsJjSVhbBG2h4Uxp1M` |
| Jarvis — cérebro :37 | `37 * * * *` | `trig_01WLrEgwpT63J2P2E5RDM9L8` |
| Jarvis — cérebro :52 | `52 * * * *` | `trig_01Hs3Heko7bNc98bVKVavbKB` |

Cinco detalhes que só se descobrem errando:

1. **O cron é UTC**, não BRT. Aqui não importa (é de hora em hora), mas importa para
   qualquer rotina com hora fixa — o Resumo 7h é `0 10 * * *` justamente porque 10:00 UTC é
   07:00 em Brasília. Errar isso publica o resumo no meio da tarde.
2. **`Bash` na lista de ferramentas é obrigatório.** O prompt manda montar JSON com
   `python3` e `json.dumps` para não estragar a query com acento e apóstrofo; sem Bash o
   modelo escreve o SQL à mão e a run morre em erro de sintaxe.
3. **`connector_uuid` só existe para conector já autorizado na conta.** Não se inventa: pegue
   de uma rotina existente com `action: "get"`, ou autorize o conector na interface antes.
4. **Não anexe os conectores de Chat e Calendar do Google.** As quatro rotinas hoje ainda
   têm o `Google_Calendar` anexado, e ele não serve para nada: dá erro de permissão
   (limite 3). Numa criação nova, deixe só o Supabase.
5. **`persist_session: false`.** Cada execução começa limpa; a memória é o banco, não a
   sessão. Com sessão persistida, quatro rotinas de hora em hora acumulam contexto e o custo
   cresce sem que nada melhore.

### Conferir e disparar na mão

```
RemoteTrigger  action: "list"                      -> todas, com next_run_at e last_run
RemoteTrigger  action: "run"        trigger_id: …  -> dispara agora
RemoteTrigger  action: "list_runs"  trigger_id: …  -> execuções recentes
RemoteTrigger  action: "get_run_log" session_id: … -> o log condensado de uma execução
RemoteTrigger  action: "update"     trigger_id: …  body: {"enabled": false}
```

Execução espontânea confirmada: a `:52` rodou às 17:52 UTC de 02/09/2026 com status
`SUCCEEDED`, sem disparo manual — o que fechou a última pendência da migração.

---

## 11. Registrar a tarefa do cérebro local

Só **uma** tarefa do Windows. A entrega virou cron no banco, e a tarefa `Jarvis Dispara`
foi removida em 01/09/2026.

**Duas armadilhas do Windows, as duas custaram tempo neste build:**

1. Tarefa criada sem `-AllowStartIfOnBatteries` e `-WakeToRun` **nunca roda** num
   notebook. A rotina anterior deste projeto ficou 3 semanas registrada e inerte por isso.
2. Tarefa com `LogonType=Interactive` **pisca uma janela de console** a cada execução.
   `-WindowStyle Hidden` não resolve: o console nasce antes de o PowerShell poder se
   esconder. Rodar como S4U resolveria, mas exige admin. A saída sem admin é um lançador
   `.vbs` — o terceiro argumento de `WScript.Shell.Run` é o estilo de janela, e `0` é
   oculta.

`oculto.vbs` (recebe o caminho do `.ps1` como argumento):

```vbscript
Dim sh, ps1
Set sh = CreateObject("WScript.Shell")
ps1 = WScript.Arguments(0)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & ps1 & Chr(34), 0, False
```

```powershell
$base = "C:\jarvis-chat"
$dur = New-TimeSpan -Days 3650   # [TimeSpan]::MaxValue falha em algumas versoes

$acao = New-ScheduledTaskAction -Execute "wscript.exe" `
  -Argument "`"$base\oculto.vbs`" `"$base\escuta.ps1`""
$gat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration $dur
$cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName "Jarvis Escuta" -Action $acao -Trigger $gat -Settings $cfg `
  -Description "Jarvis Chat: le Google Chat + Calendar a cada 15 min e agenda alertas." -Force
```

Confirme que a repetição pegou — `Register-ScheduledTask` aceita e às vezes descarta:

```powershell
Get-ScheduledTask -TaskName "Jarvis*" | ForEach-Object {
  $t = $_.Triggers[0]; $s = $_.Settings
  "{0,-16} intervalo={1,-8} bateria_ok={2,-5} acorda={3}" -f `
    $_.TaskName, $t.Repetition.Interval, (-not $s.DisallowStartIfOnBatteries), $s.WakeToRun
}
```

Esperado: `intervalo=PT15M`, `bateria_ok=True`, `acorda=True`.

**Encoding, ou todo acento vira `?`.** PowerShell 5.1 manda texto para executável externo
na codificação antiga do console. Sem estas duas linhas no topo do `escuta.ps1`, o prompt
chega mutilado do outro lado e os alertas saem com "voc?" e "n?o":

```powershell
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
```

## 12. Verificação ponta a ponta

**12.1 — a entrega, caminho vazio.** Sem nada vencido:

```sql
select jarvis.entregar('teste');
```

Esperado: `{"devidos": 0}`, instantâneo. Se demorar ou renovar token, a checagem barata
está na ordem errada — ela tem que vir antes de qualquer chamada de rede.

**12.2 — a entrega, caminho real.** Crie um compromisso vencido 2 minutos atrás e dispare:

```sql
select jarvis.upsert_compromisso('aviso','Teste de entrega', now() - interval '2 min',
         'teste de instalacao','teste','Teste de ponta a ponta. Pode ignorar.'),
       jarvis.entregar('teste');
```

Esperado: `{"devidos":1,"entregues":1,"erros":0,"via":"webhook"}` e a mensagem no espaço,
começando com `ℹ️` e com a marcação da pessoa. Rode **de novo**: tem que voltar
`devidos: 0` — o `status='disparado'` segura. Apague o compromisso de teste depois.

**12.2b — confira QUEM postou.** Leia a mensagem de volta pela API do Chat e olhe o autor.
Se aparecer como a própria pessoa, a marcação **não vai notificar** — o Chat não avisa
ninguém das próprias mensagens. Tem que aparecer como a identidade do webhook.

**12.2c — os rótulos.** Crie um de cada tipo, dois deles com `prioridade => 'alta'`, e
dispare. Confira que os `alta` chegaram **primeiro** e com `🔴` na frente, e que nenhum
texto tem emoji duplicado.

**12.3 — a primeira run real do cérebro.** Rode `escuta.ps1` à mão. A primeira lê 24h e
pode levar 15 a 20 minutos; não a interrompa. Ela é a mais pesada que você vai ver.

Enquanto roda, acompanhe pelo banco:

```sql
select (select count(*) from jarvis.mensagens)    as msgs,
       (select count(*) from jarvis.compromissos) as compromissos,
       (select count(*) from jarvis.assuntos)     as assuntos,
       (select valor->>'ultimo_ok_iso' from jarvis.estado where chave='watermark') as watermark;
```

O `watermark` só sai de `null` no fim. Se a run terminar com `watermark` ainda `null`, ela
falhou antes do passo 8 — olhe o log em `logs\`.

Referência do que a primeira run deu neste build: **230 mensagens, 26 compromissos**
(24 reuniões do Calendar nos 14 dias à frente + 2 promessas em DM), **6 assuntos**
(400 a 620 caracteres cada, longe do teto de 1200).

**12.4 — a qualidade, que é o que importa.** Leia o que ele escreveu:

```sql
select tipo, titulo,
       to_char(alerta_em_utc at time zone 'America/Sao_Paulo','DD/MM HH24:MI') as alerta,
       left(mensagem_alerta, 160) as msg
  from jarvis.compromissos order by alerta_em_utc limit 20;

select chave, titulo, resumo from jarvis.assuntos;
```

Bom sinal num `mensagem_alerta`: diz **de que se trata**, não só que existe. "Em 10 min tem
a *Daily da Equipe* (09:45-10:00). Call: meet.google.com/xxx" é bom. "Reunião às 09:45" é ruim.

Bom sinal num `resumo`: tem quem está envolvido, o que ficou decidido, o que está pendente,
e **marca o que não se sabe** ("mensagem cortada, sem mais detalhe"). Se os resumos são
genéricos, o problema está no passo 7 do prompt.

**12.5 — cancelamento.** Apague no Calendar um evento que gerou compromisso e rode
`escuta.ps1`. Esperado: aquele compromisso vira `cancelado` com motivo, **e** nasce um
`tipo: aviso` com `alerta_em` = agora dizendo o que foi cancelado e por quê. Sem o aviso,
o requisito principal não está atendido — cancelar calado não serve.

**12.6 — reprocessamento sem duplicar.** Zere o watermark
(`update jarvis.estado set valor = '{"ultimo_ok_iso": null}'::jsonb where chave='watermark'`)
e rode de novo. Esperado: as mensagens não duplicam (o `unique`) e os compromissos voltam
`inalterado` (o `fingerprint`). Se duplicar, algum dos dois não está funcionando.

---

## 13. Decisões que parecem melhoráveis e não são

Se você for "melhorar" alguma destas, leia o motivo primeiro.

**"Por que não um relógio só, de 5 minutos, fazendo tudo?"** Seriam 288 chamadas de LLM
por dia para quase sempre não haver nada novo. A leitura do Chat não precisa de precisão
de 5 min; a entrega precisa. Daí a separação — e a entrega, sendo SQL puro, sai de graça.

**"Por que o cérebro não posta direto?"** Porque perderia a precisão de hora (ver acima),
porque duas portas de saída significam duas deduplicações para manter, e porque postando
com a credencial da pessoa a marcação dela não notifica. Com uma porta — o webhook, no
banco — o `fingerprint` e o `status` resolvem tudo.

**"Por que o cérebro é duplo (nuvem 1h + local 15 min) em vez de só nuvem?"** Porque
rotina na nuvem tem **mínimo de 1 hora**; o servidor recusa `*/15`. E porque a rede do
ambiente agendado pode não alcançar o banco (ver 10b). O local é o caminho rápido, a nuvem
é o piso.

**"Por que funções em vez de `insert` no prompt?"** Porque citação obrigatória,
deduplicação, teto de 1200 caracteres e log de antes/depois são invariantes. No prompt
eles dependem de o modelo lembrar da regra em 96 execuções por dia. Na função, não
dependem de nada.

**"Por que não pgvector / embeddings para a memória longa?"** Full-text em português
resolve, custa zero por busca, e não adiciona uma dependência que precisa de reindexação.
Se um dia a busca começar a errar, aí sim.

**"Por que guardar a conversa crua por 7 dias se o resumo já existe?"** Porque se o agente
extraiu errado, o original ainda está lá para a próxima run corrigir. Depois de 7 dias, o
que importava já virou assunto ou compromisso.

**"Por que o resumo do assunto é reescrito e não anexado?"** Anexar cresce sem limite e o
teto de 1200 caracteres passaria a truncar a informação **nova** — que é a mais
relevante. Reescrever força a decidir o que ainda importa.

**"Por que `is_dono` e não `is_self`?"** Só herança do build original. Se renomear,
renomeie nas funções `definir_turno` e `briefing` e no prompt.

---

## 14. Os furos de memória, e o que tapa cada um

Os quinze, e o mecanismo que tapa cada um:

1. **Buraco na janela** (máquina desligada, run falhou) → lê **desde o watermark**, nunca
   "últimos 15 min". `fechar_run` é o único que avança, e só no fim. Ficou 3h fora, lê 3h.
2. **Alerta que venceu com a máquina fora** → `dispara` tolera 90 min e posta marcando
   "(atrasado N min)". Mais velho vira `expirado` com linha em `eventos`, não desaparece.
3. **Reset de 24h apagar o que importava** → o reset é só do cru. Compromisso e assunto
   não têm validade.
4. **Contexto de 28 dias atrás** → `assuntos` + FTS português. O script monta a query com
   as palavras das mensagens novas.
5. **Banco lotando** → teto por tabela (7d / 180d / 1.200 chars) e resumo reescrito em vez
   de anexado.
6. **Prompt inflando** rodando 96x/dia → `briefing` tem limites embutidos: 60 pendentes,
   25 mudanças, 8 assuntos, 15 silêncios.
7. **Alerta duplicado** (mesma coisa dita de dois jeitos) → `fingerprint` = tipo + slug do
   título + hora arredondada a 5 min. Evento de calendário usa `cal:<event_id>`, então
   remarcar atualiza a mesma linha.
8. **Contradição** → `eventos` guarda `antes`/`depois`; o `briefing` devolve isso em
   `mudancas_recentes`.
9. **Duas runs se atropelando** → lock de arquivo no `escuta.ps1` (nem chama o claude) +
   `jarvis.tentar_lock` de 20 min no banco.
10. **Card de convite que não vem como texto** → não confia no card. Lê o Calendar direto
    (`get_events`, 14 dias) e compara com o banco.
11. **Nome voltando como `users/123`** → `estado.pessoas`, preenchido pelo agente conforme as pessoas aparecem.
12. **Fuso e horário de verão** → tudo em UTC (`timestamptz`), renderizado em
    `America/Sao_Paulo` só na hora de escrever.
13. **Supabase ou internet fora** → `pendente-envio.jsonl` local, e o watermark não avança.
14. **Agente inventando prazo** → `origem_texto` (citação literal) é obrigatória; a função
    recusa se vier vazia. Testado.
15. **Agente parar e ninguém notar** → `estado.heartbeat` em toda run.

---

## 15. Custo

- **Cérebro:** 96 chamadas Sonnet/dia. Em regime a janela é de 15 minutos de conversa,
  então o prompt é pequeno; o `briefing` tem teto embutido justamente para isso.
- **Entrega:** 288 execuções/dia de SQL, **custo zero de LLM**. As vazias saem sem tocar
  em rede. Cabe no plano do Supabase sem aparecer.
- **Banco:** ~2.800 linhas de mensagem em regime, e o resto são linhas pequenas. Não
  cresce.

---

## 16. Como desmontar

```powershell
Unregister-ScheduledTask -TaskName "Jarvis Escuta" -Confirm:$false
```

```sql
select cron.unschedule('jarvis-entrega');
drop schema jarvis cascade;
drop function if exists public.jarvis_rpc(text, text, jsonb);
drop function if exists public.jarvis_saude();
-- e os demais public.jarvis_*
```

Apague também, pelo painel do Supabase, os segredos `jarvis_google_chat` e
`jarvis_chat_webhook` do Vault. E desative as **quatro** rotinas na nuvem por
`RemoteTrigger` (`action: "list"` para achá-las por nome, depois `update` com
`enabled: false` em cada uma) — se ficarem ligadas sem o banco, cada uma vai falhar de
hora em hora e mandar notificação.

A extensão `http` foi ligada neste banco pelo Jarvis — pense duas vezes antes de
desligar, porque outro sistema pode ter passado a usar.

A pasta local pode ser apagada.

---

## 17. Becos sem saída — o que já foi tentado e não funciona

Cada linha aqui custou tempo entre 31/08 e 02/09/2026. Elas não são história: são caminhos
que **parecem** os óbvios e que você vai tentar de novo se não estiverem escritos.

| o que se tenta | o que acontece | o caminho que funciona |
|---|---|---|
| MCP do Google Chat na nuvem (`chatmcp.googleapis.com`) | `The caller does not have permission` em **todas** as ferramentas. O app não está liberado no Workspace, e liberar depende do administrador | API REST comum do Chat com o refresh token do ambiente |
| MCP do Google Calendar na nuvem (`calendarmcp.googleapis.com`) | mesmo erro | o **banco** busca a agenda (`jarvis.calendario`), com a credencial do cofre |
| Falar com o Supabase por HTTP/curl/urllib dentro da rotina | `403 connect_rejected` — o proxy de saída do ambiente tem allowlist; `googleapis.com` passa, o host do Supabase não | conector MCP do Supabase, que sai por `mcp-proxy.anthropic.com` e não passa pelo proxy |
| Levar a credencial de Calendar para dentro da rotina | barrado **três vezes** — duas por classificador e uma pela própria rotina, que recusou executar e mandou notificação. As três recusas estavam certas | mover a **capacidade** para onde a credencial já mora: a função no banco |
| `*/15 * * * *` numa rotina da nuvem | `cron interval too short` — o mínimo é 1 hora | quatro rotinas horárias defasadas em 15 min |
| Postar o alerta com a credencial da própria pessoa | a marcação `<users/ID>` aparece na mensagem e **não notifica o celular** | webhook do espaço, que posta como outra identidade |
| Buscar mensagens novas varrendo os ~291 espaços | inviável em tempo e em chamadas | `GET /v1/spaces?pageSize=1000` traz `lastActiveTime`; filtrar pela janela derruba para menos de 10 |
| Ler o Chat sem a Chat API ativada no GCP | erro de permissão que parece trava de administrador | ativar a API (foi o caso em 31/08) |
| Cérebro rodando como tarefa local do Windows | janela de `cmd` piscando no meio do trabalho dele; ele exigiu execução remota em 01/09 | rotinas na nuvem; local só como caminho rápido, e escondido por `.vbs` |
| Tarefa do Windows criada sem `-AllowStartIfOnBatteries -WakeToRun` | fica registrada e **nunca roda** num notebook (3 semanas assim, numa rodada anterior) | os dois parâmetros, sempre |
| Deixar o espaço de alerta fora de `spaces_ignorar` | o agente lê os próprios alertas como conversa e entra em laço | incluir o próprio `space_alerta` na lista |
| Chamar o MCP de Chat sem `user_google_email` | responde como `conta-servico@suaempresa.com`, que **não vê os espaços pessoais** — lista curta, plausível, sem erro | passar o email dele em toda chamada |
| Tratar "lock tomado" como falha | o modelo insiste, força, e você ganha trabalho duplicado | abortar é o comportamento **correto**; está escrito no prompt de propósito |
| Chamar `fechar_run` quando a run deu errado | o watermark avança e a janela de mensagens é perdida para sempre | não fechar; só `soltar_lock`. Perder uma run é aceitável, perder mensagem não |

**O padrão mais reutilizável do projeto**, o único que vale copiar para outros agentes:
quando o agente precisa de uma credencial que ele não deve carregar, **mova a capacidade
para onde a credencial já mora**, em vez de mover a credencial para onde o agente está.

---

---

## 18. Pedidos pelo próprio espaço de alertas

Quem reconstrói isto do zero **precisa aplicar esta parte também** — sem ela o dono não
consegue pedir lembrete, e o cérebro volta a ser cego para o espaço de alertas.

### 18.1 As três migrações

Nomes no histórico do Supabase, nesta ordem:

1. `jarvis_pedidos_no_espaco_de_alertas` — tipo `lembrete` (+ ⏰ em `jarvis.rotulo`),
   colunas `repetir_min` / `repetir_ate` / `serie` em `jarvis.compromissos`, restrição
   `repetir_sensato` (`repetir_min >= 5`), índice parcial em `serie`, e as funções
   `jarvis.agendar_pedido`, `jarvis.encerrar_serie`, `jarvis.pedidos_ativos`.
2. `jarvis_entregar_rearma_lembrete_repetido` — `jarvis.entregar()` ganha, depois do laço
   de entrega, o passo que re-arma a próxima ocorrência do que repete.
3. `jarvis_rpc_libera_pedidos` — `public.jarvis_rpc` passa a despachar `agendar_pedido`,
   `encerrar_serie` e `pedidos_ativos`, e `catalogo_rotulos` passa a listar `lembrete`.

Numa reconstrução com o banco ainda vivo, o SQL exato sai de
`select pg_get_functiondef('jarvis.agendar_pedido(text,text,timestamptz,int,timestamptz,text,text,timestamptz,text,boolean)'::regprocedure);`
(e equivalentes). Num banco novo, reescreva a partir do contrato abaixo — ele é completo.

### 18.2 O contrato de `jarvis.agendar_pedido`

Argumentos, na ordem: `p_titulo`, `p_origem_texto`, `p_alerta_em` (null = agora),
`p_repetir_min` (null = uma vez só), `p_repetir_ate`, `p_mensagem_alerta`, `p_prioridade`,
`p_origem_msg_time`, `p_run_id`, `p_confirmar` (default `true`).

O que ela garante, e por que cada coisa está ali:

- **`serie` = `'pedido:' || substr(md5(texto_citado || hora_da_mensagem), 1, 6)`.** Se já
  existir qualquer linha com esse prefixo, devolve `inalterado` e não cria nada. É isso que
  segura o reprocessamento quando a run do cérebro morre antes de o watermark avançar.
  Os 6 caracteres são também a *handle* que ele digita para desligar.
- **Recusa `p_repetir_min < 5`** (a entrega roda de 5 em 5 min; abaixo disso é mentira) e
  **recusa pedido que geraria mais de 60 avisos**.
- **Sem `p_repetir_ate`, a série morre em 8 horas.** Cron sem fim vira ruído.
- **`p_origem_texto` vazio é exceção**, igual a `upsert_compromisso`: nem pedido dele entra
  sem a citação literal.
- **`fingerprint` = `serie || ':' || <hora UTC da ocorrência>`**, então as ocorrências da
  mesma série nunca colidem entre si nem com o que o cérebro cria por inferência.
- **Com `p_confirmar`**, insere também um `aviso` (`serie || ':ack'`, `alerta_em` = agora)
  com o título, a cadência e a linha "para desligar, mande aqui: jarvis para <handle>".
  O texto é montado **no banco** de propósito: confirmação é contrato, não redação.

### 18.3 O re-arme, dentro de `jarvis.entregar()`

Depois do laço de entrega, sobre os ids que **saíram com sucesso** (`v_ok_ids`):

```
prox = alerta_em_utc + repetir_min * (floor((now() - alerta_em_utc) / repetir_min) + 1)
```

- `prox <= repetir_ate` → insere a linha nova (`on conflict (fingerprint) do nothing`).
- `prox > repetir_ate` → insere um `aviso` (`serie || ':fim'`) dizendo que a janela pedida
  terminou e o lembrete parou ali.

O `floor(...) + 1` é o detalhe que importa: garante que `prox` é sempre **depois de agora**.
Se a entrega ficou horas fora do ar, ele pula o backlog inteiro em vez de despejar as
ocorrências vencidas de uma vez.

Três invariantes que esse desenho preserva:

- **um compromisso = uma entrega** — a próxima ocorrência é linha nova, com fingerprint
  novo; nada é "reaberto";
- **o zumbi cancelado continua morto** — `encerrar_serie` zera o `repetir_min` inclusive no
  que já foi entregue, então não sobra nada para re-armar;
- **o cérebro não cria ocorrência futura na mão** (o prompt proíbe): quem multiplica é a
  entrega, uma por vez.

### 18.4 O filtro do espaço de alertas (nos dois prompts)

Trocar a regra antiga ("pule `spaces/SEU_SPACE_ID`") pelo filtro de três condições, **todas
obrigatórias**: autor = `config.self_user_id`, primeira palavra ∈ {`jarvis`, `/lembra`,
`/cron`}, texto < 600 caracteres.

**Por que a condição do gatilho não é enfeite:** filtrar só por autor faria o cérebro ler
como pedido novo (a) os resumos das 7h anteriores a 03/09/2026, que foram postados **com a
conta do dono** e seguem no histórico, e (b) as notas que ele joga naquele espaço para
si mesmo ("Preciso de: acesso ao painel, Github (.env)"). Nos dois casos ele recriaria pendência
com outra redação — fingerprint diferente, alerta duplicado. O `jarvis` na frente é o que
separa ordem de eco. (Desde 03/09/2026 o Resumo 7h sai pelo webhook, como "Bot de
automações"; isso reduz o risco para as mensagens novas, não para o histórico.)

Só as mensagens que passam no filtro entram em `gravar_mensagens`; o resto do espaço não é
gravado.
