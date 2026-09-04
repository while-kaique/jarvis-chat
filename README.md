# Jarvis Chat

Um agente que lê o seu Google Chat e o seu Google Calendar, descobre o que virou
compromisso, e te avisa **na hora certa** num espaço privado do Chat — sem você precisar
pedir. Cancela o alerta sozinho quando você muda de ideia, e lembra de assunto de um mês
atrás.

```
                 +---------------------------------------------+
  Google Chat -->|  CEREBRO - pensa e agenda                   |
  Google Cal. -->|  a) rotina na nuvem, 1x/hora (o piso)       |
                 |  b) escuta.ps1 local, 15 min (caminho rapido)|
                 +------------------+--------------------------+
                                    |  grava em jarvis.compromissos
                                    v
                 +---------------------------------------------+
  Google Chat <--|  ENTREGA - cron dentro do Supabase, 5 min    |
                 |  posta pelo webhook do espaco. Zero LLM.     |
                 +---------------------------------------------+
```

## Comece aqui

👉 **[COMO_INSTALAR.md](COMO_INSTALAR.md)** — do zero ao ar, em 8 passos.

A referência técnica completa, com todo o SQL, está em
**[CONSTRUIR.md](CONSTRUIR.md)**.

## As três ideias que sustentam isso

1. **A entrega mora no banco.** É o único relógio que acerta o minuto e não depende de
   máquina ligada. Um tick de 15 min cai em 10:15 e 10:30 — nunca acerta "10 min antes da
   reunião das 10:30".
2. **O cérebro nunca posta.** Tudo que precisa chegar até você é uma linha em
   `jarvis.compromissos` com a hora do alerta. Uma porta de saída só, e deduplicação de
   graça pelo `fingerprint`.
3. **Toda escrita passa por função.** Nada de `insert` na mão. É o que garante citação de
   origem obrigatória e o cancelamento automático do alerta que virou zumbi.

## Precisa de

Conta Google (Chat + Calendar), um projeto no [Supabase](https://supabase.com) (plano free
serve), e o [Claude Code](https://claude.com/claude-code). O cérebro local de 15 min pede
Windows, mas é opcional — sem ele o agente roda de hora em hora pela nuvem.

## Privacidade

**Este repositório não contém dado de ninguém.** Todo valor pessoal aparece como
placeholder (`SEU_SPACE_ID`, `SEU_USER_ID`, `SEU_PROJECT_REF`, `voce@suaempresa.com`).
Você descobre os seus na instalação e é o único que os conhece — a sua memória fica no
**seu** Supabase, e o webhook do seu espaço no Vault dele.
