# Containerização — flag-service

**Projeto:** ToggleMaster (FIAP — Fase 2) · **Data:** Maio/2026

Alteração em `requirements.txt` para o container iniciar.

## Desafio 1 — Incompatibilidade entre Flask 2.2.2 e Werkzeug 3.x

**Problema:** `requirements.txt` não pinnava a versão do Werkzeug. O pip resolveu `Werkzeug==3.1.8` (última disponível), que removeu `url_quote` de `werkzeug.urls`. O Flask 2.2.2 importa esse símbolo na inicialização.

**Erro:**
```
ImportError: cannot import name 'url_quote' from 'werkzeug.urls'
  File "/usr/local/lib/python3.9/site-packages/flask/app.py", line 30, in <module>
    from werkzeug.urls import url_quote
```

**Correção:** adicionado pin `Werkzeug<3.0` em `requirements.txt` para forçar a última versão 2.x (resolvida como 2.3.8).

```diff
 Flask==2.2.2
+Werkzeug<3.0
 psycopg2-binary==2.9.5
```
