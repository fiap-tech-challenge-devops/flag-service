# Fase 4 — Instrumentação com OpenTelemetry

**Projeto:** ToggleMaster (FIAP — Fase 4)
**Escopo:** `requirements.txt`, `Dockerfile` e o uso de cursores no `app.py`

---

## Visão geral

Primeiro serviço instrumentado da Fase 4. O `flag-service` foi escolhido por ser Python — onde a instrumentação é *zero-code* — e por produzir, numa única requisição, três camadas de span: o servidor Flask, o cliente HTTP chamando o `auth-service` e a consulta ao PostgreSQL.

A premissa inicial era não tocar no `app.py`. **Ela não sobreviveu**: o span do banco não aparecia, e a causa estava em como o código criava os cursores. O achado está no Desafio 2 e é a parte que vale ser lida.

Validação feita localmente, com o Collector recebendo por OTLP e imprimindo com o exporter `debug`. Nada foi ao cluster neste passo.

---

## O desenho

```
flag-service ──OTLP(gRPC 4317)──► OTel Collector ──► exporter debug (local)
                                                 └─► Datadog, Prometheus, Loki (cluster, depois)
```

A aplicação conhece **um endereço** e nada mais. Trocar o destino, acrescentar um segundo ou mudar amostragem é configuração do Collector, sem rebuild de imagem e sem tocar nos cinco serviços.

Os três sinais percorrem pipelines independentes dentro do Collector — trace, métrica e log não compartilham caminho, o que permite destinos diferentes para cada um.

---

## Desafio 1 — instalar os pacotes num Dockerfile multi-stage

### O caminho da documentação não serve aqui

A documentação oficial recomenda `opentelemetry-bootstrap -a install`, que detecta as bibliotecas presentes e instala as instrumentações correspondentes.

Ele não funciona neste Dockerfile. O estágio de build instala com `--prefix=/install` (`Dockerfile:7`) e só esse diretório é copiado para o runtime (`Dockerfile:20`). O `bootstrap` chama `pip install` **sem** o prefixo, então os pacotes cairiam fora do que é copiado — e o runtime não tem `pip` para corrigir depois, porque ele é removido de propósito (`Dockerfile:14`).

### Correção

Pacotes fixados direto no `requirements.txt`, como o resto do arquivo:

```diff
 Flask==3.1.2
 psycopg2-binary==2.9.12
 gunicorn==23.0.0
 python-dotenv==1.0.1
 requests==2.32.5
+opentelemetry-distro[otlp]==0.66b1
+opentelemetry-instrumentation-flask==0.66b1
+opentelemetry-instrumentation-requests==0.66b1
+opentelemetry-instrumentation-psycopg2==0.66b1
+opentelemetry-instrumentation-logging==0.66b1
```

O extra `[otlp]` traz o exporter na versão correspondente, evitando casar à mão o `0.66b1` das instrumentações com o `1.x` do SDK.

> **Sobre o `0.66b1`:** API e SDK do OpenTelemetry são `1.x` estáveis; as bibliotecas de **instrumentação** seguem numeração própria, `0.xxbY`, e o sufixo `b` é a norma do ecossistema, não um beta instável avulso.

### Ativação

```diff
-CMD ["gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
+CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
```

O console script fica em `/usr/local/bin` pela cópia do `--prefix`, já no PATH. O gunicorn roda com **1 worker** (default, sem `--preload`), que é o cenário suportado pelo wrapper — com múltiplos workers seria preciso inicializar no hook `post_fork`, porque os componentes do SDK usam threads de background que não sobrevivem ao fork.

---

## Desafio 2 — o span do banco que não aparecia

### O sintoma

Com tudo instalado e o serviço respondendo, o Collector recebia spans de Flask e de `requests`, mas **nenhum de banco**:

```
InstrumentationScope opentelemetry.instrumentation.flask 0.66b1
InstrumentationScope opentelemetry.instrumentation.requests 0.66b1
```

Nenhum erro, nenhum aviso no log do serviço. Silêncio.

### A hipótese errada

A suspeita inicial era o `psycopg2-binary`: historicamente, o instrumentador procurava a distribuição `psycopg2` e registrava `DependencyConflict`, pulando a instrumentação.

Descartada na verificação. Na versão atual, o próprio instrumentador declara o pacote binário como dependência válida:

```
instruments: ('psycopg2-binary >= 2.7.3.1',)
instrument() OK
```

### A causa real

O instrumentador do psycopg2 funciona **substituindo o `cursor_factory` da conexão** por uma fábrica própria, que embrulha a original:

```python
original_cursor_factory = connection.cursor_factory
connection.cursor_factory = _new_cursor_factory(base_factory=original_cursor_factory, ...)
```

Quem chama `conn.cursor()` sem argumentos recebe o cursor instrumentado. Mas o `app.py` fazia isto, em quatro lugares:

```python
cur = conn.cursor(cursor_factory=RealDictCursor)
```

Passar a fábrica explicitamente **sobrescreve a fábrica instrumentada** com a original. O cursor volta a ser o cru e nenhum span nasce.

Comprovado com um A/B no mesmo processo, mesma conexão:

```
>>> connect patched? FunctionWrapper
A (cursor padrão)      → span "SELECT", db.statement: "SELECT 1"
B (RealDictCursor)     → nenhum span
```

### Correção

A instrumentação **também** aceita a fábrica declarada na conexão — nesse caso ela detecta, embrulha e preserva o comportamento:

```diff
-    pool = SimpleConnectionPool(1, 5, dsn=DATABASE_URL)
+    pool = SimpleConnectionPool(1, 5, dsn=DATABASE_URL, cursor_factory=RealDictCursor)
```

```diff
-        cur = conn.cursor(cursor_factory=RealDictCursor)
+        cur = conn.cursor()
```

Quatro ocorrências (`app.py:90, 120, 139, 182`). O handler de DELETE (`app.py:208`) já usava `conn.cursor()` e passa a receber `RealDictCursor`; ele só lê `cur.rowcount`, então nada muda para ele.

### Por que isso importa além deste serviço

A auto-instrumentação não é mágica: ela depende de o código usar a biblioteca pelo caminho convencional. Quando o código passa por cima de um ponto de extensão — aqui, a fábrica de cursores — **a instrumentação desaparece em silêncio**, sem erro e sem aviso.

É a mesma classe de problema que a Fase 4 existe para combater: o sistema parece observado, mas tem um ponto cego. A diferença é que, desta vez, o ponto cego foi encontrado antes de virar incidente.

---

## Resumo das mudanças

| Arquivo | Mudança | Motivo |
|---|---|---|
| `requirements.txt` | 5 pacotes OTel fixados | `bootstrap` não funciona com o prefixo do build multi-stage |
| `Dockerfile` | `CMD` prefixado com `opentelemetry-instrument` | Ativa a instrumentação sem tocar no código |
| `app.py` | `cursor_factory` movido para o pool | Sem isso, o span de banco não nasce |
| `app.py` | 4× `conn.cursor(cursor_factory=…)` → `conn.cursor()` | Deixa de sobrescrever a fábrica instrumentada |

Nenhuma lógica de negócio foi alterada. As respostas da API continuam em dicionário.

### Configuração

As variáveis vivem no ambiente, nunca no código:

```
OTEL_SERVICE_NAME=flag-service
OTEL_RESOURCE_ATTRIBUTES=service.namespace=togglemaster,deployment.environment.name=local
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_LOGS_EXPORTER=otlp
OTEL_PYTHON_LOG_CORRELATION=true
OTEL_PYTHON_FLASK_EXCLUDED_URLS=health
```

`deployment.environment.name` é o nome atual do atributo; `deployment.environment` está depreciado desde o semconv 1.27. O `EXCLUDED_URLS` tira o `/health`, que o healthcheck bate a cada 30s.

No cluster, essas variáveis virão do chart base, com `OTEL_SERVICE_NAME` derivado do nome do release.

---

## Validação

Ambiente: `togglemaster-platform-legacy`, com Collector `otel/opentelemetry-collector-contrib:0.162.0` e exporter `debug`.

### Antes e depois

| Escopo emitindo spans | Antes da correção | Depois |
|---|---|---|
| `instrumentation.flask` | sim | sim |
| `instrumentation.requests` | sim | sim |
| `instrumentation.psycopg2` | **não** | sim |

### A árvore completa, para um `GET /flags`

```
GET /flags            Kind: Server   ID: 9f1f374c…   Parent: (raiz)
├── GET               Kind: Client   Parent: 9f1f374c…      → auth-service
└── SELECT            Kind: Client   Parent: 9f1f374c…
      db.system:    postgresql
      db.name:      flags_db
      db.statement: SELECT * FROM flags ORDER BY name
```

Os três spans compartilham o mesmo `Trace ID`. Os dois filhos apontam para o mesmo pai, porque ambos ocorrem dentro da requisição: primeiro a validação da chave, depois a consulta.

### Duas escolhas do padrão que aparecem no dado

```
Name: GET /flags/<string:name>     http.route: /flags/<string:name>
db.statement: SELECT * FROM flags WHERE name = %s
```

O nome do span é a **rota**, não a URL — se fosse a URL, cada flag viraria um endpoint diferente no APM e não haveria agregação. E o `db.statement` preserva o `%s` sem interpolar o valor, o que evita vazar dado de usuário na telemetria e mantém a query agregável.

### Log correlacionado

```
Body: Str(Flag 'enable-new-dashboard' criada com sucesso.)
SeverityText: INFO
Attributes:
     -> otelTraceID: Str(309c4650cb3c7014029bf14c0cfd1a72)
     -> otelSpanID:  Str(10171f94899565f0)
```

O `otelTraceID` do log é o mesmo `Trace ID` do span da requisição. É isso que permite saltar de um trace lento para os logs exatos daquela execução — e o `app.py` não sabe que isso acontece.

### O que ainda falta no trace

O span `GET` (Client) mostra a chamada saindo para o `auth-service`, mas **não existe o lado servidor dela**: o trace morre na borda. O `auth-service` ainda não está instrumentado, e fechar essa ponte é o próximo passo.

---

## O que não foi feito

**Log em JSON.** Localmente o log trafega por OTLP, onde o contexto de trace viaja preso ao registro e não depende do formato do texto. Em produção o caminho será stdout coletado pelo `filelog`, e aí o JSON passa a ser obrigatório — é o que permite promover `trace_id` e `span_id` a campos. Entra junto com o Collector no cluster.

**Métricas de negócio.** As métricas de requisição vêm de graça com a instrumentação do Flask. Contadores próprios, como taxa de acerto de cache, exigem código e não entraram aqui.

**Amostragem.** Está em 100%, que é desvio consciente da recomendação para produção. No volume da demonstração, é o que garante que o trace procurado exista.

---

## Nota de bastidor — o lint que quebrou sozinho

O primeiro PR desta instrumentação reprovou no job `Linter`, e **não era o código**:

```
ruff failed
  Cause: Failed to load configuration `ruff.toml`
  Cause: Required version `>=0.16, <0.17` does not match the running version `0.17.0`
```

A esteira instalava `ruff` sem fixar versão. Quando a 0.17.0 saiu, o `required-version` passou a recusar a própria ferramenta que a esteira instalava, e o lint morreu ao carregar a configuração — sem analisar uma linha. Qualquer PR nos três serviços Python quebraria igual naquele dia, e a pendência já estava prevista em [`03-lint-ruff.md`](03-lint-ruff.md).

Corrigido pela [v2.2.5](https://github.com/fiap-tech-challenge-devops/reusable-workflows/releases/tag/v2.2.5) do `reusable-workflows`, que fixou `ruff`, `bandit`, `pytest` e `golangci-lint`, mais a ampliação do `required-version` aqui. Com o lint voltando a rodar de verdade: `All checks passed!`.
