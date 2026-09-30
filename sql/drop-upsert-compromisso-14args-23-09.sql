-- 23/09/2026 — upsert_compromisso voltou a ter duas versoes (14 e 16 argumentos).
-- Com as duas, qualquer chamada com 14 argumentos ou menos da erro "is not unique":
-- o vigiar() (aviso "cerebro do Jarvis parado") nao consegue gravar o alerta.
-- A de 16 faz tudo o que a de 14 faz, mais subtipo e motivo de urgencia.

drop function jarvis.upsert_compromisso(text, text, timestamptz, text, text, text,
  timestamptz, text, text, text, timestamptz, text, text, text);
