' Lancador silencioso. Existe por um motivo chato do Windows:
' o Agendador executando powershell.exe cria a janela de console ANTES de o
' PowerShell poder se esconder, entao -WindowStyle Hidden nao resolve. Rodar a
' tarefa como S4U ("esteja o usuario conectado ou nao") resolveria, mas exige
' admin. Este .vbs resolve sem admin: o terceiro argumento do Run e o estilo de
' janela, e 0 = oculta.
'
' Uso:  wscript.exe oculto.vbs "<caminho do .ps1>"

Dim sh, ps1
Set sh = CreateObject("WScript.Shell")
ps1 = WScript.Arguments(0)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
