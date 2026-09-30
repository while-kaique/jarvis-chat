-- ============================================================
-- Jarvis Chat - fundacao 03: as funcoes de escrita (invariantes)
-- ============================================================
-- Depende de: 01, 02
--
-- NUNCA escreva insert/update na mao nas tabelas do jarvis.
-- Toda escrita passa por aqui, e e isto que garante:
--   * citacao de origem obrigatoria (anti-alucinacao)
--   * deduplicacao por fingerprint
--   * uma pergunta = uma serie de cobranca, em qualquer status
--   * motivo obrigatorio para cancelar
--   * auditoria em jarvis.eventos
--
-- Algumas funcoes daqui chamam funcoes que so nascem depois
-- (`jarvis.rotulo` e `jarvis.reacoes_nos_pendentes` no 05,
-- `jarvis.dm_espaco` no 04). Isso e proposital e nao quebra nada:
-- plpgsql resolve a chamada em tempo de execucao.
-- ============================================================

-- ---------- espaco_por_nome: o id real de um chat que chegou so com o nome ----------
-- A varredura do Chat as vezes traz so o nome. Com o id errado, a resposta
-- dele nao casa com a pergunta daquele chat e o Jarvis cobra o que ja foi
-- respondido. Procura no dm_mapa (DM pelo nome da pessoa) e depois no
-- unico `spaces/` ja visto com aquele nome. Nome generico ou ambiguo = null.
create or replace function jarvis.espaco_por_nome(p_nome text)
 returns text language plpgsql stable
as $function$
declare v_nome text := nullif(btrim(p_nome), ''); v_id text;
begin
  if v_nome is null or v_nome = 'Unknown'
     or v_nome ~* '^(direct message|mensagem direta|dm \(a identificar\)|dm)$' then
    return null;
  end if;
  if v_nome ~* '^DM\s' then
    return jarvis.dm_espaco(regexp_replace(v_nome, '^DM\s*(com\s+)?', '', 'i'));
  end if;
  select min(space_id) into v_id from jarvis.dm_mapa
   where pessoa_nome is not null and jarvis.slug(pessoa_nome) = jarvis.slug(v_nome)
  having count(distinct space_id) = 1;
  if v_id is not null then return v_id; end if;
  select min(space_id) into v_id from jarvis.mensagens
   where jarvis.chave_espaco(space_id, space_nome) = jarvis.chave_espaco('x', v_nome)
     and space_id like 'spaces/%'
  having count(distinct space_id) = 1;
  return v_id;
end $function$;

-- ---------- resgatar_espacos: conserta o que entrou antes sem id ----------
-- Apaga a copia sem id quando ja existe a mesma mensagem com id, e da o
-- id real as que ficaram em `desconhecido:<nome>`.
create or replace function jarvis.resgatar_espacos(p_nomes text[] default null)
 returns jsonb language plpgsql
as $function$
declare v_dup int; v_fix int;
begin
  delete from jarvis.mensagens a
   using jarvis.mensagens b
   where a.space_id like 'desconhecido%'
     and b.space_id like 'spaces/%'
     and a.autor_id = b.autor_id and a.create_time = b.create_time
     and (p_nomes is null or a.space_nome = any(p_nomes));
  get diagnostics v_dup = row_count;

  with alvo as (
    select m.id, jarvis.espaco_por_nome(m.space_nome) as novo
      from jarvis.mensagens m
     where m.space_id like 'desconhecido:%' and m.space_id <> 'desconhecido:Unknown'
       and (p_nomes is null or m.space_nome = any(p_nomes))
  )
  update jarvis.mensagens m set space_id = a.novo
    from alvo a
   where m.id = a.id and a.novo is not null
     and not exists (select 1 from jarvis.mensagens x
                      where x.space_id = a.novo and x.autor_id = m.autor_id
                        and x.create_time = m.create_time);
  get diagnostics v_fix = row_count;

  return jsonb_build_object('copias_apagadas', v_dup, 'ids_resgatados', v_fix);
end $function$;

-- ---------- dm_registrar: anota o id de uma DM e com quem ela e ----------
create or replace function jarvis.dm_registrar(p_space_id text, p_pessoa_nome text,
                                               p_pessoa_id text default null)
 returns jsonb language plpgsql
as $function$
begin
  if coalesce(btrim(p_space_id),'') not like 'spaces/%' then
    raise exception 'dm_registrar exige um space_id de verdade (spaces/...), veio "%"', p_space_id;
  end if;
  insert into jarvis.dm_mapa (space_id, pessoa_nome, pessoa_id, visto_em, tentativas)
  values (btrim(p_space_id), nullif(btrim(p_pessoa_nome),''), nullif(btrim(p_pessoa_id),''), now(), 1)
  on conflict (space_id) do update
    set pessoa_nome = coalesce(excluded.pessoa_nome, jarvis.dm_mapa.pessoa_nome),
        pessoa_id   = coalesce(excluded.pessoa_id,   jarvis.dm_mapa.pessoa_id),
        visto_em    = now(),
        tentativas  = jarvis.dm_mapa.tentativas + 1;
  return jsonb_build_object('ok', true, 'space_id', btrim(p_space_id), 'pessoa', p_pessoa_nome);
end $function$;

-- ---------- gravar_mensagens: o que foi lido do Chat ----------
-- 24/09/2026: so procurava o id quando o nome comecava com "DM", e a mesma
-- mensagem acabava gravada duas vezes (com e sem id). Agora usa
-- espaco_por_nome antes de cair em `desconhecido:`, nao grava de novo o que
-- ja existe com id, e no fim chama resgatar_espacos para o lote.
-- O que sobrar sem id vira defeito anotado (a auditoria diaria le).
--
-- A versao de 1 argumento (a desta pasta antes de 30/09) tem que sair:
-- com as duas, a chamada de 1 argumento da "function is not unique".
drop function if exists jarvis.gravar_mensagens(jsonb);
create or replace function jarvis.gravar_mensagens(p_msgs jsonb, p_run_id text default null)
 returns jsonb language plpgsql
as $function$
declare v_novas int; v_pessoas jsonb; v_sem_id int := 0; v_resgatadas int := 0;
        v_nomes text[]; v_hist jsonb;
begin
  select coalesce(valor, '{}'::jsonb) into v_pessoas
    from jarvis.estado where chave = 'pessoas';

  with lote as (
    select m, id_cru,
           case when coalesce(nome_cru,'') = '' then 'Unknown' else nome_cru end as nome_final,
           case when id_cru like 'spaces/%' then id_cru
                else coalesce(jarvis.espaco_por_nome(nome_cru),
                              case when coalesce(nome_cru,'Unknown') = 'Unknown'
                                        or nome_cru ilike 'DM%'
                                   then 'desconhecido:Unknown'
                                   else 'desconhecido:' || nome_cru end)
           end as space_final
      from (select m,
                   nullif(btrim(m->>'space_id'), '')   as id_cru,
                   nullif(btrim(m->>'space_nome'), '') as nome_cru
              from jsonb_array_elements(coalesce(p_msgs, '[]'::jsonb)) m
             where coalesce(btrim(m->>'texto'), '') <> ''
               and (m->>'create_time') is not null) b
  ), gravadas as (
    insert into jarvis.mensagens
      (space_id, space_nome, autor_id, autor_nome, texto, create_time, is_dono, cortado)
    select space_final, nome_final,
           coalesce(nullif(m->>'autor_id', ''), 'desconhecido'),
           coalesce(nullif(btrim(m->>'autor_nome'), ''),
                    v_pessoas->>coalesce(nullif(m->>'autor_id', ''), '-')),
           m->>'texto',
           (m->>'create_time')::timestamptz,
           coalesce((m->>'is_dono')::boolean, false),
           coalesce((m->>'cortado')::boolean, false)
      from lote l
     where not exists (select 1 from jarvis.mensagens x
                        where l.space_final like 'desconhecido%'
                          and x.space_id like 'spaces/%'
                          and x.autor_id = coalesce(nullif(l.m->>'autor_id', ''), 'desconhecido')
                          and x.create_time = (l.m->>'create_time')::timestamptz)
    on conflict on constraint mensagens_unicas do nothing
    returning 1
  )
  select (select count(*)::int from gravadas),
         count(*) filter (where coalesce(id_cru,'') not like 'spaces/%'),
         count(*) filter (where coalesce(id_cru,'') not like 'spaces/%' and space_final like 'spaces/%'),
         array_agg(distinct nome_final)
    into v_novas, v_sem_id, v_resgatadas, v_nomes
    from lote;

  v_hist := jarvis.resgatar_espacos(v_nomes);

  if v_sem_id - v_resgatadas > 0 then
    perform jarvis.anotar_defeito('gravar_mensagens', 'mensagem sem id de espaco',
      'suspeito',
      jsonb_build_object('quantas', v_sem_id - v_resgatadas,
                         'resgatadas_pelo_nome', v_resgatadas,
                         'efeito', 'nao da pra cruzar resposta dele com pergunta desse chat'),
      p_run_id);
  end if;

  return jsonb_build_object('novas', v_novas,
                            'recebidas', jsonb_array_length(coalesce(p_msgs, '[]'::jsonb)),
                            'sem_id_de_espaco', v_sem_id - v_resgatadas,
                            'resgatadas_pelo_nome', v_resgatadas,
                            'historico', v_hist);
end $function$;

-- ---------- upsert_compromisso: a unica porta para criar alerta ----------
-- Mudou bastante desde a primeira versao:
--   * subtipo obrigatorio (uma linha de jarvis.categorias; sem ele, cai no
--     fallback do tipo) -- e o que escolhe emoji, rotulo e botoes;
--   * alerta vago ("a outra pessoa ja confirmou") e recusado;
--   * reuniao e prazo exigem a hora; nos outros tipos a data e sempre gravada;
--   * pergunta_aberta exige a hora da mensagem, e uma pergunta vira UMA serie
--     de cobranca em qualquer status. Antes, a serie que esgotava as 6h
--     ficava "disparado" e a rodada seguinte recriava com titulo reescrito --
--     uma mesma pergunta foi cobrada ~27 vezes em tres dias (28/09/2026).
--
-- Mantenha UMA versao so desta funcao. Duas vezes (03/09 e 23/09) uma
-- assinatura antiga ficou para tras, e toda chamada com menos argumentos
-- passou a dar "function is not unique" -- inclusive a do vigia.
-- Por isso o drop da assinatura de 14 argumentos (a desta pasta antes de 30/09).
drop function if exists jarvis.upsert_compromisso(text, text, timestamptz, text, text, text,
  timestamptz, text, text, text, timestamptz, text, text, text);
create or replace function jarvis.upsert_compromisso(
  p_tipo text, p_titulo text, p_alerta_em timestamptz, p_origem_texto text, p_run_id text,
  p_mensagem_alerta text default null, p_quando timestamptz default null,
  p_descricao text default null, p_space_origem text default null,
  p_space_origem_nome text default null, p_origem_msg_time timestamptz default null,
  p_origem_autor text default null, p_calendar_event_id text default null,
  p_prioridade text default 'normal', p_subtipo text default null,
  p_urgencia_motivo text default null)
 returns jsonb language plpgsql
as $function$
declare
  v_fp text; v_antes jarvis.compromissos; v_ja jarvis.compromissos;
  v_id bigint; v_mudou boolean; v_prio text; v_sub text; v_quando timestamptz;
  v_quando_antes timestamptz; v_n int; v_ate timestamptz;
begin
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: compromisso sem citacao literal nao entra (anti-alucinacao)';
  end if;

  perform jarvis.checar_alerta_vago(p_mensagem_alerta, 'upsert_compromisso ' || p_tipo);

  -- categoria: 19 subtipos, um emoji cada. Sem subtipo, cai no fallback do tipo.
  v_sub := coalesce(nullif(btrim(p_subtipo), ''),
             case p_tipo when 'aviso' then 'outro'
                         when 'pergunta_aberta' then 'pergunta'
                         else p_tipo end);
  if not exists (select 1 from jarvis.categorias where subtipo = v_sub) then
    raise exception 'subtipo % nao existe. Os validos: %', v_sub,
      (select string_agg(subtipo, ', ' order by ordem) from jarvis.categorias);
  end if;

  -- nome de gente, nunca rotulo generico: o alerta e lido horas depois
  if p_origem_autor ilike '%identificad%' then
    raise exception 'origem_autor "%" nao e nome de gente: passe o nome de quem falou, ou deixe nulo', p_origem_autor;
  end if;

  if p_tipo = 'conflito' then
    if p_quando is null then
      raise exception 'conflito exige p_quando = o DIA E A HORA DO CHOQUE (nao agora): sem isso a deduplicacao junta choques diferentes';
    end if;
    if p_quando < now() - interval '5 minutes' then
      raise exception 'conflito com p_quando no passado (%): passe o dia e a hora do choque, nao o momento em que voce descobriu',
        to_char(p_quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    end if;
  end if;

  -- data SEMPRE gravada. Reuniao e prazo exigem a hora de verdade; nas demais,
  -- a data do fato e a hora da mensagem que o gerou.
  if p_tipo in ('reuniao','prazo') and p_quando is null then
    raise exception '% exige p_quando (o dia e a hora da coisa): data e hora sao obrigatorias nesse tipo', p_tipo;
  end if;
  v_quando := coalesce(p_quando, p_origem_msg_time, p_alerta_em);

  if p_tipo = 'pergunta_aberta' then
    if p_origem_msg_time is null then
      raise exception 'pergunta_aberta exige p_origem_msg_time (a hora da mensagem que perguntou): sem isso nao ha como saber se essa pergunta ja foi encerrada antes';
    end if;

    -- uma pergunta = uma serie de cobranca, em QUALQUER status. Antes so olhava
    -- cancelado/cumprido: serie que esgotou as 6h ficava "disparado" e a rodada
    -- seguinte recriava com titulo reescrito (serie nova, 6h novas). Marina 25-27/09.
    select * into v_ja
      from jarvis.compromissos c
     where c.tipo = 'pergunta_aberta'
       and c.origem_msg_time between p_origem_msg_time - interval '30 minutes'
                                 and p_origem_msg_time + interval '30 minutes'
       and (case when coalesce(btrim(p_origem_autor), '') <> ''
                   and coalesce(btrim(c.origem_autor), '') <> ''
                 then jarvis.slug(c.origem_autor) = jarvis.slug(p_origem_autor)
                 else jarvis.slug(coalesce(c.space_origem_nome, ''))
                      = jarvis.slug(coalesce(p_space_origem_nome, '')) end)
     order by case when c.status in ('cancelado', 'cumprido') then 0 else 1 end, c.id desc
     limit 1;

    if found then
      if v_ja.status in ('cancelado', 'cumprido') then
        return jsonb_build_object(
          'acao', 'ignorado', 'id', v_ja.id, 'status', v_ja.status,
          'nota', 'esta MESMA pergunta ja foi encerrada como ' || v_ja.status
                  || ' no compromisso ' || v_ja.id
                  || ' (' || coalesce(left(v_ja.cancelado_motivo, 80), 'sem motivo') || ')'
                  || ' -- nao recrie. Se ele pedir de novo, fale com ele antes.');
      end if;

      select count(*) filter (where disparado_em is not null), max(repetir_ate)
        into v_n, v_ate
        from jarvis.compromissos
       where serie = v_ja.serie;

      return jsonb_build_object(
        'acao', 'ignorado', 'id', v_ja.id, 'status', v_ja.status, 'serie', v_ja.serie,
        'nota', case when v_ate > now()
                     then 'esta pergunta ja esta sendo cobrada (serie ' || v_ja.serie || ', ate '
                          || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
                          || ') -- nao recrie nem mude a hora'
                     else 'esta pergunta ja foi cobrada ' || coalesce(v_n, 0)
                          || ' vezes e a janela de cobranca acabou -- nao recrie. Se ainda importa, cite no resumo, sem cobrar de novo.'
                end);
    end if;
  end if;

  v_prio := case when coalesce(p_prioridade, 'normal') = 'alta' then 'alta' else 'normal' end;

  -- fingerprint segue usando p_quando cru: mexer nisso ressuscitaria alerta antigo
  v_fp := case
            when p_tipo = 'aviso' then
              'aviso:'
              || case when p_calendar_event_id is not null
                      then 'cal:' || p_calendar_event_id
                      else left(jarvis.slug(p_titulo), 60) end
              || ':' || to_char(coalesce(p_quando, p_alerta_em, now())
                                  at time zone 'America/Sao_Paulo', 'YYYYMMDD')
            when p_calendar_event_id is not null then 'cal:' || p_calendar_event_id
            when p_tipo = 'conflito' then
              'conflito:' || to_char(p_quando at time zone 'UTC', 'YYYYMMDD"T"HH24')
            else jarvis.fingerprint(p_tipo, p_titulo, coalesce(p_quando, p_alerta_em))
          end;

  select * into v_antes from jarvis.compromissos where fingerprint = v_fp;

  if not found then
    insert into jarvis.compromissos
      (tipo, subtipo, titulo, descricao, quando_utc, alerta_em_utc, space_origem, space_origem_nome,
       fingerprint, origem_texto, origem_msg_time, origem_autor, calendar_event_id,
       mensagem_alerta, prioridade, urgencia_motivo, repetir_min, repetir_ate, serie)
    values
      (p_tipo, v_sub, p_titulo, p_descricao, v_quando, p_alerta_em, p_space_origem, p_space_origem_nome,
       v_fp, p_origem_texto, p_origem_msg_time, p_origem_autor, p_calendar_event_id,
       p_mensagem_alerta, v_prio, nullif(btrim(coalesce(p_urgencia_motivo,'')), ''),
       case when p_tipo = 'pergunta_aberta' then
         coalesce((select (valor->>'pergunta_repetir_min')::int from jarvis.estado where chave='config'), 30)
       end,
       case when p_tipo = 'pergunta_aberta' then
         p_alerta_em + make_interval(hours =>
           coalesce((select (valor->>'pergunta_repetir_horas')::int from jarvis.estado where chave='config'), 6))
       end,
       case when p_tipo = 'pergunta_aberta' then 'pergunta:' || v_fp end)
    returning id into v_id;

    insert into jarvis.eventos (compromisso_id, acao, motivo, depois, run_id)
    values (v_id, 'criou', p_titulo,
            jsonb_build_object('tipo', p_tipo, 'subtipo', v_sub, 'quando', v_quando,
                               'alerta_em', p_alerta_em, 'prioridade', v_prio), p_run_id);

    return jsonb_build_object('acao', 'criou', 'id', v_id, 'fingerprint', v_fp,
                              'subtipo', v_sub,
                              'rotulo', jarvis.rotulo(p_tipo, v_prio, v_sub));
  end if;

  -- linha antiga sem quando gravado nao conta como mudanca (senao ressuscita alerta)
  v_quando_antes := coalesce(v_antes.quando_utc, v_quando);

  if p_tipo = 'conflito' then
    v_mudou := v_quando_antes <> v_quando;
  elsif p_tipo = 'aviso' then
    v_mudou := false;
  else
    v_mudou := (v_quando_antes <> v_quando)
            or (coalesce(v_antes.alerta_em_utc, 'epoch'::timestamptz) <> coalesce(p_alerta_em, 'epoch'::timestamptz))
            or (coalesce(v_antes.titulo, '')    <> coalesce(p_titulo, ''))
            or (coalesce(v_antes.descricao, '') <> coalesce(p_descricao, v_antes.descricao, ''));
  end if;

  if v_antes.status in ('cancelado', 'cumprido') and v_quando_antes = v_quando then
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', 'estava ' || v_antes.status || ' e a hora nao mudou');
  end if;

  if not v_mudou then
    update jarvis.compromissos
       set titulo          = coalesce(p_titulo, titulo),
           subtipo         = coalesce(v_sub, subtipo),
           descricao       = coalesce(p_descricao, descricao),
           mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
           prioridade      = v_prio,
           urgencia_motivo = coalesce(nullif(btrim(coalesce(p_urgencia_motivo,'')), ''), urgencia_motivo),
           quando_utc      = coalesce(quando_utc, v_quando),
           alerta_em_utc   = case when status = 'pendente' then p_alerta_em else alerta_em_utc end,
           atualizado_em   = now()
     where id = v_antes.id;
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', case when p_tipo = 'aviso'
                                           then 'aviso ja existe hoje para este assunto -- nao repete'
                                      end);
  end if;

  update jarvis.compromissos set
    titulo          = p_titulo,
    subtipo         = coalesce(v_sub, subtipo),
    descricao       = coalesce(p_descricao, descricao),
    quando_utc      = v_quando,
    alerta_em_utc   = p_alerta_em,
    mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
    prioridade      = v_prio,
    urgencia_motivo = coalesce(nullif(btrim(coalesce(p_urgencia_motivo,'')), ''), urgencia_motivo),
    origem_texto    = p_origem_texto,
    origem_msg_time = coalesce(p_origem_msg_time, origem_msg_time),
    status          = 'pendente',
    disparado_em    = null,
    cancelado_motivo = null,
    atualizado_em   = now()
  where id = v_antes.id
  returning id into v_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, antes, depois, run_id)
  values (v_id, 'atualizou',
          case when v_antes.status = 'cancelado' then 'remarcado depois de cancelado' else 'hora mudou' end,
          jsonb_build_object('titulo', v_antes.titulo, 'quando', v_antes.quando_utc,
                             'alerta_em', v_antes.alerta_em_utc, 'status', v_antes.status,
                             'prioridade', v_antes.prioridade),
          jsonb_build_object('titulo', p_titulo, 'quando', v_quando,
                             'alerta_em', p_alerta_em, 'status', 'pendente',
                             'prioridade', v_prio),
          p_run_id);

  return jsonb_build_object('acao', 'atualizou', 'id', v_id, 'fingerprint', v_fp,
                            'subtipo', v_sub, 'status_antes', v_antes.status);
end $function$;

-- ---------- upsert_assunto: a memoria de longo prazo ----------
create or replace function jarvis.upsert_assunto(p_chave text, p_titulo text, p_resumo text,
  p_pessoas text[] default '{}', p_spaces text[] default '{}', p_aberto boolean default true)
 returns jsonb language plpgsql
as $function$
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
end $function$;

-- ---------- encerrar_compromisso: motivo obrigatorio ----------
create or replace function jarvis.encerrar_compromisso(p_id bigint, p_status text, p_motivo text, p_run_id text)
 returns jsonb language plpgsql
as $function$
declare v_antes jarvis.compromissos; v_irmas int := 0;
begin
  if p_status not in ('cancelado', 'cumprido', 'expirado') then
    raise exception 'status invalido para encerrar: %', p_status;
  end if;
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'motivo obrigatorio: voce precisa saber POR QUE cancelou';
  end if;

  select * into v_antes from jarvis.compromissos where id = p_id;
  if not found then
    return jsonb_build_object('acao', 'nada', 'nota', 'id inexistente');
  end if;
  if v_antes.status = p_status then
    return jsonb_build_object('acao', 'nada', 'id', p_id, 'nota', 'ja estava ' || p_status);
  end if;

  update jarvis.compromissos
     set status = p_status,
         cancelado_motivo = p_motivo,
         atualizado_em = now()
   where id = p_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, antes, depois, run_id)
  values (p_id,
          case p_status when 'cancelado' then 'cancelou' when 'cumprido' then 'cumpriu' else 'expirou' end,
          p_motivo,
          jsonb_build_object('status', v_antes.status, 'quando', v_antes.quando_utc),
          jsonb_build_object('status', p_status), p_run_id);

  update jarvis.compromissos
     set status = p_status,
         cancelado_motivo = 'junto com o compromisso ' || p_id || ': ' || p_motivo,
         atualizado_em = now()
   where fingerprint = v_antes.fingerprint || ':vespera'
     and status = 'pendente';
  get diagnostics v_irmas = row_count;

  return jsonb_build_object('acao', p_status, 'id', p_id, 'titulo', v_antes.titulo,
                            'era_status', v_antes.status, 'vespera_encerrada', v_irmas);
end $function$;

-- ---------- encerrar_serie: desliga um pedido recorrente ----------
-- 09/09/2026: so sabia matar serie `pedido:`, e a cobranca de pergunta
-- (`pergunta:...`) seguia insistindo depois de ele mandar parar. Agora
-- aceita a serie inteira (qualquer prefixo) ou o handle de 6 letras.
-- Corta a recorrencia tambem no que ja foi entregue, senao o proximo
-- tique do entregar re-arma a serie.
create or replace function jarvis.encerrar_serie(p_serie text, p_motivo text, p_run_id text default null)
 returns jsonb language plpgsql
as $function$
declare v_h text; v_ids bigint[]; v_n int;
begin
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'motivo obrigatorio para desligar um pedido';
  end if;

  v_h := btrim(p_serie);
  if v_h = '' then
    raise exception 'serie vazia: passe a serie inteira ou o handle de 6 letras';
  end if;

  with fim as (
    update jarvis.compromissos c
       set status = 'cancelado', cancelado_motivo = btrim(p_motivo),
           repetir_min = null, atualizado_em = now()
     where c.status = 'pendente'
       and (    c.serie = v_h
             or starts_with(c.serie, v_h || ':')
             or c.serie = 'pedido:' || v_h
             or starts_with(c.serie, 'pedido:' || v_h || ':') )
    returning c.id
  ) select array_agg(id) into v_ids from fim;

  update jarvis.compromissos c
     set repetir_min = null, atualizado_em = now()
   where c.repetir_min is not null
     and (    c.serie = v_h
           or starts_with(c.serie, v_h || ':')
           or c.serie = 'pedido:' || v_h
           or starts_with(c.serie, 'pedido:' || v_h || ':') );
  get diagnostics v_n = row_count;

  insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
  select id, 'cancelou', btrim(p_motivo), p_run_id from unnest(coalesce(v_ids, '{}')) as id;

  return jsonb_build_object('serie', v_h,
                            'cancelados', coalesce(array_length(v_ids, 1), 0),
                            'recorrencia_cortada', v_n);
end $function$;

-- ---------- achar_serie: "jarvis, para o lembrete de X" -> qual serie ----------
-- Ele fala do lembrete pelo assunto, nao pelo handle. Devolve as series
-- de lembrete pendentes que casam com o texto, a mais provavel primeiro.
create or replace function jarvis.achar_serie(p_texto text)
 returns jsonb language sql stable
as $function$
  with alvo as (select jarvis.slug(coalesce(p_texto,'')) as s)
  select coalesce(jsonb_agg(x order by peso desc, prox), '[]'::jsonb) from (
    select jsonb_build_object('serie', c.serie, 'titulo', c.titulo,
                              'proximo', to_char(c.alerta_em_utc at time zone 'America/Sao_Paulo','DD/MM HH24:MI'),
                              'repetir_min', c.repetir_min) as x,
           case when jarvis.slug(c.titulo) = (select s from alvo) then 3
                when (select s from alvo) like '%' || jarvis.slug(c.titulo) || '%' then 2
                else 1 end as peso,
           c.alerta_em_utc as prox
      from jarvis.compromissos c
     where c.tipo = 'lembrete' and c.status = 'pendente' and c.serie is not null
       and ( jarvis.slug(c.titulo) = (select s from alvo)
          or (select s from alvo) like '%' || jarvis.slug(c.titulo) || '%'
          or jarvis.slug(c.titulo) like '%' || nullif((select s from alvo),'') || '%' )
  ) t
$function$;

-- ---------- fechar_perguntas_respondidas: a entrega nao cobra o que ele ja respondeu ----------
-- Roda dentro do entregar(), antes de montar o lote. Se ele escreveu
-- naquele chat depois da pergunta, a serie inteira fecha como cumprida.
-- Reacao com emoji tambem conta (reacoes_nos_pendentes, no 05).
create or replace function jarvis.fechar_perguntas_respondidas(p_run_id text default 'entrega')
 returns jsonb language plpgsql
as $function$
declare v_ids bigint[]; v_series text[]; v_n int := 0; v_reac jsonb;
begin
  with respondidas as (
    select distinct c.serie,
           (select min(m.create_time) from jarvis.mensagens m
             where m.space_id = c.space_origem and m.is_dono
               and m.create_time > c.origem_msg_time) as respondeu_em
      from jarvis.compromissos c
     where c.tipo = 'pergunta_aberta'
       and c.status = 'pendente'
       and c.serie is not null
       and c.space_origem is not null
       and c.space_origem not like 'desconhecido%'
       and c.origem_msg_time is not null
       and exists (select 1 from jarvis.mensagens m
                    where m.space_id = c.space_origem and m.is_dono
                      and m.create_time > c.origem_msg_time)
  ), fim as (
    update jarvis.compromissos c
       set status = 'cumprido',
           cancelado_motivo = 'ele respondeu naquele espaco em '
             || to_char(r.respondeu_em at time zone 'America/Sao_Paulo', 'DD/MM "as" HH24:MI')
             || ' -- fechado pela entrega, sem cobrar de novo',
           repetir_min = null, atualizado_em = now()
      from respondidas r
     where c.serie = r.serie and c.status = 'pendente'
    returning c.id, c.serie
  )
  select array_agg(id), array_agg(distinct serie) into v_ids, v_series from fim;

  v_n := coalesce(array_length(v_ids, 1), 0);
  if v_n > 0 then
    insert into jarvis.eventos (compromisso_id, acao, motivo, run_id)
    select id, 'cumpriu', 'pergunta ja respondida por ele', p_run_id from unnest(v_ids) as id;
  end if;

  -- 25/09/2026: reação com emoji também conta (ver jarvis.reacoes_nos_pendentes)
  begin
    v_reac := jarvis.reacoes_nos_pendentes(p_run_id);
  exception when others then
    v_reac := jsonb_build_object('erro', sqlerrm);
  end;

  return jsonb_build_object('fechadas', v_n, 'series', to_jsonb(coalesce(v_series,'{}')), 'reacoes', v_reac);
end $function$;

-- ---------- marcar_disparados: usado pelo entregador local (reserva) ----------
create or replace function jarvis.marcar_disparados(p_disparos jsonb, p_run_id text)
 returns jsonb language plpgsql
as $function$
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
              coalesce(d->>'nota', 'postado pelo dispara.ps1'), p_run_id);
    end if;
  end loop;
  return jsonb_build_object('marcados', v_n);
end $function$;
