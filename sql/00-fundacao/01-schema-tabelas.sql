-- ============================================================
-- Jarvis Chat - fundacao 01: schema, tabelas, indices
-- ============================================================
-- Aplique os arquivos desta pasta em ordem numerica (01 a 08),
-- um por vez, no SQL Editor do Supabase.
--
-- Este arquivo e o estado ATUAL do schema, ja com tudo que as
-- migracoes 1 a 17 fizeram. Nao precisa aplicar as migracoes
-- historicas: as secoes 3 a 5 do CONSTRUIR.md sao o passo a
-- passo comentado, estes arquivos sao o que voce roda.
--
-- Nenhum dado pessoal aqui. Os seus valores entram no seed
-- (07-seed.sql).
-- ============================================================

create schema if not exists jarvis;

-- ---------- mensagens: o que foi lido do Chat ----------
create table if not exists jarvis.mensagens (
  id            bigserial primary key,
  space_id      text        not null default 'desconhecido',
  space_nome    text,
  autor_id      text        not null default 'desconhecido',
  autor_nome    text,
  texto         text        not null,
  create_time   timestamptz not null,
  is_dono       boolean     not null default false,
  cortado       boolean     not null default false,
  coletado_em   timestamptz not null default now(),
  tsv           tsvector generated always as
                  (to_tsvector('portuguese', coalesce(texto,''))) stored,
  constraint mensagens_unicas unique (space_id, autor_id, create_time)
);
create index if not exists mensagens_create_time_idx on jarvis.mensagens (create_time desc);
create index if not exists mensagens_dono_idx        on jarvis.mensagens (create_time) where is_dono;
create index if not exists mensagens_tsv_idx         on jarvis.mensagens using gin (tsv);

-- ---------- compromissos: a fila de alertas ----------
create table if not exists jarvis.compromissos (
  id                bigserial primary key,
  tipo              text        not null,
  titulo            text        not null,
  descricao         text,
  quando_utc        timestamptz,
  alerta_em_utc     timestamptz not null,
  space_origem      text,
  space_origem_nome text,
  status            text        not null default 'pendente',
  fingerprint       text        not null unique,
  origem_texto      text        not null,
  origem_msg_time   timestamptz,
  origem_autor      text,
  calendar_event_id text,
  cancelado_motivo  text,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  disparado_em      timestamptz,
  mensagem_alerta   text,
  prioridade        text        not null default 'normal',
  repetir_min       integer,
  repetir_ate       timestamptz,
  serie             text,
  constraint compromissos_tipo_check check (tipo = any (array[
    'reuniao','prazo','promessa','pergunta_aberta','mencao','conflito','aviso','lembrete'])),
  constraint compromissos_status_check check (status = any (array[
    'pendente','disparado','cancelado','cumprido','expirado'])),
  constraint compromissos_prioridade_check check (prioridade = any (array['alta','normal'])),
  constraint origem_nao_vazia check (length(btrim(origem_texto)) > 0),
  constraint repetir_sensato  check (repetir_min is null or repetir_min >= 5)
);
create index if not exists compromissos_pendentes_idx on jarvis.compromissos (alerta_em_utc) where status = 'pendente';
create index if not exists compromissos_status_idx    on jarvis.compromissos (status, atualizado_em desc);
create index if not exists compromissos_serie_idx     on jarvis.compromissos (serie) where serie is not null;
create unique index if not exists compromissos_cal_idx on jarvis.compromissos (calendar_event_id) where calendar_event_id is not null;

-- ---------- assuntos: a memoria de longo prazo ----------
create table if not exists jarvis.assuntos (
  id            bigserial primary key,
  chave         text        not null unique,
  titulo        text        not null,
  resumo        text        not null,
  pessoas       text[]      not null default '{}',
  spaces        text[]      not null default '{}',
  primeira_vez  timestamptz not null default now(),
  ultima_vez    timestamptz not null default now(),
  mencoes       integer     not null default 1,
  aberto        boolean     not null default true,
  atualizado_em timestamptz not null default now(),
  tsv           tsvector generated always as (to_tsvector('portuguese',
                  coalesce(titulo,'') || ' ' || coalesce(resumo,'') || ' ' ||
                  replace(coalesce(chave,''),'-',' '))) stored,
  constraint resumo_com_teto check (length(resumo) <= 1200)
);
create index if not exists assuntos_abertos_idx    on jarvis.assuntos (ultima_vez desc) where aberto;
create index if not exists assuntos_ultima_vez_idx on jarvis.assuntos (ultima_vez desc);
create index if not exists assuntos_tsv_idx        on jarvis.assuntos using gin (tsv);

-- ---------- eventos: auditoria de toda escrita ----------
create table if not exists jarvis.eventos (
  id             bigserial primary key,
  ts             timestamptz not null default now(),
  compromisso_id bigint references jarvis.compromissos(id) on delete set null,
  acao           text        not null,
  motivo         text,
  antes          jsonb,
  depois         jsonb,
  run_id         text,
  constraint eventos_acao_check check (acao = any (array[
    'criou','atualizou','cancelou','disparou','cumpriu','expirou','ignorou','erro']))
);
create index if not exists eventos_ts_idx          on jarvis.eventos (ts desc);
create index if not exists eventos_compromisso_idx on jarvis.eventos (compromisso_id);

-- ---------- estado: watermark, turno, lock, config, ruido, pessoas ----------
create table if not exists jarvis.estado (
  chave         text primary key,
  valor         jsonb not null,
  atualizado_em timestamptz not null default now()
);

-- ---------- prompt: as instrucoes do cerebro na nuvem ----------
create table if not exists jarvis.prompt (
  nome       text primary key,
  versao     integer not null default 1,
  corpo      text    not null,
  atualizado timestamptz not null default now()
);

-- ---------- credencial: a porta de capacidade (token hasheado) ----------
create table if not exists jarvis.credencial (
  nome       text primary key,
  token_hash text not null,
  criado_em  timestamptz not null default now(),
  ultimo_uso timestamptz,
  usos       bigint not null default 0
);

-- ---------- acoes_calendar: auditoria das escritas no Calendar ----------
create table if not exists jarvis.acoes_calendar (
  id          bigserial primary key,
  verbo       text    not null,
  event_id    text,
  pedido      jsonb,
  antes       jsonb,
  depois      jsonb,
  http_status integer,
  ok          boolean not null default false,
  erro        text,
  run_id      text,
  criado_em   timestamptz not null default now()
);

-- ---------- consumo + preco_modelo: quanto cada run gastou ----------
create table if not exists jarvis.consumo (
  id           bigserial primary key,
  rotina       text not null,
  session_id   text not null default '',
  modelo       text,
  inicio       timestamptz,
  fim          timestamptz not null default now(),
  duracao_s    integer,
  turnos       integer,
  tokens_in    bigint not null default 0,
  tokens_out   bigint not null default 0,
  cache_write  bigint not null default 0,
  cache_read   bigint not null default 0,
  tokens_total bigint generated always as
                 (tokens_in + tokens_out + cache_write + cache_read) stored,
  custo_usd    numeric(12,6),
  detalhe      jsonb not null default '{}',
  criado_em    timestamptz not null default now(),
  constraint consumo_unico unique (rotina, session_id)
);
create index if not exists consumo_fim        on jarvis.consumo (fim desc);
create index if not exists consumo_rotina_fim on jarvis.consumo (rotina, fim desc);

create table if not exists jarvis.preco_modelo (
  modelo          text primary key,
  usd_in          numeric(10,4) not null,
  usd_out         numeric(10,4) not null,
  usd_cache_write numeric(10,4) not null,
  usd_cache_read  numeric(10,4) not null,
  fonte           text,
  atualizado_em   timestamptz not null default now()
);

-- ---------- diario: o resumo por sessao de trabalho (opcional) ----------
create table if not exists jarvis.diario (
  id            bigserial primary key,
  sessao        text not null,
  maquina       text not null default 'minha-maquina',
  projeto       text,
  dia           date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  inicio        timestamptz,
  fim           timestamptz,
  titulo        text,
  resumo        text not null,
  entregue      jsonb not null default '[]',
  parcial       jsonb not null default '[]',
  travado       jsonb not null default '[]',
  descartado    jsonb not null default '[]',
  avisar        jsonb not null default '[]',
  arquivos      jsonb not null default '[]',
  commits       jsonb not null default '[]',
  chaves        jsonb not null default '[]',
  fonte         text not null default 'lote',
  gerado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint diario_sessao_maquina unique (sessao, maquina)
);
create index if not exists diario_dia_idx on jarvis.diario (dia desc);
create index if not exists diario_fim_idx on jarvis.diario (fim desc);

-- ---------- fecha a porta: nada de anon/authenticated no jarvis ----------
revoke all on schema jarvis from anon, authenticated;
revoke all on all tables    in schema jarvis from anon, authenticated;
revoke all on all functions in schema jarvis from anon, authenticated;
