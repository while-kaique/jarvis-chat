-- ============================================================
-- Jarvis Chat - fundacao 02: utilitarios, lock, turno, poda,
--                            e as guardas que rodam em toda escrita
-- ============================================================
-- Depende de: 01-schema-tabelas.sql
--
-- `slug` e `fingerprint` sao IMMUTABLE de proposito: o
-- fingerprint arredonda o horario em janelas de 5 min, e e ele
-- que faz a deduplicacao (unique em compromissos.fingerprint).
-- Mexer na formula depois de ter dados em producao muda o
-- fingerprint de tudo e reabre alertas ja fechados.
--
-- `nome_pessoa` chama a rede (People API) e depende de
-- jarvis.token_google(), do 05-entrega.sql. Sem a credencial do
-- Google ela so devolve o que ja esta em estado.pessoas.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- slug: texto -> chave sem acento ----------
create or replace function jarvis.slug(p_txt text)
 returns text language sql immutable
as $function$
  select regexp_replace(
           regexp_replace(
             lower(translate(coalesce(p_txt, ''),
               'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
               'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')),
             '[^a-z0-9]+', '-', 'g'),
           '^-+|-+$', '', 'g')
$function$;

-- ---------- fingerprint: a chave de deduplicacao ----------
create or replace function jarvis.fingerprint(p_tipo text, p_titulo text, p_quando timestamptz)
 returns text language sql immutable
as $function$
  select p_tipo || ':' || left(jarvis.slug(p_titulo), 60) || ':' ||
         coalesce(
           to_char(to_timestamp(round(extract(epoch from p_quando) / 300) * 300)
                     at time zone 'UTC', 'YYYYMMDD"T"HH24MI'),
           'semdata')
$function$;

-- ---------- data_br / hora_br / contagem: texto humano ----------
-- "14h", "9h30", "0h" -- e o formato que ele le no aviso. Viver no banco
-- (e nao no prompt) e o que deixa todo aviso sair igual.
create or replace function jarvis.data_br(p timestamptz)
 returns text language sql immutable
as $function$
  select case when p is null then null
              else to_char(p at time zone 'America/Sao_Paulo', 'DD/MM') end
$function$;

create or replace function jarvis.hora_br(p timestamptz)
 returns text language sql immutable
as $function$
  select case
    when p is null then null
    else (case when to_char(p at time zone 'America/Sao_Paulo','HH24') = '00'
               then '0'
               else ltrim(to_char(p at time zone 'America/Sao_Paulo','HH24'), '0') end)
         || 'h'
         || (case when to_char(p at time zone 'America/Sao_Paulo','MI') = '00'
                  then ''
                  else to_char(p at time zone 'America/Sao_Paulo','MI') end)
  end
$function$;

create or replace function jarvis.contagem(p_n integer, p_singular text, p_plural text)
 returns text language sql immutable
as $function$
  select p_n || ' ' || case when p_n = 1 then p_singular else p_plural end
$function$;

-- ---------- emoji_*: ler a reacao dele numa mensagem ----------
-- Reacao com emoji "claro" (joinha, check...) conta como resposta.
-- Qualquer outro emoji vira pergunta "reagiu, mas resolveu?".
-- emoji_base tira o seletor de variacao (U+FE0F) e o tom de pele.
create or replace function jarvis.emoji_base(p text)
 returns text language sql immutable
as $function$
  select regexp_replace(coalesce(p, ''), '[️\U0001F3FB-\U0001F3FF]', '', 'g')
$function$;

create or replace function jarvis.emoji_claro(p text)
 returns boolean language sql immutable
as $function$
  select jarvis.emoji_base(p) = any (array['✅','☑','✔','👌','🫡','👍','🆗','🤝','💯'])
$function$;

create or replace function jarvis.emoji_sentido(p text)
 returns text language sql immutable
as $function$
  select case
    when b in ('👀') then 'vi, ainda vou olhar'
    when b in ('😂','🤣','😆','😅','😹','😁','😄') then 'risada'
    when b in ('❤','♥','😍','🥰','💙','💜','🧡','💚','🩷') then 'curtida'
    when b in ('🙏') then 'obrigado ou por favor'
    when b in ('🔥','🚀','🎉','🥳','👏','💪') then 'animação'
    when b in ('😮','😱','😯','🤯') then 'surpresa'
    when b in ('🤔','🧐') then 'dúvida'
    when b in ('😢','😭','😞','🥲') then 'tristeza'
    when b in ('✍') then 'anotando'
    when b in ('👎') then 'discordância'
    else null end
  from (select jarvis.emoji_base(p) b) x
$function$;

-- ---------- anotar_defeito: o banco registra o que consertou ----------
create or replace function jarvis.anotar_defeito(p_onde text, p_regra text, p_gravidade text,
                                                 p_detalhe jsonb default '{}'::jsonb,
                                                 p_run_id text default null)
 returns void language sql
as $function$
  insert into jarvis.defeitos (onde, regra, gravidade, detalhe, run_id)
  values (p_onde, p_regra, p_gravidade, coalesce(p_detalhe,'{}'::jsonb), p_run_id);
$function$;

-- ---------- checar_alerta_vago: "a outra pessoa ja confirmou" nao entra ----------
-- Aviso que obriga ele a investigar QUEM falou nao serve. O banco recusa,
-- e o erro ja diz ao cerebro como consertar (nome, ou o id cru).
create or replace function jarvis.checar_alerta_vago(p_msg text, p_onde text)
 returns void language plpgsql immutable
as $function$
begin
  if coalesce(p_msg, '') ~* '(a outra pessoa|as outras pessoas|essa pessoa|uma pessoa|a pessoa (ja|já|disse|confirmou|pediu)|com alguem|com alguém|alguem (ja|já)|alguém (ja|já))' then
    raise exception
      '% : alerta vago -- diga o NOME de quem falou e o ASSUNTO. Se o nome nao esta no mapa estado.pessoas, escreva o id cru (users/123...) no lugar do nome: o banco troca pelo nome real do diretorio do Google. Texto barrado: "%"',
      p_onde, left(p_msg, 200);
  end if;
end $function$;

-- ---------- nome_pessoa: users/ID -> nome real ----------
-- Primeiro o mapa estado.pessoas; se faltar, a People API (o id do Chat
-- e o id da pessoa no diretorio) com a mesma credencial do Calendar, e
-- grava no mapa. Qualquer falha devolve null: nome nunca derruba aviso.
create or replace function jarvis.nome_pessoa(p_id text)
 returns text language plpgsql security definer
 set search_path to 'public','extensions'
as $function$
declare v_id text; v_nome text; v_resp extensions.http_response;
begin
  v_id := substring(coalesce(p_id,'') from '(\d{10,})');
  if v_id is null then return null; end if;

  select valor->>('users/' || v_id) into v_nome from jarvis.estado where chave = 'pessoas';
  if coalesce(v_nome,'') <> '' and v_nome !~ 'users/|^\d+$' then return v_nome; end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '8');
    select * into v_resp from extensions.http((
      'GET', 'https://people.googleapis.com/v1/people/' || v_id || '?personFields=names',
      array[extensions.http_header('Authorization', 'Bearer ' || jarvis.token_google())],
      null, null)::extensions.http_request);
    if v_resp.status = 200 then
      v_nome := nullif(btrim((v_resp.content::jsonb)->'names'->0->>'displayName'), '');
    else
      v_nome := null;
    end if;
  exception when others then
    v_nome := null;
  end;

  if v_nome is not null then
    update jarvis.estado
       set valor = valor || jsonb_build_object('users/' || v_id, v_nome)
     where chave = 'pessoas';
  end if;
  return v_nome;
end $function$;

-- ---------- corrigir_nomes: troca todo users/ID do texto pelo nome ----------
-- Preserva a marcacao <users/ID> (e ela que faz o celular vibrar).
create or replace function jarvis.corrigir_nomes(p_texto text)
 returns text language plpgsql
as $function$
declare v_out text := p_texto; v_id text; v_nome text;
begin
  if p_texto is null or p_texto !~ 'users/\d{10,}' then return p_texto; end if;
  for v_id in select distinct m[1] from regexp_matches(p_texto, 'users/(\d{10,})', 'g') as m loop
    v_nome := jarvis.nome_pessoa(v_id);
    if v_nome is null then continue; end if;
    v_out := regexp_replace(v_out,
      '(alguém|alguem|pessoa não identificada|pessoa nao identificada)\s*\(\s*users/' || v_id || '\s*\)',
      v_nome, 'gi');
    v_out := regexp_replace(v_out, '<users/' || v_id || '>', '<<' || v_id || '>>', 'g');  -- protege marcacao
    v_out := regexp_replace(v_out, 'users/' || v_id, v_nome, 'g');
    v_out := replace(v_out, '<<' || v_id || '>>', '<users/' || v_id || '>');
  end loop;
  return v_out;
end $function$;

-- ---------- normalizar_alerta: \n literal virou quebra de linha ----------
-- O modelo escreve "\n" dentro do JSON e as vezes ele chega escapado
-- duas vezes. Corrigir na escrita e mais barato do que confiar no prompt.
create or replace function jarvis.normalizar_alerta()
 returns trigger language plpgsql
as $function$
begin
  if new.mensagem_alerta is not null then
    new.mensagem_alerta := replace(replace(new.mensagem_alerta, '\\n', chr(10)), '\n', chr(10));
  end if;
  return new;
end
$function$;

-- ---------- tg_corrigir_nomes: o nome real, em todo aviso gravado ----------
create or replace function jarvis.tg_corrigir_nomes()
 returns trigger language plpgsql
as $function$
begin
  begin
    new.titulo            := jarvis.corrigir_nomes(new.titulo);
    new.descricao         := jarvis.corrigir_nomes(new.descricao);
    new.space_origem_nome := jarvis.corrigir_nomes(new.space_origem_nome);
    new.mensagem_alerta   := jarvis.corrigir_nomes(new.mensagem_alerta);
    new.origem_autor      := jarvis.corrigir_nomes(new.origem_autor);
  exception when others then
    null;  -- nome nunca impede o aviso de ser gravado
  end;
  return new;
end $function$;

-- ---------- guarda_compromisso: o que o banco conserta sozinho ----------
-- Cada regra aqui nasceu de um aviso errado que chegou de verdade.
-- Conserta em vez de recusar (o aviso chegar importa mais), e anota
-- em jarvis.defeitos para a auditoria diaria ver se esta repetindo.
create or replace function jarvis.guarda_compromisso()
 returns trigger language plpgsql
as $function$
declare
  v_limpo text;
begin
  -- 1) subtipo sempre preenchido
  if new.subtipo is null then
    new.subtipo := case new.tipo when 'aviso' then 'outro'
                                when 'pergunta_aberta' then 'pergunta'
                                else new.tipo end;
    if not exists (select 1 from jarvis.categorias where subtipo = new.subtipo) then
      new.subtipo := 'outro';
    end if;
    perform jarvis.anotar_defeito('compromissos', 'alerta sem subtipo', 'consertado',
      jsonb_build_object('tipo', new.tipo, 'titulo', new.titulo, 'assumido', new.subtipo));
  end if;

  -- 2) data sempre gravada
  if new.quando_utc is null then
    new.quando_utc := coalesce(new.origem_msg_time, new.alerta_em_utc);
    perform jarvis.anotar_defeito('compromissos', 'alerta sem data', 'consertado',
      jsonb_build_object('tipo', new.tipo, 'titulo', new.titulo,
                         'assumido', new.quando_utc, 'de_onde', 'origem_msg_time ou alerta_em'));
  end if;

  -- 3) pergunta sem o id do chat nao pode INSISTIR: ela avisa uma vez e para.
  --    Sem o id nao da pra saber que ele respondeu -- foi o caso Rafael,
  --    18/09/2026, quatro cobrancas de algo ja respondido as 10h58.
  if new.tipo = 'pergunta_aberta'
     and coalesce(new.space_origem, '') not like 'spaces/%'
     and new.repetir_min is not null then
    perform jarvis.anotar_defeito('compromissos', 'pergunta sem id de chat', 'consertado',
      jsonb_build_object('titulo', new.titulo, 'chat', new.space_origem_nome,
                         'autor', new.origem_autor,
                         'efeito', 'avisa uma vez e nao repete: sem id nao da pra ver a resposta dele'));
    new.repetir_min := null;
  end if;

  -- 4) nome de gente no lugar de id cru
  if new.origem_autor like 'users/%' then
    perform jarvis.anotar_defeito('compromissos', 'autor como id cru', 'suspeito',
      jsonb_build_object('titulo', new.titulo, 'autor', new.origem_autor));
  end if;

  -- 5) aviso de reuniao nao cita choque. O texto e escrito dias antes e o choque
  --    pode ser resolvido no meio -- foi Diretoria x Marina, 23/09/2026. Choque
  --    e do tipo `conflito`, que o banco cancela quando a agenda muda.
  if new.tipo = 'reuniao' and new.mensagem_alerta
       ~* '(choque|conflit|mesmo hor[aá]rio|bate com|sobrep|se batendo|hora de decidir)' then
    select string_agg(l, chr(10) order by n) into v_limpo
      from regexp_split_to_table(new.mensagem_alerta, '\n') with ordinality as t(l, n)
     where l !~* '(choque|conflit|mesmo hor[aá]rio|bate com|sobrep|se batendo|hora de decidir)';
    perform jarvis.anotar_defeito('compromissos', 'reuniao citando choque', 'consertado',
      jsonb_build_object('titulo', new.titulo, 'antes', new.mensagem_alerta, 'depois', v_limpo));
    new.mensagem_alerta := nullif(btrim(coalesce(v_limpo, '')), '');
  end if;

  -- 6) pergunta em que ele reagiu com emoji ambiguo (25/09/2026): pergunta UMA vez
  --    "continuo te alertando?". So volta a insistir se ele clicar "Continua me avisando".
  if new.subtipo = 'pergunta_reagida' then
    new.repetir_min := null;
  end if;

  return new;
end $function$;

-- Os tres triggers BEFORE rodam em ordem alfabetica do nome:
-- corrigir_nomes -> guarda_compromisso -> trg_normalizar_alerta.
drop trigger if exists corrigir_nomes on jarvis.compromissos;
create trigger corrigir_nomes
  before insert or update of titulo, descricao, space_origem_nome, mensagem_alerta, origem_autor
  on jarvis.compromissos
  for each row execute function jarvis.tg_corrigir_nomes();

drop trigger if exists guarda_compromisso on jarvis.compromissos;
create trigger guarda_compromisso
  before insert or update on jarvis.compromissos
  for each row execute function jarvis.guarda_compromisso();

drop trigger if exists trg_normalizar_alerta on jarvis.compromissos;
create trigger trg_normalizar_alerta
  before insert or update of mensagem_alerta on jarvis.compromissos
  for each row execute function jarvis.normalizar_alerta();

-- ---------- lock: quem chega primeiro roda, o outro aborta em paz ----------
-- Grava tambem `inicio_utc`: e ele que o fechar_run usa para nunca
-- avancar o watermark alem do comeco da propria run (28/09/2026).
create or replace function jarvis.tentar_lock(p_run_id text, p_minutos integer default 12)
 returns jsonb language plpgsql
as $function$
declare v_lock jsonb;
begin
  select valor into v_lock from jarvis.estado where chave = 'lock' for update;
  if v_lock ? 'expira_utc' and (v_lock->>'expira_utc') is not null
     and (v_lock->>'expira_utc')::timestamptz > now() then
    return jsonb_build_object('ok', false, 'dono', v_lock->>'run_id', 'expira', v_lock->>'expira_utc');
  end if;
  update jarvis.estado
     set valor = jsonb_build_object('run_id', p_run_id,
                                    'inicio_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'expira_utc', to_char(now() + make_interval(mins => p_minutos), 'YYYY-MM-DD"T"HH24:MI:SSOF')),
         atualizado_em = now()
   where chave = 'lock';
  return jsonb_build_object('ok', true, 'run_id', p_run_id);
end $function$;

create or replace function jarvis.soltar_lock(p_run_id text)
 returns jsonb language plpgsql
as $function$
begin
  update jarvis.estado
     set valor = '{"run_id": null, "expira_utc": null}'::jsonb, atualizado_em = now()
   where chave = 'lock' and (valor->>'run_id' = p_run_id or valor->>'run_id' is null);
  return jsonb_build_object('ok', true);
end $function$;

-- ---------- turno: a jornada de hoje, ancorada na sua 1a mensagem ----------
create or replace function jarvis.definir_turno(p_ref timestamptz default now())
 returns jsonb language plpgsql
as $function$
declare
  v_dia    date;
  v_inicio timestamptz;
  v_cfg    jsonb;
  v_dur    numeric;
  v_marg   numeric;
  v_fim    timestamptz;
  v_out    jsonb;
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
                                'nota', 'voce ainda nao falou nada hoje; sem ancora de turno');
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
end $function$;

-- ---------- fechar_run: watermark + heartbeat + solta o lock ----------
-- 28/09/2026: uma run leu o Chat as 20h25, fechou as 20h34 e passou a
-- hora do FIM como watermark. Tudo que chegou nesses 9 min sumiu -- inclusive
-- a resposta dele a uma pergunta, que o Jarvis ficou cobrando por dias.
-- Agora o watermark nunca passa do `inicio_utc` gravado pelo tentar_lock.
create or replace function jarvis.fechar_run(p_run_id text, p_ate timestamptz, p_resultado jsonb)
 returns jsonb language plpgsql
as $function$
declare v_lock jsonb; v_inicio timestamptz; v_ate timestamptz;
begin
  -- o watermark nunca passa da hora em que ESTA run comecou: mensagem que chegou
  -- durante a run nao foi lida por ela e tem que ficar para a proxima.
  select valor into v_lock from jarvis.estado where chave = 'lock';
  if v_lock->>'run_id' = p_run_id and (v_lock->>'inicio_utc') is not null then
    v_inicio := (v_lock->>'inicio_utc')::timestamptz;
  end if;
  v_ate := least(coalesce(p_ate, now()), coalesce(v_inicio, p_ate, now()));

  update jarvis.estado
     set valor = jsonb_build_object('ultimo_ok_iso', to_char(v_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'run_id', p_run_id),
         atualizado_em = now()
   where chave = 'watermark';

  update jarvis.estado
     set valor = jsonb_build_object('ultima_run_utc', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                                    'run_id', p_run_id, 'resultado', p_resultado),
         atualizado_em = now()
   where chave = 'heartbeat';

  if p_resultado ? 'visto' then
    update jarvis.estado
       set valor = coalesce(valor, '{}'::jsonb) || (p_resultado->'visto'),
           atualizado_em = now()
     where chave = 'visto';
  end if;

  perform jarvis.soltar_lock(p_run_id);
  return jsonb_build_object('ok', true,
                            'watermark', to_char(v_ate, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
                            'watermark_limitado_ao_inicio', v_ate < p_ate,
                            'visto_gravado', p_resultado ? 'visto');
end $function$;

-- ---------- podar: expira reuniao velha, apaga mensagem antiga ----------
create or replace function jarvis.podar(p_run_id text default null)
 returns jsonb language plpgsql
as $function$
declare v_msgs int; v_evt int; v_exp int; v_tol int;
begin
  select coalesce((valor->>'tolerancia_atraso_min')::int, 90) into v_tol
    from jarvis.estado where chave = 'config';

  with venc as (
    update jarvis.compromissos
       set status = 'expirado', atualizado_em = now(),
           cancelado_motivo = 'reuniao ja tinha comecado ha ' || v_tol || '+ min quando daria para avisar'
     where status = 'pendente'
       and tipo = 'reuniao'
       and alerta_em_utc < now() - make_interval(mins => v_tol)
    returning id
  )
  insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
  select id, 'expirou', 'passou ' || v_tol || ' min da hora e e reuniao', p_run_id from venc;
  get diagnostics v_exp = row_count;

  delete from jarvis.mensagens where create_time < now() - interval '7 days';
  get diagnostics v_msgs = row_count;

  delete from jarvis.eventos where ts < now() - interval '180 days';
  get diagnostics v_evt = row_count;

  return jsonb_build_object('mensagens_apagadas', v_msgs, 'eventos_apagados', v_evt,
                            'compromissos_expirados', v_exp);
end $function$;

-- ---------- custo_estimado: tokens -> USD, pela tabela de preco ----------
create or replace function jarvis.custo_estimado(p_modelo text, p_in bigint, p_out bigint,
                                                 p_cache_write bigint, p_cache_read bigint)
 returns numeric language sql stable
as $function$
  select round((
      coalesce(p_in,0)          * p.usd_in          +
      coalesce(p_out,0)         * p.usd_out         +
      coalesce(p_cache_write,0) * p.usd_cache_write +
      coalesce(p_cache_read,0)  * p.usd_cache_read
    ) / 1000000.0, 6)
    from jarvis.preco_modelo p
   where p.modelo = p_modelo
      or p_modelo like p.modelo || '%'
   order by (p.modelo = p_modelo) desc, length(p.modelo) desc
   limit 1;
$function$;

-- ---------- definir_credencial: guarda o hash do token da porta ----------
-- O token em claro nunca fica no banco. Voce gera um aleatorio,
-- chama isto uma vez, e guarda o token no segredo da rotina.
create or replace function jarvis.definir_credencial(p_nome text, p_token text)
 returns text language plpgsql security definer set search_path to 'public','extensions'
as $function$
begin
  if length(coalesce(p_token,'')) < 32 then
    raise exception 'token curto demais; use ao menos 32 caracteres aleatorios';
  end if;
  insert into jarvis.credencial (nome, token_hash)
  values (p_nome, encode(extensions.digest(p_token, 'sha256'), 'hex'))
  on conflict (nome) do update
     set token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex'),
         criado_em = now(), usos = 0, ultimo_uso = null;
  return p_nome;
end $function$;
