-- ============================================================
-- Jarvis Chat - fundacao 08: o seed do estado e das categorias
-- ============================================================
-- Depende de: 01 a 07
--
-- ESTE E O UNICO ARQUIVO QUE VOCE PRECISA EDITAR.
-- Troque os 6 valores que voce descobriu no Passo 3 do
-- COMO_INSTALAR.md. Tudo abaixo com SEU_ ou <...> e placeholder.
--
-- As 10 chaves sao obrigatorias. `visto` e `ultima_entrega`
-- parecem dispensaveis e nao sao: `fechar_run` e `entregar`
-- fazem UPDATE nelas, e um update em linha que nao existe nao
-- da erro -- so nao grava. Sem elas, `tem_trabalho` acha que
-- nada mudou desde a run anterior e o cerebro nunca trabalha.
--
-- As categorias tambem: compromissos.subtipo e chave estrangeira
-- para jarvis.categorias, e upsert_compromisso recusa subtipo que
-- nao existe. Sem estas linhas, NENHUM aviso entra.
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
-- tentar_lock grava tambem `inicio_utc` (e o teto do watermark).
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
--                        funciona pelo webhook ou pelo app, nao postando como voce
--   resolver_url      -> a pagina que o botao de LINK abre (?t=<token>) e que
--                        chama public.jarvis_resolver. Vazio = aviso sem botao.
--   via_app           -> true so depois que o app do Chat (09) postar E o
--                        clique voltar. False = webhook, com botao de link.
--   silencio_pergunta_horas -> quanto tempo uma pergunta a voce fica sem
--                        resposta antes de virar aviso (1h desde 03/09/2026)
('config', '{
  "space_alerta": "spaces/SEU_SPACE_ID",
  "space_alerta_nome": "Alertas do Jarvis",
  "self_user_id": "users/SEU_USER_ID",
  "email": "voce@suaempresa.com",
  "mencionar": true,
  "resolver_url": "",
  "via_app": false,
  "antecedencia_reuniao_min": 10,
  "antecedencia_prazo_min": 20,
  "tolerancia_atraso_min": 90,
  "silencio_pergunta_horas": 1,
  "conversa_ativa_min": 5,
  "encerrou_autor_min": 30,
  "pergunta_repetir_min": 30,
  "pergunta_repetir_horas": 6,
  "top_assuntos": 8
}'::jsonb),

-- ---------- 8. ruido: espacos que ele le mas nao vigia ----------
-- INCLUA O NOME DO SEU PROPRIO space_alerta AQUI. Sem isso o
-- agente le os proprios alertas e entra em laco. Se voce renomear
-- o espaco, troque aqui tambem (o que vale para a entrega e o id).
('ruido', '{"spaces_ignorar": ["Alertas do Jarvis",
                               "Nome de um espaco barulhento",
                               "Outro espaco so de robo"],
            "nota": "so entra se citarem voce pelo nome"}'::jsonb),

-- ---------- 9. pessoas: id do Chat -> nome ----------
-- COMECE VAZIO ({}). O agente preenche sozinho conforme conhece
-- as pessoas, e jarvis.nome_pessoa completa pela People API.
('pessoas', '{}'::jsonb),

-- ---------- 10. chat_app: o app do Chat (so se aplicar o 09) ----------
--   endpoint      -> URL da Edge Function chat-app. No modo "complemento
--                    do Workspace" ela e o `function` do botao.
--   post_endpoint -> URL da Edge Function chat-post (postar_como_app)
-- Sem o app, deixe como esta: nada le isto enquanto via_app = false.
('chat_app', '{"nome": "Jarvis",
               "endpoint": "https://SEU_PROJECT_REF.supabase.co/functions/v1/chat-app",
               "post_endpoint": "https://SEU_PROJECT_REF.supabase.co/functions/v1/chat-post",
               "projeto_id": "SEU_PROJETO_GCP",
               "numero_projeto": "SEU_PROJECT_NUMBER"}'::jsonb)

on conflict (chave) do nothing
returning chave;

-- Precisa devolver 10 linhas. Se devolver menos, alguma chave ja
-- existia -- confira com:
--   select chave, valor from jarvis.estado order by chave;

-- ---------- as categorias de aviso ----------
-- Uma linha por subtipo: emoji (unico), rotulo (a palavra antes do
-- titulo: "*Pergunta: ...*"), se exige hora, o molde que o cerebro
-- segue ao escrever, e ate dois botoes. Acoes de botao: resolver,
-- cancelar, adiar, manter (so pelo app), responder, agenda.
-- Seis categorias ficam sem botao de proposito: sao recibo, nao pedido.
-- Mudar botao ou rotulo depois e um `update` nesta tabela.
insert into jarvis.categorias (subtipo, tipo, emoji, nome, exige_hora, molde, ordem, rotulo, botoes) values
  ('reuniao', 'reuniao', '📅', 'Reuniao', true,
   'Em 10 min: *<nome>* (<hora>), com <quem>. / linha 2: do que se trata + link', 1, 'Reunião',
   '[{"acao":"agenda","texto":"📅 Abrir agenda"},{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('conflito', 'conflito', '⚡', 'Choque de agenda', true,
   '*<A>* (<janela>) bate com *<B>* (<janela>) / linha 2: o que e cada uma', 2, 'Choque de agenda',
   '[{"acao":"agenda","texto":"📅 Abrir agenda"},{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('prazo', 'prazo', '⏳', 'Prazo', true,
   '<o que vence> / linha 2: quem cobra e o que trava sem isso', 3, 'Prazo',
   '[{"acao":"resolver","texto":"✅ Finalizar aviso"},{"acao":"adiar","texto":"⏰ Me lembre em 1 hora"}]'),
  ('promessa', 'promessa', '🤝', 'Promessa', false,
   'Voce prometeu <o que> pra <quem>: "<citacao>" / linha 2: o que falta', 4, 'Promessa',
   '[{"acao":"responder","texto":"💬 Responder"},{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('pergunta', 'pergunta_aberta', '❓', 'Pergunta sem resposta', false,
   '<Fulano> te perguntou: "<citacao>" e ainda nao teve resposta sua', 5, 'Pergunta',
   '[{"acao":"responder","texto":"💬 Responder"},{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('mencao', 'mencao', '👀', 'Falaram de voce', false,
   '<Fulano> disse em <espaco>: "<citacao>" / linha 2: o que isso muda', 6, 'Falaram de você',
   '[{"acao":"responder","texto":"💬 Abrir conversa"},{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('pergunta_reagida', 'pergunta_aberta', '🤔', 'Você reagiu, mas não sei se resolveu', false,
   'linha 1: quem perguntou e o quê; linha 2: "Você reagiu com <emoji> (<sentido>) — continuo te alertando, ou já foi resolvido?"', 6, 'Pergunta',
   '[{"acao":"manter","texto":"🔔 Continua me avisando"},{"acao":"resolver","texto":"✅ Já foi resolvido"}]'),
  ('lembrete', 'lembrete', '⏰', 'Lembrete que voce pediu', false,
   '<o que fazer>. Voce pediu esse toque <cadencia>', 7, 'Lembrete',
   '[{"acao":"resolver","texto":"✅ Finalizar aviso"},{"acao":"adiar","texto":"⏰ Me lembre em 1 hora"}]'),
  ('lembrete_criado', 'aviso', '🔔', 'Lembrete armado', false,
   '*Lembrete criado:* <o que> / *Quando:* <cadencia>', 10, 'Lembrete armado',
   '[{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('lembrete_fim', 'aviso', '🔕', 'Lembrete encerrado', false,
   '*Ultimo aviso de:* <o que> / a janela fechou', 11, 'Lembrete encerrado',
   '[]'),
  ('alerta_ajustado', 'aviso', '✂️', 'Alerta ajustado', false,
   'Cancelei/mudei <o que> porque <motivo, citando ele>', 12, 'Alerta ajustado',
   '[]'),
  ('item_fechado', 'aviso', '✅', 'Item fechado', false,
   'Marquei como cumprido <o que> / linha 2: a prova', 13, 'Item fechado',
   '[]'),
  ('esclarecimento', 'aviso', '🙋', 'Preciso que voce diga', false,
   '<o que nao bateu> / linha 2: a lista do que tenho aberto', 14, 'Preciso que você diga',
   '[{"acao":"responder","texto":"💬 Responder"}]'),
  ('saude_jarvis', 'aviso', '🩺', 'Saude do Jarvis', false,
   'Falhei <N>x / linha 2: o que se perdeu (ou nao) e o log', 15, 'Saúde do Jarvis',
   '[]'),
  ('agenda_sumiu', 'aviso', '🔎', 'Sumiu da agenda', true,
   '*<evento>* sumiu do Calendar / linha 2: o que fiz e o que confirmar', 16, 'Sumiu da agenda',
   '[{"acao":"agenda","texto":"📅 Abrir agenda"},{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('numero_vigiado', 'aviso', '📈', 'Numero vigiado', false,
   '<numero> subiu pra <valor> / linha 2: quem tem o acesso', 17, 'Número vigiado',
   '[{"acao":"resolver","texto":"✅ Parar de vigiar"}]'),
  ('erro_meu', 'aviso', '🛠️', 'Erro meu, ja corrigido', false,
   'Eu errei <o que> e ja corrigi / linha 2: acao nenhuma', 18, 'Erro meu',
   '[]'),
  ('retomar', 'aviso', '▶️', 'Retomar trabalho', false,
   'Volte em <onde voce parou> / linha 2: o que falta voce fazer', 19, 'Retomar',
   '[{"acao":"resolver","texto":"✅ Finalizar aviso"},{"acao":"adiar","texto":"⏰ Me lembre em 1 hora"}]'),
  ('aviso_externo', 'aviso', '📢', 'Aviso de terceiros', false,
   '<o fato de fora> / linha 2: o que muda pra voce', 20, 'Aviso',
   '[{"acao":"responder","texto":"💬 Abrir conversa"},{"acao":"resolver","texto":"✅ Finalizar aviso"}]'),
  ('outro', 'aviso', '📌', 'Nao classificado', false,
   '<o fato> / linha 2: por que nao coube em nenhuma categoria', 99, 'Alerta',
   '[{"acao":"resolver","texto":"✅ Finalizar aviso"}]')
on conflict (subtipo) do nothing;

-- Precisa haver 20 categorias:
--   select subtipo, emoji, rotulo from jarvis.categorias order by ordem;

-- ---------- o prompt do cerebro na nuvem ----------
-- O corpo real e o conteudo de prompt-nuvem.md. Fica no banco (e
-- nao no arquivo da rotina) para voce mudar comportamento com um
-- update, em vez de reeditar as quatro rotinas na nuvem.
-- Antes de sobrescrever uma versao, copie a velha para
-- jarvis.prompt_historico (o jarvis_rpc le sem filtrar versao).
insert into jarvis.prompt (nome, versao, corpo)
values ('nuvem', 1, 'COLE AQUI O CONTEUDO DE prompt-nuvem.md')
on conflict (nome) do nothing;
