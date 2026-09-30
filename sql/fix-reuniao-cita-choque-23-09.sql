-- 23/09/2026 — aviso de reuniao citava choque que ja tinha sido resolvido.
-- Caso: "Encontro com Diretores" (id 347) foi escrito em 18/09 14h19 com a linha
-- "Nesse mesmo horario voce tem 1:1 com a Marina as 14h". As 16h05 do mesmo dia a
-- Marina remarcou pra 14h30 e o choque (id 344) foi cancelado — mas o texto do aviso
-- de reuniao, gravado 5 dias antes, saiu intacto hoje.
-- Regra: aviso de reuniao fala SO da propria reuniao. Choque e trabalho do tipo
-- `conflito`, que tem chave propria e e cancelado quando o calendario muda.
-- A trava fica no banco (trigger), nao so no prompt: vale pros dois cerebros.

create or replace function jarvis.guarda_compromisso()
 returns trigger
 language plpgsql
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
  --    Sem o id nao da pra saber que ele respondeu -- foi o caso Carlos,
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
  --    pode ser resolvido no meio -- foi o Diretores x Marina, 23/09/2026. Choque
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

  return new;
end $function$;
