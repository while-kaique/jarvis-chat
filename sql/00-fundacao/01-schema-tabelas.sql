-- ============================================================
-- Jarvis Chat - fundacao 01: schema, tabelas, indices
-- ============================================================
-- Aplique os arquivos desta pasta em ordem numerica (01 a 10),
-- um por vez, no SQL Editor do Supabase.
--
-- Este arquivo e o estado ATUAL do schema (conferido contra o
-- banco em 30/09/2026). Nao precisa aplicar as migracoes
-- historicas: as secoes 3 a 5 do CONSTRUIR.md sao o passo a
-- passo comentado, estes arquivos sao o que voce roda.
--
-- Nenhum dado pessoal aqui. Os seus valores entram no seed
-- (08-seed.sql).
-- ============================================================

create schema if not exists jarvis;

-- pgcrypto: o token aleatorio de cada aviso (botao) e o sha256 da porta
create extension if not exists pgcrypto with schema extensions;

-- http: sobe aqui, e nao so no 05, porque o 02 (nome_pessoa) ja usa o tipo
-- extensions.http_response. Num banco novo, sem isto, o 02 quebra.
create extension if not exists http with schema extensions;

-- ---------- chave_espaco: o "balde" de um chat sem id confiavel ----------
-- Nasce aqui, e nao no 02, porque um indice de mensagens usa ela.
-- DM sem nome (ou "DM ...") cai toda no mesmo balde; grupo cai pelo
-- nome normalizado. E o que deixa o banco achar o id real de um chat
-- que chegou so com o nome (ver espaco_por_nome, no 03).
create or replace function jarvis.chave_espaco(p_space_id text, p_space_nome text)
 returns text language sql immutable
as $function$
  select case
           when coalesce(nullif(btrim(p_space_nome), ''), 'Unknown') = 'Unknown'
                or btrim(p_space_nome) ilike 'DM%'
           then 'dm:desconhecido'
           else 'nome:' || lower(regexp_replace(btrim(p_space_nome), '\s+', ' ', 'g'))
         end
$function$;

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
create index if not exists mensagens_chave_espaco_tempo
  on jarvis.mensagens (jarvis.chave_espaco(space_id, space_nome), create_time);

-- ---------- categorias: o catalogo de avisos (emoji, rotulo, botoes) ----------
-- Uma linha por subtipo. Mudar o botao ou o rotulo de uma categoria e
-- um `update`, nao um deploy. As linhas entram no 08-seed.sql, e TEM que
-- entrar antes do primeiro aviso: compromissos.subtipo e chave estrangeira.
create table if not exists jarvis.categorias (
  subtipo    text    primary key,
  tipo       text    not null,
  emoji      text    not null unique,
  nome       text    not null,
  exige_hora boolean not null default false,
  molde      text,
  ordem      integer not null default 99,
  rotulo     text,
  botoes     jsonb   not null default '[]'
);

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
  subtipo           text,
  urgencia_motivo   text,
  -- token do botao: e o que o link/acao do card carrega, nunca o id
  token             text        default encode(extensions.gen_random_bytes(9), 'hex'),
  -- conversa do Chat onde o aviso saiu (so quando posta pelo app)
  chat_thread       text,
  -- emojis dele ja perguntados ("reagiu, mas resolveu?"): nao pergunta 2x
  reacao_vista      text[],
  constraint compromissos_tipo_check check (tipo = any (array[
    'reuniao','prazo','promessa','pergunta_aberta','mencao','conflito','aviso','lembrete'])),
  constraint compromissos_status_check check (status = any (array[
    'pendente','disparado','cancelado','cumprido','expirado'])),
  constraint compromissos_prioridade_check check (prioridade = any (array['alta','normal'])),
  constraint origem_nao_vazia check (length(btrim(origem_texto)) > 0),
  constraint repetir_sensato  check (repetir_min is null or repetir_min >= 5),
  constraint compromissos_subtipo_fk foreign key (subtipo) references jarvis.categorias(subtipo)
);
create index if not exists compromissos_pendentes_idx on jarvis.compromissos (alerta_em_utc) where status = 'pendente';
create index if not exists compromissos_status_idx    on jarvis.compromissos (status, atualizado_em desc);
create index if not exists compromissos_serie_idx     on jarvis.compromissos (serie) where serie is not null;
create index if not exists compromissos_chat_thread   on jarvis.compromissos (chat_thread) where chat_thread is not null;
create unique index if not exists compromissos_cal_idx   on jarvis.compromissos (calendar_event_id) where calendar_event_id is not null;
create unique index if not exists compromissos_token_idx on jarvis.compromissos (token);

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

-- ---------- defeitos: o que o banco consertou (ou recusou) sozinho ----------
-- O trigger guarda_compromisso e o gravar_mensagens anotam aqui cada
-- vez que tapam um buraco do cerebro (aviso sem data, pergunta sem id
-- do chat...). A auditoria diaria (05) le esta tabela e avisa se um
-- mesmo defeito comecar a se repetir.
create table if not exists jarvis.defeitos (
  id        bigserial primary key,
  ts        timestamptz not null default now(),
  onde      text not null,
  regra     text not null,
  gravidade text not null,
  detalhe   jsonb,
  run_id    text,
  constraint defeitos_gravidade_check check (gravidade = any (array['recusado','consertado','suspeito']))
);
create index if not exists defeitos_ts    on jarvis.defeitos (ts desc);
create index if not exists defeitos_regra on jarvis.defeitos (regra, ts desc);

-- ---------- dm_mapa: id real de cada DM -> com quem e ----------
-- A varredura do Chat as vezes so traz o nome da DM. Sem o id, a
-- resposta dele numa DM nao casava com a pergunta daquela DM.
create table if not exists jarvis.dm_mapa (
  space_id    text primary key,
  pessoa_nome text,
  pessoa_id   text,
  visto_em    timestamptz not null default now(),
  tentativas  integer not null default 0
);

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

-- ---------- prompt_historico: a versao anterior de cada prompt ----------
-- `jarvis.prompt` tem UMA linha por nome e o jarvis_rpc('prompt') le sem
-- filtrar versao: versionar e sobrescrever. Antes de sobrescrever, copie
-- a linha velha para ca.
create table if not exists jarvis.prompt_historico (
  nome      text        not null,
  versao    integer     not null,
  corpo     text        not null,
  arquivado timestamptz not null default now(),
  primary key (nome, versao, arquivado)
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

-- ---------- chat_app_log: cada clique e cada post do app do Chat ----------
-- Gravada pelas Edge Functions do app (via public.jarvis_chat_log, no 10).
-- Guarda 14 dias. Leitura rapida: select * from jarvis.chat_app_cliques limit 5;
create table if not exists jarvis.chat_app_log (
  id      bigserial primary key,
  em      timestamptz not null default now(),
  req     text,
  etapa   text not null,
  ok      boolean,
  detalhe jsonb
);
create index if not exists chat_app_log_em on jarvis.chat_app_log (em desc);

-- um clique por linha, etapas em ordem (chegou -> token -> evento -> banco -> respondeu)
create or replace view jarvis.chat_app_cliques as
 select req,
        min(em) as em,
        bool_and(coalesce(ok, true)) as tudo_ok,
        jsonb_agg(jsonb_build_object('etapa', etapa, 'ok', ok, 'detalhe', detalhe) order by id) as etapas
   from jarvis.chat_app_log
  group by req
  order by (min(em)) desc;

-- ---------- resumo_itens: itens clicaveis de um resumo diario (opcional) ----------
-- Quem ESCREVE aqui e uma rotina de resumo matinal que nao vem neste
-- repo. A tabela fica porque `resolver_item` (10) declara uma variavel
-- do tipo dela: sem a tabela, o botao de qualquer aviso quebra.
create table if not exists jarvis.resumo_itens (
  id             bigserial primary key,
  token          text not null unique,
  origem         text not null default 'resumo7h',
  data_resumo    date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  n              text,
  secao          text,
  titulo         text not null,
  chave          text not null,
  de             text,
  onde           text,
  urgencia       text,
  pendente_desde text,
  status         text not null default 'aberto',
  resolvido_em   timestamptz,
  desfeito_em    timestamptz,
  criado_em      timestamptz not null default now(),
  constraint resumo_itens_status_check check (status = any (array['aberto','resolvido']))
);
create index if not exists resumo_itens_chave_idx  on jarvis.resumo_itens (chave);
create index if not exists resumo_itens_data_idx   on jarvis.resumo_itens (data_resumo desc);
create index if not exists resumo_itens_status_idx on jarvis.resumo_itens (status) where status = 'resolvido';

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
