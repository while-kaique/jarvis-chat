-- fix_grupo_balde_ressurreicao_alerta_vago_10_09  (10/09/2026)
--
-- Tres defeitos que sairam do mesmo dia:
--
-- 1) GRUPO COM NOME EM DOIS BALDES. A correcao de 09/09 unificou so as DMs.
--    Grupo com nome continuou gravado em dois enderecos: id real quando vem do
--    aprofundamento (get_messages) e 'desconhecido:<nome>' quando vem da varredura
--    (search_messages). Como briefing().silencio_dele casa resposta pelo space_id,
--    a resposta dele num balde nunca fechava a pergunta do outro.
--    Caso real: Time de Dados, pergunta em spaces/SEU_SPACE_ID_2
--    e a fala dele em desconhecido:Time de Dados.
--    Correcao: passar a casar por CONVERSA (jarvis.chave_espaco), nao por space_id.
--
-- 2) PERGUNTA ENCERRADA RESSUSCITA NO DIA SEGUINTE. O fingerprint carrega o slug do
--    TITULO + a janela da run. Titulo reescrito = fingerprint nova = serie nova.
--    A pergunta do Rafael foi cancelada em 09/09 e voltou em 10/09 com outro
--    titulo (compromissos 245/247/252). Correcao: pergunta_aberta agora exige
--    origem_msg_time e e barrada quando a MESMA pergunta (mesma pessoa, +-30 min da
--    mesma mensagem) ja foi encerrada como cancelado/cumprido.
--
-- 3) ALERTA QUE NAO DIZ QUEM NEM O QUE. "A outra pessoa ja confirmou que entra as 11h"
--    (compromisso 251) — sem nome, sem assunto, sem citacao. Duas causas:
--    a) jarvis.mensagens aceita autor_nome nulo, entao a identidade se perde na coleta;
--    b) nada impedia o cerebro de escrever o alerta com pronome.
--    Correcao: gravar_mensagens resolve o nome pelo mapa estado.pessoas, e
--    jarvis.checar_alerta_vago() barra pronome no lugar do nome.


-- ---------------------------------------------------------------- 1) chave da conversa
create or replace function jarvis.chave_espaco(p_space_id text, p_space_nome text)
returns text language sql immutable as $$
  select case
           when coalesce(nullif(btrim(p_space_nome), ''), 'Unknown') = 'Unknown'
                or btrim(p_space_nome) ilike 'DM%'
           then 'dm:desconhecido'
           else 'nome:' || lower(regexp_replace(btrim(p_space_nome), '\s+', ' ', 'g'))
         end
$$;

comment on function jarvis.chave_espaco(text, text) is
  'Endereco canonico de uma conversa. O mesmo grupo chega com space_id diferente pela varredura e pelo aprofundamento; o nome e o que os dois caminhos tem em comum. DM (sem nome confiavel) cai num balde unico, como em 09/09.';

create index if not exists mensagens_chave_espaco_tempo
  on jarvis.mensagens (jarvis.chave_espaco(space_id, space_nome), create_time);

-- ---------------------------------------------------------------- 3a) nome do autor
create or replace function jarvis.gravar_mensagens(p_msgs jsonb)
 returns jsonb
 language plpgsql
as $function$
declare v_novas int; v_pessoas jsonb;
begin
  -- estado.pessoas e o mapa users/<id> -> nome. Sem ele, DM de quem nunca apareceu
  -- com nome entra como autor anonimo e o alerta sai dizendo "a outra pessoa".
  select coalesce(valor, '{}'::jsonb) into v_pessoas
    from jarvis.estado where chave = 'pessoas';

  insert into jarvis.mensagens
    (space_id, space_nome, autor_id, autor_nome, texto, create_time, is_dono, cortado)
  select
         case when coalesce(nullif(btrim(m->>'space_nome'), ''), 'Unknown') = 'Unknown'
                   or btrim(m->>'space_nome') ilike 'DM%'
              then 'desconhecido:Unknown'
              else coalesce(nullif(m->>'space_id', ''),
                            'desconhecido:' || coalesce(m->>'space_nome', '?'))
         end,
         case when coalesce(nullif(btrim(m->>'space_nome'), ''), 'Unknown') = 'Unknown'
                   or btrim(m->>'space_nome') ilike 'DM%'
              then 'Unknown'
              else m->>'space_nome'
         end,
         coalesce(nullif(m->>'autor_id', ''), 'desconhecido'),
         coalesce(nullif(btrim(m->>'autor_nome'), ''),
                  v_pessoas->>coalesce(nullif(m->>'autor_id', ''), '-')),
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
end $function$;

-- backfill do que ja esta gravado sem nome mas com id conhecido
update jarvis.mensagens m
   set autor_nome = p.valor->>m.autor_id
  from jarvis.estado p
 where p.chave = 'pessoas'
   and m.autor_nome is null
   and p.valor ? m.autor_id;

-- ---------------------------------------------------------------- 3b) alerta com pronome
create or replace function jarvis.checar_alerta_vago(p_msg text, p_onde text)
returns void language plpgsql immutable as $function$
begin
  if coalesce(p_msg, '') ~* '(a outra pessoa|as outras pessoas|essa pessoa|uma pessoa|a pessoa (ja|já|disse|confirmou|pediu)|com alguem|com alguém|alguem (ja|já)|alguém (ja|já))' then
    raise exception
      '% : alerta vago -- diga o NOME de quem falou e o ASSUNTO. Se o nome nao existe no mapa estado.pessoas, escreva "pessoa nao identificada" e CITE a mensagem dela entre aspas. Texto barrado: "%"',
      p_onde, left(p_msg, 200);
  end if;
end $function$;

comment on function jarvis.checar_alerta_vago(text, text) is
  'Barra alerta escrito com pronome no lugar do nome (compromisso 251, 10/09: "A outra pessoa ja confirmou que entra as 11h"). Um alerta que ele nao consegue entender sozinho e um alerta que ele vai ter que investigar.';


-- ---------------------------------------------------------------- 1) briefing por conversa
create or replace function jarvis.briefing(p_texto_novo text DEFAULT ''::text, p_top integer DEFAULT NULL::integer)
 returns jsonb
 language plpgsql
 stable
as $function$
declare
  v_cfg jsonb; v_top int; v_out jsonb;
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
    -- Toda comparacao daqui pra baixo e por jarvis.chave_espaco (a CONVERSA), nunca por
    -- space_id: o mesmo grupo chega com dois space_id diferentes (varredura x
    -- aprofundamento), e casar por id fazia a resposta dele num balde nao fechar a
    -- pergunta gravada no outro. Foi o falso "ninguem respondeu" do Rafael.
    'silencio_dele', coalesce((
      select jsonb_agg(jsonb_build_object(
               'space', m.space_nome, 'de', coalesce(m.autor_nome, m.autor_id),
               'quando_brt', to_char(m.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'msg_time_utc', to_char(m.create_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'horas_parada', round((extract(epoch from (now() - m.create_time)) / 3600.0)::numeric, 1),
               'texto', left(m.texto, 200),
               'dele_antes_min', (
                  select round((extract(epoch from (m.create_time - max(a.create_time))) / 60.0)::numeric, 1)
                    from jarvis.mensagens a
                   where jarvis.chave_espaco(a.space_id, a.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                     and a.is_dono
                     and a.create_time < m.create_time
                     and a.create_time > m.create_time - interval '60 minutes'),
               'autor_insistiu', exists (
                  select 1 from jarvis.mensagens i
                   where jarvis.chave_espaco(i.space_id, i.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                     and i.autor_id = m.autor_id
                     and i.create_time > m.create_time and i.texto like '%?%'),
               'depois', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'de', coalesce(d.autor_nome, d.autor_id),
                           'quando_brt', to_char(d.create_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                           'texto', left(d.texto, 150)))
                    from (select * from jarvis.mensagens dd
                           where jarvis.chave_espaco(dd.space_id, dd.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                             and dd.create_time > m.create_time
                           order by dd.create_time limit 6) d), '[]'::jsonb)
             ) order by m.create_time desc)
        from jarvis.mensagens m
       where not m.is_dono
         and m.texto like '%?%'
         and m.create_time > now() - interval '3 days'
         and coalesce(m.space_nome, '') <> all (
               select jsonb_array_elements_text(coalesce(valor->'spaces_ignorar', '[]'::jsonb))
                 from jarvis.estado where chave = 'ruido')
         and coalesce(m.autor_nome, '') !~* '(bot|automa[çc][ãa]o|alerta|relat[óo]rio)'
         and m.create_time < now() - make_interval(hours => coalesce((v_cfg->>'silencio_pergunta_horas')::int, 1))
         and not exists (
               select 1 from jarvis.mensagens r
                where jarvis.chave_espaco(r.space_id, r.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                  and r.is_dono and r.create_time > m.create_time)
         and not exists (
               select 1 from jarvis.mensagens o
                where jarvis.chave_espaco(o.space_id, o.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                  and not o.is_dono
                  and o.autor_id is distinct from m.autor_id
                  and o.create_time >  m.create_time
                  and o.create_time <= m.create_time + interval '30 minutes')
         and not (
               exists (
                 select 1 from jarvis.mensagens a
                  where jarvis.chave_espaco(a.space_id, a.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                    and a.is_dono
                    and a.create_time < m.create_time
                    and a.create_time >= m.create_time
                        - make_interval(mins => coalesce((v_cfg->>'conversa_ativa_min')::int, 5)))
           and not exists (
                 select 1 from jarvis.mensagens i
                  where jarvis.chave_espaco(i.space_id, i.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                    and i.autor_id = m.autor_id
                    and i.create_time > m.create_time and i.texto like '%?%'))
         and not exists (
               select 1 from jarvis.mensagens f
                where jarvis.chave_espaco(f.space_id, f.space_nome) = jarvis.chave_espaco(m.space_id, m.space_nome)
                  and f.autor_id = m.autor_id
                  and f.create_time >  m.create_time
                  and f.create_time <= m.create_time
                      + make_interval(mins => coalesce((v_cfg->>'encerrou_autor_min')::int, 30))
                  and f.texto not like '%?%'
                  and char_length(btrim(f.texto)) <= 40
                  and f.texto ~* '(boa|ok|blz|beleza|show|valeu|vlw|obg|obrigad|perfeito|top|entendi|tranquilo|certo|fechado|combinado|kk|rs)')
       limit 15), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $function$;

-- ------------------------------------------- 2) pergunta encerrada nao ressuscita
--                                             3b) alerta com pronome nao passa
create or replace function jarvis.upsert_compromisso(
  p_tipo text, p_titulo text, p_alerta_em timestamp with time zone, p_origem_texto text,
  p_run_id text, p_mensagem_alerta text DEFAULT NULL::text,
  p_quando timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_descricao text DEFAULT NULL::text, p_space_origem text DEFAULT NULL::text,
  p_space_origem_nome text DEFAULT NULL::text,
  p_origem_msg_time timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_origem_autor text DEFAULT NULL::text, p_calendar_event_id text DEFAULT NULL::text,
  p_prioridade text DEFAULT 'normal'::text)
 returns jsonb
 language plpgsql
as $function$
declare
  v_fp text; v_antes jarvis.compromissos; v_ja jarvis.compromissos;
  v_id bigint; v_mudou boolean; v_prio text;
begin
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: compromisso sem citacao literal nao entra (anti-alucinacao)';
  end if;

  -- Alerta que ele nao entende sozinho e alerta que ele vai ter que investigar.
  perform jarvis.checar_alerta_vago(p_mensagem_alerta, 'upsert_compromisso ' || p_tipo);

  -- A chave do choque e o dia+hora DO CHOQUE. Se vier nulo ou vier "agora"
  -- (o momento em que o cerebro descobriu), a deduplicacao quebra e o mesmo
  -- choque renasce a cada rodada -- foi o que aconteceu 5 vezes com 14/09.
  if p_tipo = 'conflito' then
    if p_quando is null then
      raise exception 'conflito exige p_quando = o DIA E A HORA DO CHOQUE (nao agora): sem isso a deduplicacao junta choques diferentes';
    end if;
    if p_quando < now() - interval '5 minutes' then
      raise exception 'conflito com p_quando no passado (%): passe o dia e a hora do choque, nao o momento em que voce descobriu',
        to_char(p_quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    end if;
  end if;

  -- Pergunta aberta: o fingerprint carrega o slug do TITULO, entao titulo reescrito
  -- num dia seguinte nascia como serie nova e a pergunta ressuscitava (Rafael,
  -- cancelado em 09/09, de volta em 10/09). A identidade real da pergunta e a
  -- MENSAGEM que a originou -- e ela precisa vir preenchida.
  if p_tipo = 'pergunta_aberta' then
    if p_origem_msg_time is null then
      raise exception 'pergunta_aberta exige p_origem_msg_time (a hora da mensagem que perguntou): sem isso nao ha como saber se essa pergunta ja foi encerrada antes';
    end if;

    select * into v_ja
      from jarvis.compromissos c
     where c.tipo = 'pergunta_aberta'
       and c.status in ('cancelado', 'cumprido')
       and c.origem_msg_time between p_origem_msg_time - interval '30 minutes'
                                 and p_origem_msg_time + interval '30 minutes'
       and (case when coalesce(btrim(p_origem_autor), '') <> ''
                   and coalesce(btrim(c.origem_autor), '') <> ''
                 then jarvis.slug(c.origem_autor) = jarvis.slug(p_origem_autor)
                 else jarvis.slug(coalesce(c.space_origem_nome, ''))
                      = jarvis.slug(coalesce(p_space_origem_nome, '')) end)
     order by c.id desc
     limit 1;

    if found then
      return jsonb_build_object(
        'acao', 'ignorado', 'id', v_ja.id, 'status', v_ja.status,
        'nota', 'esta MESMA pergunta ja foi encerrada como ' || v_ja.status
                || ' no compromisso ' || v_ja.id
                || ' (' || coalesce(left(v_ja.cancelado_motivo, 80), 'sem motivo') || ')'
                || ' -- nao recrie. Se ele pedir de novo, fale com ele antes.');
    end if;
  end if;

  v_prio := case when coalesce(p_prioridade, 'normal') = 'alta' then 'alta' else 'normal' end;

  v_fp := case
            -- Aviso: um por assunto por DIA. Ancorado no event_id quando o aviso
            -- e sobre um evento do Calendar; nunca no minuto em que ele descobriu.
            -- Vem antes do ramo 'cal:' para nao colidir com a linha da reuniao.
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
      (tipo, titulo, descricao, quando_utc, alerta_em_utc, space_origem, space_origem_nome,
       fingerprint, origem_texto, origem_msg_time, origem_autor, calendar_event_id,
       mensagem_alerta, prioridade, repetir_min, repetir_ate, serie)
    values
      (p_tipo, p_titulo, p_descricao, p_quando, p_alerta_em, p_space_origem, p_space_origem_nome,
       v_fp, p_origem_texto, p_origem_msg_time, p_origem_autor, p_calendar_event_id,
       p_mensagem_alerta, v_prio,
       -- pergunta que ficou sem resposta insiste de 30 em 30 min ate o teto.
       -- So para quando o cerebro chamar encerrar_compromisso.
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
            jsonb_build_object('tipo', p_tipo, 'quando', p_quando, 'alerta_em', p_alerta_em,
                               'prioridade', v_prio), p_run_id);

    return jsonb_build_object('acao', 'criou', 'id', v_id, 'fingerprint', v_fp,
                              'rotulo', jarvis.rotulo(p_tipo, v_prio));
  end if;

  -- Para choque, so a HORA DO CHOQUE reabre a linha. Titulo reescrito e alerta_em
  -- recalculado a cada rodada nao sao noticia nova. Para os outros tipos vale a
  -- regra antiga (promessa nao cumprida volta a cobrar).
  if p_tipo = 'conflito' then
    v_mudou := coalesce(v_antes.quando_utc, 'epoch'::timestamptz)
            <> coalesce(p_quando, 'epoch'::timestamptz);
  elsif p_tipo = 'aviso' then
    -- Aviso e tiro unico: uma vez dito, esta dito. Nada reabre.
    -- Sem esta linha, a chave estavel acima faria a rodada seguinte REENTREGAR
    -- o mesmo aviso (titulo reescrito contava como mudanca), o que troca
    -- duplicata por repeticao.
    v_mudou := false;
  else
    v_mudou := (coalesce(v_antes.quando_utc,    'epoch'::timestamptz) <> coalesce(p_quando,    'epoch'::timestamptz))
            or (coalesce(v_antes.alerta_em_utc, 'epoch'::timestamptz) <> coalesce(p_alerta_em, 'epoch'::timestamptz))
            or (coalesce(v_antes.titulo, '')    <> coalesce(p_titulo, ''))
            or (coalesce(v_antes.descricao, '') <> coalesce(p_descricao, v_antes.descricao, ''));
  end if;

  if v_antes.status in ('cancelado', 'cumprido')
     and coalesce(v_antes.quando_utc, 'epoch'::timestamptz) = coalesce(p_quando, 'epoch'::timestamptz) then
    return jsonb_build_object('acao', 'inalterado', 'id', v_antes.id, 'status', v_antes.status,
                              'nota', 'estava ' || v_antes.status || ' e a hora nao mudou');
  end if;

  if not v_mudou then
    update jarvis.compromissos
       set titulo          = coalesce(p_titulo, titulo),
           descricao       = coalesce(p_descricao, descricao),
           mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
           prioridade      = v_prio,
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
    descricao       = coalesce(p_descricao, descricao),
    quando_utc      = p_quando,
    alerta_em_utc   = p_alerta_em,
    mensagem_alerta = coalesce(p_mensagem_alerta, mensagem_alerta),
    prioridade      = v_prio,
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
          jsonb_build_object('titulo', p_titulo, 'quando', p_quando,
                             'alerta_em', p_alerta_em, 'status', 'pendente',
                             'prioridade', v_prio),
          p_run_id);

  return jsonb_build_object('acao', 'atualizou', 'id', v_id, 'fingerprint', v_fp,
                            'status_antes', v_antes.status);
end $function$;

-- ------------------- 3b) o pedido dele tambem passa pela guarda do alerta vago
-- O compromisso 251 ("A outra pessoa ja confirmou que entra as 11h hoje") nasceu por
-- aqui, de um item numerado do Resumo 7h. Pedido dele nao dispensa nome nem assunto:
-- o alerta e lido daqui a horas, quando ele nao lembra mais de quem se tratava.
create or replace function jarvis.agendar_pedido(
  p_titulo text, p_origem_texto text,
  p_alerta_em timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_repetir_min integer DEFAULT NULL::integer,
  p_repetir_ate timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_mensagem_alerta text DEFAULT NULL::text, p_prioridade text DEFAULT 'normal'::text,
  p_origem_msg_time timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_run_id text DEFAULT NULL::text, p_confirmar boolean DEFAULT true)
 returns jsonb
 language plpgsql
as $function$
declare
  v_cfg jsonb; v_space text; v_space_nome text;
  v_handle text; v_serie text; v_alerta timestamptz; v_ate timestamptz;
  v_prio text; v_n int; v_id bigint; v_txt text; v_quando_txt text;
  c_teto_ocorrencias int := 60;
begin
  if coalesce(btrim(p_titulo), '') = '' then
    raise exception 'pedido sem titulo';
  end if;
  if coalesce(btrim(p_origem_texto), '') = '' then
    raise exception 'origem_texto vazio: nem pedido dele entra sem a citacao literal';
  end if;

  perform jarvis.checar_alerta_vago(p_mensagem_alerta, 'agendar_pedido');
  perform jarvis.checar_alerta_vago(p_titulo, 'agendar_pedido (titulo)');

  select valor into v_cfg from jarvis.estado where chave = 'config';
  v_space      := coalesce(v_cfg->>'space_alerta', 'spaces/SEU_SPACE_ID');
  v_space_nome := coalesce(v_cfg->>'space_alerta_nome', 'Alertas do Jarvis');

  v_handle := substr(md5(btrim(p_origem_texto) || coalesce(p_origem_msg_time::text, '')), 1, 6);
  v_serie  := 'pedido:' || v_handle;

  if exists (select 1 from jarvis.compromissos where serie like v_serie || '%') then
    return jsonb_build_object('acao', 'inalterado', 'serie', v_serie,
                              'nota', 'esse pedido ja foi registrado');
  end if;

  v_prio   := case when coalesce(p_prioridade, 'normal') = 'alta' then 'alta' else 'normal' end;
  v_alerta := coalesce(p_alerta_em, now());

  if p_repetir_min is not null then
    if p_repetir_min < 5 then
      raise exception 'intervalo de % min e menor que o piso de 5 min (a entrega roda de 5 em 5)', p_repetir_min;
    end if;
    -- sem teto explicito, um pedido repetido morre em 8h: cron sem fim vira ruido
    v_ate := coalesce(p_repetir_ate, greatest(v_alerta, now()) + interval '8 hours');
    if v_ate <= v_alerta then
      raise exception 'repetir_ate (%) nao e depois do primeiro alerta (%)', v_ate, v_alerta;
    end if;
    v_n := floor(extract(epoch from (v_ate - v_alerta)) / (p_repetir_min * 60))::int + 1;
    if v_n > c_teto_ocorrencias then
      raise exception 'esse pedido geraria % avisos (teto %): aumente o intervalo ou encurte a janela',
                      v_n, c_teto_ocorrencias;
    end if;
  end if;

  insert into jarvis.compromissos
    (tipo, titulo, alerta_em_utc, prioridade, mensagem_alerta, origem_texto,
     origem_msg_time, origem_autor, space_origem, space_origem_nome,
     fingerprint, serie, repetir_min, repetir_ate)
  values
    ('lembrete', btrim(p_titulo), v_alerta, v_prio,
     coalesce(p_mensagem_alerta, '*' || btrim(p_titulo) || '*'), btrim(p_origem_texto),
     p_origem_msg_time, v_cfg->>'self_user_id', v_space, v_space_nome,
     v_serie || ':' || to_char(v_alerta at time zone 'UTC', 'YYYYMMDD"T"HH24MI'),
     v_serie, p_repetir_min, v_ate)
  returning id into v_id;

  insert into jarvis.eventos (compromisso_id, acao, motivo, depois, run_id)
  values (v_id, 'criou', 'pedido dele no espaco de alertas',
          jsonb_build_object('tipo', 'lembrete', 'alerta_em', v_alerta,
                             'repetir_min', p_repetir_min, 'repetir_ate', v_ate,
                             'serie', v_serie, 'prioridade', v_prio), p_run_id);

  -- confirmacao imediata: ele precisa saber que o pedido pegou, e como desligar
  if p_confirmar then
    v_quando_txt := case
      when p_repetir_min is null then
        'uma vez, ' || to_char(v_alerta at time zone 'America/Sao_Paulo', 'DD/MM "as" HH24:MI')
      else
        'de ' || p_repetir_min || ' em ' || p_repetir_min || ' min ate '
          || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM "as" HH24:MI')
          || ' (' || v_n || ' avisos)'
      end;

    v_txt := '*Lembrete criado:* ' || btrim(p_titulo) || chr(10)
          || 'Quando: ' || v_quando_txt || chr(10)
          || '_Para desligar, mande aqui: jarvis para ' || v_handle || '_';

    insert into jarvis.compromissos
      (tipo, titulo, alerta_em_utc, prioridade, mensagem_alerta, origem_texto,
       origem_msg_time, origem_autor, space_origem, space_origem_nome, fingerprint, serie)
    values
      ('aviso', 'confirmacao do lembrete ' || v_handle, now(), 'normal', v_txt,
       btrim(p_origem_texto), p_origem_msg_time, v_cfg->>'self_user_id',
       v_space, v_space_nome, v_serie || ':ack', v_serie || ':ack');
  end if;

  return jsonb_build_object('acao', 'criou', 'id', v_id, 'serie', v_serie,
                            'handle', v_handle, 'alerta_em', v_alerta,
                            'repetir_min', p_repetir_min, 'repetir_ate', v_ate,
                            'ocorrencias_previstas', coalesce(v_n, 1),
                            'rotulo', jarvis.rotulo('lembrete', v_prio));
end $function$;

-- ------------------------------------------- 3a) o mapa de pessoas vira o que a coleta ja sabe
-- estado.pessoas tinha 20 nomes; jarvis.mensagens ja conhecia 50. Como gravar_mensagens
-- passou a resolver o nome pelo mapa, o mapa precisa ser o maior dos dois -- senao a DM
-- de quem chega sem nome no payload continua anonima e o alerta volta a dizer
-- "a outra pessoa". Depois disso: 54 pessoas no mapa, 30 linhas sem nome (ids que
-- ninguem nunca nomeou em lugar nenhum -- para esses o alerta cita a mensagem).
with nomes as (
  select autor_id, min(btrim(replace(autor_nome, ' (voce)', ''))) as nome
    from jarvis.mensagens
   where autor_nome is not null and btrim(autor_nome) <> '' and autor_id like 'users/%'
   group by autor_id
)
update jarvis.mensagens m
   set autor_nome = n.nome
  from nomes n
 where n.autor_id = m.autor_id
   and m.autor_nome is null;

with nomes as (
  select jsonb_object_agg(autor_id, nome) as mapa
    from (select autor_id, min(btrim(replace(autor_nome, ' (voce)', ''))) as nome
            from jarvis.mensagens
           where autor_nome is not null and btrim(autor_nome) <> '' and autor_id like 'users/%'
           group by autor_id) s
)
update jarvis.estado e
   set valor = n.mapa || e.valor,   -- o mapa curado dele vence o aprendido
       atualizado_em = now()
  from nomes n
 where e.chave = 'pessoas';

-- ------------------------------------------- prompt: nuvem v22, resumo7h v4
-- O bloco de regras esta em prompt-escuta.md (secao "O alerta tem que dizer QUEM e O QUE
-- -- 10/09/2026") e foi anexado igual nas duas linhas de jarvis.prompt. O banco e o que
-- as rotinas da nuvem leem; o arquivo e o que a maquina dele le.

-- ------------------------------------------- o que foi feito na mao
-- 1. encerrar_serie('pergunta:pergunta_aberta:responder-o-rafael-descricoes-dos-3-projetos-validadas:20260910T1350')
--    -- 1 pendente cancelado, 2 recorrencias cortadas (motivo: falso positivo).
-- 2. compromisso 251: mensagem_alerta reescrita com a citacao da DM e o aviso de que a
--    pessoa nao esta no mapa. Era o alerta vago; agora diz o que da para dizer.
