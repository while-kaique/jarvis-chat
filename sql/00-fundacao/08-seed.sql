-- ============================================================
-- Jarvis Chat - fundacao 08: o seed do estado
-- ============================================================
-- Depende de: 01 a 07
--
-- ESTE E O UNICO ARQUIVO QUE VOCE PRECISA EDITAR.
-- Troque os 6 valores que voce descobriu no Passo 3 do
-- COMO_INSTALAR.md. Tudo abaixo com SEU_ ou <...> e placeholder.
--
-- As 9 chaves sao obrigatorias. `visto` e `ultima_entrega`
-- parecem dispensaveis e nao sao: `fechar_run` e `entregar`
-- fazem UPDATE nelas, e um update em linha que nao existe nao
-- da erro -- so nao grava. Sem elas, `tem_trabalho` acha que
-- nada mudou desde a run anterior e o cerebro nunca trabalha.
-- ============================================================

insert into jarvis.estado (chave, valor) values

-- ---------- 1. watermark: ate onde o cerebro ja leu ----------
('watermark', '{"ultimo_ok_iso": null,
                "nota": "null = primeira run le as ultimas 24h"}'::jsonb),

-- ---------- 2. turno: o tamanho da sua jornada ----------
-- duracao_horas: quantas horas dura o seu dia de trabalho. Serve
-- para o agente decidir se "entrego hoje" cabe ou vira "amanha".
-- margem_min: quanto antes do fim do turno ele para de agendar.
('turno', '{"data": null, "inicio_utc": null, "fim_alerta_utc": null,
            "duracao_horas": 6, "margem_min": 10}'::jsonb),

-- ---------- 3. heartbeat: o ultimo sinal de vida do cerebro ----------
('heartbeat', '{"ultima_run_utc": null, "run_id": null, "resultado": null}'::jsonb),

-- ---------- 4. lock: quem esta rodando agora ----------
('lock', '{"run_id": null, "expira_utc": null}'::jsonb),

-- ---------- 5. visto: o hash do que ele viu na run anterior ----------
-- E o que faz `tem_trabalho` responder "nada mudou" e economizar
-- um turno inteiro de modelo. Comece vazio.
('visto', '{}'::jsonb),

-- ---------- 6. ultima_entrega: o recibo do ultimo tique do cron ----------
('ultima_entrega', '{}'::jsonb),

-- ---------- 7. config: OS SEUS VALORES ----------
--   space_alerta      -> mcp__google-workspace__list_spaces, page_size 100
--   space_alerta_nome -> o nome que voce deu ao espaco
--   self_user_id      -> o `sender` de uma mensagem sua (search_messages)
--   email             -> o seu
--   mencionar         -> true marca voce no alerta (<users/ID>); so
--                        funciona pelo webhook, nao postando como voce
('config', '{
  "space_alerta": "spaces/SEU_SPACE_ID",
  "space_alerta_nome": "Alertas do Jarvis",
  "self_user_id": "users/SEU_USER_ID",
  "email": "voce@suaempresa.com",
  "mencionar": true,
  "antecedencia_reuniao_min": 10,
  "antecedencia_prazo_min": 20,
  "tolerancia_atraso_min": 90,
  "silencio_pergunta_horas": 4,
  "conversa_ativa_min": 5,
  "encerrou_autor_min": 30,
  "pergunta_repetir_min": 30,
  "pergunta_repetir_horas": 6,
  "top_assuntos": 8
}'::jsonb),

-- ---------- 8. ruido: espacos que ele le mas nao vigia ----------
-- INCLUA O NOME DO SEU PROPRIO space_alerta AQUI. Sem isso o
-- agente le os proprios alertas e entra em laco.
('ruido', '{"spaces_ignorar": ["Alertas do Jarvis",
                               "Nome de um espaco barulhento",
                               "Outro espaco so de robo"],
            "nota": "so entra se citarem voce pelo nome"}'::jsonb),

-- ---------- 9. pessoas: id do Chat -> nome ----------
-- COMECE VAZIO ({}). O agente preenche sozinho conforme conhece
-- as pessoas -- ele tem instrucao para isso no prompt.
('pessoas', '{}'::jsonb)

on conflict (chave) do nothing
returning chave;

-- Precisa devolver 9 linhas. Se devolver menos, alguma chave ja
-- existia -- confira com:
--   select chave, valor from jarvis.estado order by chave;

-- ---------- o prompt do cerebro na nuvem ----------
-- O corpo real e o conteudo de prompt-nuvem.md. Fica no banco (e
-- nao no arquivo da rotina) para voce mudar comportamento com um
-- update, em vez de reeditar as quatro rotinas na nuvem.
insert into jarvis.prompt (nome, versao, corpo)
values ('nuvem', 1, 'COLE AQUI O CONTEUDO DE prompt-nuvem.md')
on conflict (nome) do nothing;
