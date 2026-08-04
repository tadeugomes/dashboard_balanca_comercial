# Pipeline Mensal Comex Stat — Plano de Implementação

> **Para trabalhadores agênticos:** SUB-SKILL OBRIGATÓRIA: use `superpowers:subagent-driven-development` (recomendado) ou `superpowers:executing-plans` para implementar este plano tarefa a tarefa. Os passos usam sintaxe de checkbox (`- [ ]`) para acompanhamento.

**Objetivo:** Reconstruir o ETL perdido do Comex Stat, dinamizar o ano de referência do dashboard e automatizar a atualização mensal via GitHub Actions, mantendo os parquets fora do versionamento.

**Arquitetura:** Um pipeline em R que consulta `Last-Modified` dos CSVs anuais do MDIC, baixa apenas o que mudou, agrega via DuckDB para dois parquets com schema idêntico ao atual, e só publica se passar por um portão de validação. O GitHub Actions executa isso mensalmente e faz o deploy no shinyapps.io.

**Stack:** R 4.4.2, DuckDB (via pacote `duckdb`), Arrow, testthat, GitHub Actions, Quarto/Shiny, rsconnect.

**Spec:** `docs/superpowers/specs/2026-08-04-pipeline-mensal-comex-design.md`

## Restrições globais

Estes valores valem para **todas** as tarefas e foram verificados na fonte em 2026-08-04. Nenhum pode ser alterado sem revisar a spec.

- **Schema de saída** (ordem e tipos exatos): `no_pais` string, `no_uf` string, `no_regiao` string, `no_cuci_grupo` string, `ano` int64, `mes` int64, `nome_mes` string, `peso_liquido_kg` double, `valor_fob_dolar` double.
- **Arquivos de saída:** `dados/ncm_exportacao_agrupado.parquet` e `dados/ncm_importacao_agrupado.parquet`.
- **`nome_mes`** usa exatamente estes rótulos, indexados por `mes` de 1 a 12:
  `jan.`, `fev.`, `mar.`, `abr.`, `maio`, `jun.`, `jul.`, `ago.`, `set.`, `out.`, `nov.`, `dez.`
  Atenção: `maio` **não** leva ponto; todos os outros levam.
- **De-para de `no_regiao`** (a fonte traz caixa alta sem acento; o dashboard filtra pelos valores da direita):
  | `UF.csv` → `NO_REGIAO` | saída |
  |---|---|
  | `REGIAO NORTE` | `Norte` |
  | `REGIAO NORDESTE` | `Nordeste` |
  | `REGIAO SUDESTE` | `Sudeste` |
  | `REGIAO SUL` | `Sul` |
  | `REGIAO CENTRO OESTE` | `Centro-Oeste` |
  | qualquer outro (`REGIAO NAO DECLARADA`, `CONSUMO DE BORDO`, `MERCADORIA NACIONALIZADA`, `REEXPORTACAO`) | `Não Declarada` |

  O hífen em `Centro-Oeste` é adicionado por nós — a fonte escreve `CENTRO OESTE` sem hífen.
- **Sem valores nulos na saída.** `UF.csv` cobre todos os códigos especiais (`EX`, `CB`, `MN`, `RE`, `ED`, `ND`, `ZN`), então o join de UF sempre resolve. NCMs sem correspondência em `NCM_CUCI.csv` recebem **string vazia**, não `NULL` — o parquet atual tem 88 linhas assim (0,0001% do valor).
- **Codificação:** `{EXP,IMP}_<ano>.csv` são ASCII; as tabelas auxiliares são **ISO-8859-1** e devem ser convertidas para UTF-8 antes de qualquer leitura pelo DuckDB.
- **Formato CSV da fonte:** delimitador `;`, aspas duplas, cabeçalho na primeira linha.
- **Ano inicial da série:** 2014.
- **Idioma:** todo código, comentário, mensagem de erro e log em português.
- **Comando de teste:** `Rscript -e 'testthat::test_dir("tests/testthat")'`

---

## Estrutura de arquivos

| Arquivo | Responsabilidade |
|---|---|
| `etl/R/fontes.R` | Catálogo de URLs e consulta de `Last-Modified`. Não baixa nada, não conhece NCM. |
| `etl/R/baixar.R` | Download com retry e conversão de encoding. Não sabe o que os arquivos contêm. |
| `etl/R/transformar.R` | Executa o SQL de um ano. Não decide *quais* anos. |
| `etl/sql/agregado_ncm.sql` | Joins e agregação. Única fonte da verdade sobre o schema. |
| `etl/R/consolidar.R` | Une parquets anuais nos dois finais. |
| `etl/R/validar.R` | Portão de sanidade. Não sabe de onde veio o arquivo — testável com dados sintéticos. |
| `etl/R/estado.R` | Leitura e escrita de `etl/estado.json`. |
| `etl/run.R` | Orquestrador. Única parte que conhece o fluxo completo. |
| `tests/testthat/test-*.R` | Um arquivo por módulo. |
| `.github/workflows/atualizar-dados.yml` | Agendamento, cache, deploy. |

Cada módulo é testável isoladamente: `validar.R` recebe um caminho de parquet e devolve um relatório, sem tocar em rede.

---

## Task 1: Reconciliar o Git e preservar as duas variantes

**Contexto para quem executa:** o clone local está divergente do GitHub — 1 commit à frente (a spec) e 2 atrás. Pior: há mudanças não commitadas nos mesmos arquivos que os commits remotos alteram, e elas são **opostas** (local remove a paralelização; remoto a adiciona). O `bundleId` no `.dcf` prova que **a versão local é a que está no ar** no shinyapps.io. Portanto a versão local vence os conflitos, e a remota é preservada num branch para ser medida na Task 9.

**Files:**
- Modify: `.gitignore`
- Preserve: branch novo `paralelizacao`

**Interfaces:**
- Consumes: nada.
- Produces: branch `master` convergido com `origin/master`; branch `paralelizacao` apontando para o antigo `origin/master`.

- [ ] **Step 1: Fazer backup espelhado antes de qualquer coisa**

```bash
cd /Users/tgt/Documents/GitHub/dashboard_balanca_comercial
git clone --mirror . ../backup-dashboard-$(date +%Y%m%d).git
tar czf ../backup-worktree-$(date +%Y%m%d).tar.gz --exclude=.git .
ls -la ../backup-dashboard-*.git ../backup-worktree-*.tar.gz
```

Esperado: ambos existem e o `.tar.gz` tem mais de 100 MB. **Não prossiga sem isso.**

- [ ] **Step 2: Preservar a variante remota num branch nomeado**

```bash
git branch paralelizacao origin/master
git log paralelizacao -1 --format='%h %s'
```

Esperado: `96d07a5 paralelização`

- [ ] **Step 3: Commitar o estado local que está no ar**

```bash
git add -A
git commit -m "chore: estado local publicado no shinyapps.io (leitura preguiçosa via Arrow)"
```

- [ ] **Step 4: Mesclar o remoto mantendo a versão local nos conflitos**

```bash
git merge origin/master
```

Esperado: conflitos em `dashboard.qmd`, `dashboard.html`, `renv.lock`, `balanca_comercial.dcf`. Resolva mantendo a versão local em todos:

```bash
git checkout --ours dashboard.qmd dashboard.html renv.lock \
  rsconnect/documents/dashboard.qmd/shinyapps.io/observatorioportuario/balanca_comercial.dcf
git add -A
git commit -m "merge: reconcilia origin/master preservando a variante em produção

A variante com future/furrr fica preservada no branch 'paralelizacao'
para medição de memória na Task 9."
```

- [ ] **Step 5: Verificar que a convergência ocorreu**

```bash
git rev-list --left-right --count origin/master...master
```

Esperado: `0	N` (zero commits só no remoto; N commits locais a enviar).

- [ ] **Step 6: Impedir que os parquets voltem ao versionamento**

Acrescente ao final de `.gitignore`:

```
# Dados gerados pelo ETL — publicados como asset de Release, nunca versionados
dados/*.parquet
```

- [ ] **Step 7: Remover os parquets do índice mantendo-os em disco**

```bash
git rm --cached dados/ncm_exportacao_agrupado.parquet dados/ncm_importacao_agrupado.parquet
git status --short dados/
```

Esperado: duas linhas `D` no índice; os arquivos continuam presentes em `ls dados/`.

- [ ] **Step 8: Commitar e enviar**

```bash
git add .gitignore
git commit -m "chore: retira os parquets do versionamento

Passam a ser gerados pelo ETL e distribuídos como asset de Release."
git push origin master
git push origin paralelizacao
```

---

## Task 2: Catálogo de fontes

**Files:**
- Create: `etl/R/fontes.R`
- Test: `tests/testthat/test-fontes.R`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `COMEX_BASE` — string, URL base.
  - `fontes_anuais(ano_min = 2014L, ano_max)` → `data.frame(chave, fluxo, ano, url)`, com `chave` no formato `"EXP_2014"`.
  - `fontes_auxiliares()` → `data.frame(chave, url)` para `PAIS`, `UF`, `NCM`, `NCM_CUCI`.
  - `metadados_remotos(url)` → `list(last_modified = character(1), content_length = character(1))`.

- [ ] **Step 1: Escrever o teste que falha**

Crie `tests/testthat/test-fontes.R`:

```r
source(file.path("..", "..", "etl", "R", "fontes.R"))

test_that("fontes_anuais gera duas linhas por ano, uma por fluxo", {
  f <- fontes_anuais(ano_min = 2014L, ano_max = 2016L)
  expect_equal(nrow(f), 6L)
  expect_setequal(unique(f$fluxo), c("exportacao", "importacao"))
  expect_setequal(unique(f$ano), 2014:2016)
})

test_that("fontes_anuais monta a URL e a chave no formato do MDIC", {
  f <- fontes_anuais(ano_min = 2025L, ano_max = 2025L)
  exp <- f[f$fluxo == "exportacao", ]
  expect_equal(exp$chave, "EXP_2025")
  expect_equal(
    exp$url,
    "https://balanca.economia.gov.br/balanca/bd/comexstat-bd/ncm/EXP_2025.csv"
  )
  imp <- f[f$fluxo == "importacao", ]
  expect_equal(imp$chave, "IMP_2025")
})

test_that("fontes_auxiliares lista as quatro tabelas necessárias", {
  a <- fontes_auxiliares()
  expect_setequal(a$chave, c("PAIS", "UF", "NCM", "NCM_CUCI"))
  expect_true(all(grepl("^https://.*/tabelas/[A-Z_]+\\.csv$", a$url)))
})

test_that("fontes_anuais rejeita intervalo invertido", {
  expect_error(fontes_anuais(2020L, 2015L), "ano_max")
})
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "fontes")'`
Esperado: FAIL — `cannot open file '../../etl/R/fontes.R'`

- [ ] **Step 3: Implementar**

Crie `etl/R/fontes.R`:

```r
# Catálogo das fontes públicas do Comex Stat (MDIC).
# Este módulo apenas descreve onde os arquivos estão e qual a versão remota
# deles. Não baixa nada e não conhece o conteúdo dos arquivos.

COMEX_BASE <- "https://balanca.economia.gov.br/balanca/bd"

# Prefixo do arquivo anual conforme o fluxo comercial.
PREFIXO_FLUXO <- c(exportacao = "EXP", importacao = "IMP")

# Tabelas auxiliares necessárias para os joins. VIA, URF e NCM_CGCE existem na
# fonte mas não entram no schema de saída.
AUXILIARES <- c("PAIS", "UF", "NCM", "NCM_CUCI")

fontes_anuais <- function(ano_min = 2014L,
                          ano_max = as.integer(format(Sys.Date(), "%Y"))) {
  ano_min <- as.integer(ano_min)
  ano_max <- as.integer(ano_max)
  if (ano_max < ano_min) {
    stop("ano_max (", ano_max, ") é anterior a ano_min (", ano_min, ")")
  }

  grade <- expand.grid(
    ano = seq(ano_min, ano_max),
    fluxo = names(PREFIXO_FLUXO),
    stringsAsFactors = FALSE
  )

  chave <- paste0(PREFIXO_FLUXO[grade$fluxo], "_", grade$ano)

  data.frame(
    chave = unname(chave),
    fluxo = grade$fluxo,
    ano = grade$ano,
    url = paste0(COMEX_BASE, "/comexstat-bd/ncm/", chave, ".csv"),
    stringsAsFactors = FALSE
  )
}

fontes_auxiliares <- function() {
  data.frame(
    chave = AUXILIARES,
    url = paste0(COMEX_BASE, "/tabelas/", AUXILIARES, ".csv"),
    stringsAsFactors = FALSE
  )
}

# Consulta a versão remota de um arquivo sem baixá-lo. Devolve strings vazias
# quando o servidor não informa o cabeçalho, o que força o reprocessamento —
# preferimos trabalho extra a dado desatualizado.
metadados_remotos <- function(url) {
  h <- curl::new_handle(nobody = TRUE, followlocation = TRUE)
  resp <- curl::curl_fetch_memory(url, handle = h)

  if (resp$status_code != 200L) {
    stop("HTTP ", resp$status_code, " ao consultar ", url)
  }

  cabecalhos <- curl::parse_headers_list(resp$headers)

  list(
    last_modified = as.character(cabecalhos[["last-modified"]] %||% ""),
    content_length = as.character(cabecalhos[["content-length"]] %||% "")
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "fontes")'`
Esperado: PASS — 4 testes.

- [ ] **Step 5: Commit**

```bash
git add etl/R/fontes.R tests/testthat/test-fontes.R
git commit -m "feat(etl): catálogo de fontes do Comex Stat"
```

---

## Task 3: Download com retry e conversão de encoding

**Files:**
- Create: `etl/R/baixar.R`
- Test: `tests/testthat/test-baixar.R`

**Interfaces:**
- Consumes: nada de Task 2 (proposital — este módulo recebe URLs prontas).
- Produces:
  - `baixar_arquivo(url, destino, tentativas = 3L)` → `destino` (invisível). Erro após esgotar tentativas.
  - `converter_para_utf8(caminho)` → `caminho` (invisível). Converte ISO-8859-1 → UTF-8 no lugar.

- [ ] **Step 1: Escrever o teste que falha**

Crie `tests/testthat/test-baixar.R`:

```r
source(file.path("..", "..", "etl", "R", "baixar.R"))

test_that("converter_para_utf8 traduz acentos de ISO-8859-1", {
  origem <- tempfile(fileext = ".csv")
  # Grava "Índia" e "África" em latin1, como o MDIC publica.
  con <- file(origem, open = "wb")
  writeBin(iconv("NO_PAIS\nÍndia\nÁfrica do Sul\n", "UTF-8", "ISO-8859-1",
                 toRaw = TRUE)[[1]], con)
  close(con)

  converter_para_utf8(origem)

  linhas <- readLines(origem, encoding = "UTF-8")
  expect_equal(linhas[2], "Índia")
  expect_equal(linhas[3], "África do Sul")
  expect_false(any(grepl("�", linhas)))
})

test_that("converter_para_utf8 é idempotente em arquivo já ASCII", {
  origem <- tempfile(fileext = ".csv")
  writeLines(c("CO_ANO;CO_MES", "2026;01"), origem)
  antes <- readLines(origem)

  converter_para_utf8(origem)

  expect_equal(readLines(origem), antes)
})

test_that("baixar_arquivo desiste após esgotar as tentativas", {
  destino <- tempfile(fileext = ".csv")
  expect_error(
    baixar_arquivo("https://balanca.economia.gov.br/inexistente-xyz.csv",
                   destino, tentativas = 2L),
    "Falha ao baixar"
  )
})
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "baixar")'`
Esperado: FAIL — arquivo `baixar.R` não existe.

- [ ] **Step 3: Implementar**

Crie `etl/R/baixar.R`:

```r
# Download dos arquivos da fonte e normalização de codificação.
# Este módulo não sabe o que os arquivos contêm — recebe URL e destino.

# Baixa com repetição e espera crescente. O servidor do MDIC é lento e derruba
# conexões em arquivos grandes; desistir na primeira falha tornaria o pipeline
# não confiável.
baixar_arquivo <- function(url, destino, tentativas = 3L) {
  dir.create(dirname(destino), recursive = TRUE, showWarnings = FALSE)

  for (tentativa in seq_len(tentativas)) {
    parcial <- paste0(destino, ".parcial")
    resultado <- try(
      curl::curl_download(url, parcial, quiet = TRUE, mode = "wb"),
      silent = TRUE
    )

    if (!inherits(resultado, "try-error") && file.exists(parcial) &&
        file.size(parcial) > 0) {
      file.rename(parcial, destino)
      return(invisible(destino))
    }

    unlink(parcial)
    if (tentativa < tentativas) {
      espera <- 5 * tentativa
      message("Tentativa ", tentativa, " falhou para ", basename(url),
              "; nova tentativa em ", espera, "s")
      Sys.sleep(espera)
    }
  }

  stop("Falha ao baixar ", url, " após ", tentativas, " tentativas")
}

# As tabelas auxiliares vêm em ISO-8859-1 e é delas que saem "Índia",
# "África do Sul" e os nomes dos grupos CUCI. O DuckDB assume UTF-8, então sem
# esta conversão os acentos chegariam corrompidos ao dashboard — falha que
# nenhuma validação numérica detectaria.
converter_para_utf8 <- function(caminho) {
  bruto <- readBin(caminho, "raw", file.size(caminho))
  texto <- iconv(rawToChar(bruto), from = "ISO-8859-1", to = "UTF-8")

  if (is.na(texto)) {
    stop("Não foi possível converter ", caminho, " de ISO-8859-1 para UTF-8")
  }

  con <- file(caminho, open = "wb")
  on.exit(close(con))
  writeBin(charToRaw(texto), con)

  invisible(caminho)
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "baixar")'`
Esperado: PASS — 3 testes. O terceiro faz uma requisição real e leva ~15s por causa das esperas.

- [ ] **Step 5: Commit**

```bash
git add etl/R/baixar.R tests/testthat/test-baixar.R
git commit -m "feat(etl): download com retry e conversão de encoding"
```

---

## Task 4: SQL de agregação e transformação por ano

**Contexto:** esta é a tarefa de maior risco do plano. O SQL precisa reproduzir **exatamente** o schema e os rótulos do parquet atual, incluindo o de-para de região e os rótulos abreviados de mês listados nas Restrições Globais. Um erro aqui produz números plausíveis e rótulos errados.

**Files:**
- Create: `etl/sql/agregado_ncm.sql`
- Create: `etl/R/transformar.R`
- Test: `tests/testthat/test-transformar.R`

**Interfaces:**
- Consumes: nada dos módulos anteriores.
- Produces:
  - `transformar_ano(csv_dados, dir_auxiliares, destino_parquet)` → `destino_parquet` (invisível).

- [ ] **Step 1: Adicionar duckdb e testthat ao renv**

```bash
Rscript -e 'renv::install(c("duckdb", "testthat"))'
Rscript -e 'renv::snapshot(prompt = FALSE)'
Rscript -e 'packageVersion("duckdb")'
```

Esperado: uma versão 1.x é impressa.

- [ ] **Step 2: Escrever o teste que falha**

Crie `tests/testthat/test-transformar.R`. Ele monta CSVs sintéticos minúsculos cobrindo os casos difíceis: uma UF real, um código especial (`CB`) e um NCM sem correspondência em CUCI.

```r
source(file.path("..", "..", "etl", "R", "transformar.R"))

# O testthat roda a partir de tests/testthat, então o default de CAMINHO_SQL
# (relativo à raiz do projeto) não resolveria daqui.
SQL_TESTE <- file.path("..", "..", "etl", "sql", "agregado_ncm.sql")

# Monta um conjunto mínimo de arquivos no formato exato do MDIC.
montar_fixture <- function() {
  dir <- tempfile("fixture")
  dir.create(file.path(dir, "aux"), recursive = TRUE)

  writeLines(c(
    '"CO_ANO";"CO_MES";"CO_NCM";"CO_UNID";"CO_PAIS";"SG_UF_NCM";"CO_VIA";"CO_URF";"QT_ESTAT";"KG_LIQUIDO";"VL_FOB"',
    '"2025";"01";"10011000";"10";"063";"MA";"01";"0817800";100;200;3000',
    '"2025";"01";"10011000";"10";"063";"MA";"01";"0817800";50;100;1000',
    '"2025";"05";"99999999";"10";"063";"CB";"01";"0817800";10;20;70'
  ), file.path(dir, "EXP_2025.csv"))

  writeLines(c(
    '"CO_PAIS";"CO_PAIS_ISON3";"CO_PAIS_ISOA3";"NO_PAIS";"NO_PAIS_ING";"NO_PAIS_ESP"',
    '"063";"076";"BRA";"Índia";"India";"India"'
  ), file.path(dir, "aux", "PAIS.csv"))

  writeLines(c(
    '"CO_UF";"SG_UF";"NO_UF";"NO_REGIAO"',
    '"21";"MA";"Maranhão";"REGIAO NORDESTE"',
    '"94";"CB";"Consumo de Bordo";"CONSUMO DE BORDO"'
  ), file.path(dir, "aux", "UF.csv"))

  writeLines(c(
    '"CO_NCM";"CO_UNID";"CO_SH6";"CO_PPE";"CO_PPI";"CO_FAT_AGREG";"CO_CUCI_ITEM";"CO_CGCE_N3";"CO_SIIT";"CO_ISIC_CLASSE";"CO_EXP_SUBSET";"NO_NCM_POR";"NO_NCM_ESP";"NO_NCM_ING"',
    '"10011000";"10";"100110";"0";"0";"1";"04110";"210";"1";"0111";"0";"Trigo";"Trigo";"Wheat"',
    '"99999999";"10";"999999";"0";"0";"1";"99999";"999";"1";"9999";"0";"Outros";"Otros";"Other"'
  ), file.path(dir, "aux", "NCM.csv"))

  writeLines(c(
    '"CO_CUCI_ITEM";"NO_CUCI_ITEM";"CO_CUCI_SUB";"NO_CUCI_SUB";"CO_CUCI_GRUPO";"NO_CUCI_GRUPO";"CO_CUCI_DIVISAO";"NO_CUCI_DIVISAO";"CO_CUCI_SEC";"NO_CUCI_SEC"',
    '"04110";"Trigo";"041";"Trigo";"041";"Trigo e centeio, não moídos";"04";"Cereais";"0";"Alimentos"'
  ), file.path(dir, "aux", "NCM_CUCI.csv"))

  dir
}

ler_saida <- function(caminho) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s') ORDER BY mes",
                               caminho))
}

test_that("transformar_ano agrega e produz o schema exato do dashboard", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")

  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  expect_equal(
    names(saida),
    c("no_pais", "no_uf", "no_regiao", "no_cuci_grupo",
      "ano", "mes", "nome_mes", "peso_liquido_kg", "valor_fob_dolar")
  )
  # As duas linhas de janeiro compartilham todas as chaves e devem somar.
  expect_equal(nrow(saida), 2L)
  expect_equal(saida$valor_fob_dolar[1], 4000)
  expect_equal(saida$peso_liquido_kg[1], 300)
})

test_that("transformar_ano normaliza a região e preserva acentos", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  expect_equal(saida$no_regiao[1], "Nordeste")   # de "REGIAO NORDESTE"
  expect_equal(saida$no_uf[1], "Maranhão")
  expect_equal(saida$no_pais[1], "Índia")
})

test_that("códigos especiais de UF caem em Não Declarada", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  linha <- saida[saida$mes == 5, ]
  expect_equal(linha$no_uf, "Consumo de Bordo")
  expect_equal(linha$no_regiao, "Não Declarada")  # de "CONSUMO DE BORDO"
})

test_that("NCM sem grupo CUCI recebe string vazia, nunca NA", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  linha <- saida[saida$mes == 5, ]
  expect_equal(linha$no_cuci_grupo, "")
  expect_false(anyNA(saida))
})

test_that("nome_mes usa os rótulos abreviados do dashboard", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  expect_equal(saida$nome_mes[saida$mes == 1], "jan.")
  expect_equal(saida$nome_mes[saida$mes == 5], "maio")  # sem ponto
})
```

- [ ] **Step 3: Rodar e confirmar que falha**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "transformar")'`
Esperado: FAIL — `transformar.R` não existe.

- [ ] **Step 4: Escrever o SQL**

Crie `etl/sql/agregado_ncm.sql`. Os marcadores `{{csv_dados}}` e `{{dir_aux}}` são substituídos por `transformar.R`.

```sql
-- Agrega um arquivo anual do Comex Stat no schema consumido pelo dashboard.
-- Os rótulos de mês e o de-para de região são fixos de propósito: o dashboard
-- filtra por esses valores literais.
COPY (
  WITH dados AS (
    SELECT
      CAST(CO_ANO AS BIGINT)     AS ano,
      CAST(CO_MES AS BIGINT)     AS mes,
      CO_PAIS,
      SG_UF_NCM,
      CO_NCM,
      CAST(KG_LIQUIDO AS DOUBLE) AS peso_liquido_kg,
      CAST(VL_FOB AS DOUBLE)     AS valor_fob_dolar
    FROM read_csv(
      '{{csv_dados}}',
      delim = ';', header = true, quote = '"', all_varchar = true
    )
  ),
  ncm_grupo AS (
    SELECT n.CO_NCM, c.NO_CUCI_GRUPO
    FROM read_csv('{{dir_aux}}/NCM.csv',
                  delim = ';', header = true, quote = '"', all_varchar = true) n
    LEFT JOIN read_csv('{{dir_aux}}/NCM_CUCI.csv',
                  delim = ';', header = true, quote = '"', all_varchar = true) c
      ON n.CO_CUCI_ITEM = c.CO_CUCI_ITEM
  )
  SELECT
    COALESCE(p.NO_PAIS, '')  AS no_pais,
    COALESCE(u.NO_UF, '')    AS no_uf,
    CASE u.NO_REGIAO
      WHEN 'REGIAO NORTE'        THEN 'Norte'
      WHEN 'REGIAO NORDESTE'     THEN 'Nordeste'
      WHEN 'REGIAO SUDESTE'      THEN 'Sudeste'
      WHEN 'REGIAO SUL'          THEN 'Sul'
      WHEN 'REGIAO CENTRO OESTE' THEN 'Centro-Oeste'
      ELSE 'Não Declarada'
    END                      AS no_regiao,
    COALESCE(g.NO_CUCI_GRUPO, '') AS no_cuci_grupo,
    d.ano                    AS ano,
    d.mes                    AS mes,
    CASE d.mes
      WHEN 1 THEN 'jan.' WHEN 2 THEN 'fev.' WHEN 3  THEN 'mar.'
      WHEN 4 THEN 'abr.' WHEN 5 THEN 'maio' WHEN 6  THEN 'jun.'
      WHEN 7 THEN 'jul.' WHEN 8 THEN 'ago.' WHEN 9  THEN 'set.'
      WHEN 10 THEN 'out.' WHEN 11 THEN 'nov.' WHEN 12 THEN 'dez.'
    END                      AS nome_mes,
    SUM(d.peso_liquido_kg)   AS peso_liquido_kg,
    SUM(d.valor_fob_dolar)   AS valor_fob_dolar
  FROM dados d
  LEFT JOIN read_csv('{{dir_aux}}/PAIS.csv',
                     delim = ';', header = true, quote = '"',
                     all_varchar = true) p
    ON d.CO_PAIS = p.CO_PAIS
  LEFT JOIN read_csv('{{dir_aux}}/UF.csv',
                     delim = ';', header = true, quote = '"',
                     all_varchar = true) u
    ON d.SG_UF_NCM = u.SG_UF
  LEFT JOIN ncm_grupo g
    ON d.CO_NCM = g.CO_NCM
  GROUP BY ALL
) TO '{{destino}}' (FORMAT PARQUET, COMPRESSION ZSTD);
```

- [ ] **Step 5: Implementar o executor**

Crie `etl/R/transformar.R`:

```r
# Executa a agregação de um ano via DuckDB.
# Não decide quais anos processar — isso é responsabilidade de run.R.

CAMINHO_SQL <- file.path("etl", "sql", "agregado_ncm.sql")

transformar_ano <- function(csv_dados, dir_auxiliares, destino_parquet,
                            caminho_sql = CAMINHO_SQL) {
  if (!file.exists(csv_dados)) {
    stop("CSV de dados não encontrado: ", csv_dados)
  }

  modelo <- paste(readLines(caminho_sql, warn = FALSE), collapse = "\n")

  # normalizePath evita que caminhos relativos quebrem dentro do DuckDB.
  consulta <- modelo
  consulta <- gsub("{{csv_dados}}", normalizePath(csv_dados), consulta,
                   fixed = TRUE)
  consulta <- gsub("{{dir_aux}}", normalizePath(dir_auxiliares), consulta,
                   fixed = TRUE)
  consulta <- gsub("{{destino}}", destino_parquet, consulta, fixed = TRUE)

  dir.create(dirname(destino_parquet), recursive = TRUE, showWarnings = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, consulta)

  invisible(destino_parquet)
}
```

- [ ] **Step 6: Rodar e confirmar que passa**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "transformar")'`
Esperado: PASS — 5 testes.

Se `nome_mes` ou `no_regiao` falharem, o erro está no `CASE` do SQL, não no R. Compare com a tabela nas Restrições Globais.

- [ ] **Step 7: Commit**

```bash
git add etl/sql/agregado_ncm.sql etl/R/transformar.R tests/testthat/test-transformar.R renv.lock
git commit -m "feat(etl): agregação anual via DuckDB"
```

---

## Task 5: Consolidação dos anos

**Files:**
- Create: `etl/R/consolidar.R`
- Test: `tests/testthat/test-consolidar.R`

**Interfaces:**
- Consumes: parquets anuais produzidos por `transformar_ano()`.
- Produces:
  - `consolidar_fluxo(parquets_anuais, destino_parquet)` → `destino_parquet` (invisível).

- [ ] **Step 1: Escrever o teste que falha**

Crie `tests/testthat/test-consolidar.R`:

```r
source(file.path("..", "..", "etl", "R", "consolidar.R"))

gravar_parquet <- function(df, caminho) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb::duckdb_register(con, "tmp", df)
  DBI::dbExecute(con, sprintf(
    "COPY (SELECT * FROM tmp) TO '%s' (FORMAT PARQUET)", caminho))
  caminho
}

linha <- function(ano, valor) {
  data.frame(
    no_pais = "Índia", no_uf = "Maranhão", no_regiao = "Nordeste",
    no_cuci_grupo = "Trigo", ano = as.integer(ano), mes = 1L,
    nome_mes = "jan.", peso_liquido_kg = 10, valor_fob_dolar = valor,
    stringsAsFactors = FALSE
  )
}

test_that("consolidar_fluxo empilha os anos preservando ordem e valores", {
  dir <- tempfile("consolidar"); dir.create(dir)
  a <- gravar_parquet(linha(2024, 100), file.path(dir, "2024.parquet"))
  b <- gravar_parquet(linha(2025, 200), file.path(dir, "2025.parquet"))
  destino <- file.path(dir, "final.parquet")

  consolidar_fluxo(c(a, b), destino)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  saida <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM read_parquet('%s') ORDER BY ano", destino))

  expect_equal(nrow(saida), 2L)
  expect_equal(saida$ano, c(2024L, 2025L))
  expect_equal(saida$valor_fob_dolar, c(100, 200))
})

test_that("consolidar_fluxo recusa lista vazia", {
  expect_error(consolidar_fluxo(character(0), tempfile()), "nenhum parquet")
})

test_that("consolidar_fluxo recusa arquivo ausente", {
  expect_error(
    consolidar_fluxo(file.path(tempdir(), "nao-existe.parquet"), tempfile()),
    "não encontrado"
  )
})
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "consolidar")'`
Esperado: FAIL — `consolidar.R` não existe.

- [ ] **Step 3: Implementar**

Crie `etl/R/consolidar.R`:

```r
# Une os parquets anuais no arquivo final consumido pelo dashboard.

consolidar_fluxo <- function(parquets_anuais, destino_parquet) {
  if (length(parquets_anuais) == 0) {
    stop("Lista de entrada vazia: nenhum parquet para consolidar")
  }

  ausentes <- parquets_anuais[!file.exists(parquets_anuais)]
  if (length(ausentes) > 0) {
    stop("Parquet anual não encontrado: ", paste(ausentes, collapse = ", "))
  }

  dir.create(dirname(destino_parquet), recursive = TRUE, showWarnings = FALSE)

  lista <- paste0("'", normalizePath(parquets_anuais), "'", collapse = ", ")

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, sprintf(
    "COPY (SELECT * FROM read_parquet([%s])) TO '%s'
     (FORMAT PARQUET, COMPRESSION ZSTD)",
    lista, destino_parquet
  ))

  invisible(destino_parquet)
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "consolidar")'`
Esperado: PASS — 3 testes.

- [ ] **Step 5: Commit**

```bash
git add etl/R/consolidar.R tests/testthat/test-consolidar.R
git commit -m "feat(etl): consolidação dos parquets anuais"
```

---

## Task 6: Portão de validação

**Files:**
- Create: `etl/R/validar.R`
- Test: `tests/testthat/test-validar.R`

**Interfaces:**
- Consumes: um parquet consolidado.
- Produces:
  - `SCHEMA_ESPERADO` — vetor nomeado: nome da coluna → tipo DuckDB (`VARCHAR`/`BIGINT`/`DOUBLE`).
  - `validar_parquet(caminho, totais_anteriores = NULL, tolerancia = 0.01)` → `list(ok = logical(1), problemas = character(), totais_por_ano = named list)`.

- [ ] **Step 1: Escrever o teste que falha**

Crie `tests/testthat/test-validar.R`:

```r
source(file.path("..", "..", "etl", "R", "validar.R"))

gravar_parquet <- function(df, caminho) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb::duckdb_register(con, "tmp", df)
  DBI::dbExecute(con, sprintf(
    "COPY (SELECT * FROM tmp) TO '%s' (FORMAT PARQUET)", caminho))
  caminho
}

MESES <- c("jan.", "fev.", "mar.", "abr.", "maio", "jun.",
           "jul.", "ago.", "set.", "out.", "nov.", "dez.")

# Dois anos completos: 2024 fechado e 2025 fechado.
base_valida <- function() {
  do.call(rbind, lapply(c(2024L, 2025L), function(a) {
    data.frame(
      no_pais = "Índia", no_uf = "Maranhão", no_regiao = "Nordeste",
      no_cuci_grupo = "Trigo", ano = a, mes = 1:12, nome_mes = MESES,
      peso_liquido_kg = 10, valor_fob_dolar = 100,
      stringsAsFactors = FALSE
    )
  }))
}

# Os fixtures cobrem apenas 2024-2025; sem ano_inicial a verificação de lacuna
# acusaria 2014-2023 ausentes e todo teste reprovaria.
validar_fixture <- function(caminho, ...) {
  validar_parquet(caminho, ano_inicial = 2024L, ...)
}

test_that("parquet íntegro passa e devolve os totais por ano", {
  p <- gravar_parquet(base_valida(), tempfile(fileext = ".parquet"))
  r <- validar_fixture(p)

  expect_true(r$ok)
  expect_length(r$problemas, 0)
  expect_equal(r$totais_por_ano[["2024"]], 1200)
})

test_that("coluna faltando reprova", {
  df <- base_valida(); df$no_regiao <- NULL
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p)

  expect_false(r$ok)
  expect_true(any(grepl("schema", r$problemas, ignore.case = TRUE)))
})

test_that("ano fechado com menos de 12 meses reprova", {
  df <- base_valida()
  df <- df[!(df$ano == 2024L & df$mes == 7L), ]
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p)

  expect_false(r$ok)
  expect_true(any(grepl("meses", r$problemas)))
})

test_that("buraco na série de anos reprova", {
  df <- base_valida()
  df$ano[df$ano == 2025L] <- 2027L
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p)

  expect_false(r$ok)
  expect_true(any(grepl("lacuna", r$problemas)))
})

test_that("valor negativo reprova", {
  df <- base_valida(); df$valor_fob_dolar[1] <- -5
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p)

  expect_false(r$ok)
  expect_true(any(grepl("negativ", r$problemas)))
})

test_that("caractere de substituição reprova", {
  df <- base_valida()
  # U+FFFD construído por código: escrevê-lo literalmente no arquivo de teste
  # depende da codificação com que o arquivo foi salvo.
  df$no_pais[1] <- paste0(intToUtf8(65533), "ndia")
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p)

  expect_false(r$ok)
  expect_true(any(grepl("codifica", r$problemas, ignore.case = TRUE)))
})

test_that("queda maior que a tolerância em ano fechado reprova", {
  p <- gravar_parquet(base_valida(), tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, totais_anteriores = list("2024" = 5000))

  expect_false(r$ok)
  expect_true(any(grepl("regress", r$problemas, ignore.case = TRUE)))
})

test_that("variação dentro da tolerância é aceita", {
  p <- gravar_parquet(base_valida(), tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, totais_anteriores = list("2024" = 1205))

  expect_true(r$ok)
})

test_that("ano em andamento não dispara alerta de regressão", {
  # 2025 é o ano mais recente do fixture; seu total cresce a cada mês novo.
  p <- gravar_parquet(base_valida(), tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, totais_anteriores = list("2025" = 999999))

  expect_true(r$ok)
})
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "validar")'`
Esperado: FAIL — `validar.R` não existe.

- [ ] **Step 3: Implementar**

Crie `etl/R/validar.R`:

```r
# Portão de sanidade sobre o parquet consolidado.
# Não sabe de onde o arquivo veio — recebe um caminho e devolve um relatório.
# Isso permite testá-lo com dados sintéticos, sem rede.

SCHEMA_ESPERADO <- c(
  no_pais         = "VARCHAR",
  no_uf           = "VARCHAR",
  no_regiao       = "VARCHAR",
  no_cuci_grupo   = "VARCHAR",
  ano             = "BIGINT",
  mes             = "BIGINT",
  nome_mes        = "VARCHAR",
  peso_liquido_kg = "DOUBLE",
  valor_fob_dolar = "DOUBLE"
)

ANO_INICIAL <- 2014L

# ano_inicial é parâmetro para que os testes possam usar fixtures curtos sem
# que a verificação de lacuna acuse todos os anos ausentes desde 2014.
validar_parquet <- function(caminho, totais_anteriores = NULL,
                            tolerancia = 0.01, ano_inicial = ANO_INICIAL) {
  if (!file.exists(caminho)) {
    stop("Parquet não encontrado: ", caminho)
  }

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  fonte <- sprintf("read_parquet('%s')", normalizePath(caminho))
  problemas <- character(0)

  # --- schema ---------------------------------------------------------------
  colunas <- DBI::dbGetQuery(con, sprintf(
    "SELECT name, type FROM (DESCRIBE SELECT * FROM %s)", fonte))

  if (!identical(colunas$name, names(SCHEMA_ESPERADO))) {
    problemas <- c(problemas, paste0(
      "schema divergente: esperado [", paste(names(SCHEMA_ESPERADO), collapse = ", "),
      "], obtido [", paste(colunas$name, collapse = ", "), "]"))
    # Sem o schema correto as demais verificações não fazem sentido.
    return(list(ok = FALSE, problemas = problemas, totais_por_ano = list()))
  }

  divergentes <- colunas$name[colunas$type != unname(SCHEMA_ESPERADO)]
  if (length(divergentes) > 0) {
    problemas <- c(problemas, paste0(
      "schema divergente nos tipos: ", paste(divergentes, collapse = ", ")))
  }

  # --- cobertura ------------------------------------------------------------
  cobertura <- DBI::dbGetQuery(con, sprintf(
    "SELECT ano, COUNT(DISTINCT mes) AS meses, SUM(valor_fob_dolar) AS total
     FROM %s GROUP BY ano ORDER BY ano", fonte))

  anos <- cobertura$ano
  esperados <- seq(ano_inicial, max(anos))
  faltando <- setdiff(esperados, anos)
  if (length(faltando) > 0) {
    problemas <- c(problemas, paste0(
      "lacuna na série de anos: ", paste(faltando, collapse = ", ")))
  }

  # O ano mais recente pode estar em andamento; os anteriores, não.
  fechados <- cobertura[cobertura$ano < max(anos), ]
  incompletos <- fechados$ano[fechados$meses != 12L]
  if (length(incompletos) > 0) {
    problemas <- c(problemas, paste0(
      "ano fechado sem os 12 meses: ", paste(incompletos, collapse = ", ")))
  }

  # --- integridade ----------------------------------------------------------
  ruins <- DBI::dbGetQuery(con, sprintf(
    "SELECT
       COUNT(*) FILTER (WHERE valor_fob_dolar IS NULL
                           OR peso_liquido_kg IS NULL) AS nulos,
       COUNT(*) FILTER (WHERE valor_fob_dolar < 0
                           OR peso_liquido_kg < 0)     AS negativos,
       COUNT(*) FILTER (WHERE no_pais IS NULL OR no_uf IS NULL
                           OR no_regiao IS NULL
                           OR no_cuci_grupo IS NULL)   AS chaves_nulas
     FROM %s", fonte))

  if (ruins$nulos > 0) {
    problemas <- c(problemas, paste0(ruins$nulos, " linhas com medida nula"))
  }
  if (ruins$negativos > 0) {
    problemas <- c(problemas, paste0(ruins$negativos,
                                     " linhas com medida negativa"))
  }
  if (ruins$chaves_nulas > 0) {
    problemas <- c(problemas, paste0(ruins$chaves_nulas,
                                     " linhas com chave nula (join falhou)"))
  }

  # --- codificação ----------------------------------------------------------
  # U+FFFD indica que um byte latin1 foi lido como UTF-8. Nenhuma verificação
  # numérica detectaria isso, e o resultado seria "Ãfrica do Sul" no painel.
  # chr(65533) em vez do literal: evita depender da codificação com que este
  # arquivo-fonte foi salvo.
  corrompidos <- DBI::dbGetQuery(con, sprintf(
    "SELECT COUNT(*) AS n FROM %s
     WHERE contains(no_pais, chr(65533))
        OR contains(no_uf, chr(65533))
        OR contains(no_cuci_grupo, chr(65533))", fonte))

  if (corrompidos$n > 0) {
    problemas <- c(problemas, paste0(
      corrompidos$n, " linhas com falha de codificação (U+FFFD)"))
  }

  # --- regressão ------------------------------------------------------------
  totais <- as.list(stats::setNames(cobertura$total, as.character(cobertura$ano)))

  if (!is.null(totais_anteriores)) {
    ano_corrente <- as.character(max(anos))
    for (ano in names(totais_anteriores)) {
      # O ano em andamento cresce a cada mês; comparar seria falso positivo.
      if (ano == ano_corrente || is.null(totais[[ano]])) next

      antes <- totais_anteriores[[ano]]
      agora <- totais[[ano]]
      if (antes > 0 && abs(agora - antes) / antes > tolerancia) {
        problemas <- c(problemas, sprintf(
          "regressão em %s: total variou %.2f%% (de %.0f para %.0f)",
          ano, 100 * (agora - antes) / antes, antes, agora))
      }
    }
  }

  list(
    ok = length(problemas) == 0,
    problemas = problemas,
    totais_por_ano = totais
  )
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "validar")'`
Esperado: PASS — 8 testes.

- [ ] **Step 5: Commit**

```bash
git add etl/R/validar.R tests/testthat/test-validar.R
git commit -m "feat(etl): portão de validação do parquet consolidado"
```

---

## Task 7: Estado, orquestrador e primeira execução real

**Files:**
- Create: `etl/R/estado.R`
- Create: `etl/run.R`
- Create: `etl/estado.json`
- Test: `tests/testthat/test-estado.R`

**Interfaces:**
- Consumes: tudo das Tasks 2 a 6.
- Produces:
  - `ler_estado(caminho)` → `list(atualizado_em, arquivos, totais_por_ano)`; devolve estrutura vazia se o arquivo não existir.
  - `gravar_estado(estado, caminho)` → `caminho` (invisível).
  - `precisa_atualizar(fontes, estado, remotos)` → `data.frame` com o subconjunto de `fontes` cuja versão remota difere da registrada. `remotos` é uma lista nomeada por `chave`, cada item no formato devolvido por `metadados_remotos()`.
  - `etl/run.R` executável via `Rscript etl/run.R`.

- [ ] **Step 1: Escrever o teste que falha**

Crie `tests/testthat/test-estado.R`:

```r
source(file.path("..", "..", "etl", "R", "estado.R"))

test_that("ler_estado devolve estrutura vazia quando não há arquivo", {
  e <- ler_estado(file.path(tempdir(), "inexistente.json"))
  expect_equal(length(e$arquivos), 0L)
  expect_equal(length(e$totais_por_ano), 0L)
})

test_that("gravar e reler preserva o conteúdo", {
  caminho <- tempfile(fileext = ".json")
  estado <- list(
    atualizado_em = "2026-08-04T12:00:00Z",
    arquivos = list(EXP_2025 = list(last_modified = "Thu, 05 Feb 2026 18:21:06 GMT",
                                    content_length = "113715007")),
    totais_por_ano = list(exportacao = list("2024" = 1200))
  )

  gravar_estado(estado, caminho)
  lido <- ler_estado(caminho)

  expect_equal(lido$arquivos$EXP_2025$content_length, "113715007")
  expect_equal(lido$totais_por_ano$exportacao[["2024"]], 1200)
})

test_that("precisa_atualizar seleciona apenas o que mudou", {
  fontes <- data.frame(
    chave = c("EXP_2025", "EXP_2026"),
    url = c("u1", "u2"),
    stringsAsFactors = FALSE
  )
  estado <- list(arquivos = list(
    EXP_2025 = list(last_modified = "A", content_length = "1"),
    EXP_2026 = list(last_modified = "B", content_length = "2")
  ))
  remotos <- list(
    EXP_2025 = list(last_modified = "A", content_length = "1"),  # igual
    EXP_2026 = list(last_modified = "C", content_length = "9")   # mudou
  )

  pendentes <- precisa_atualizar(fontes, estado, remotos)

  expect_equal(pendentes$chave, "EXP_2026")
})

test_that("precisa_atualizar inclui arquivo nunca visto", {
  fontes <- data.frame(chave = "EXP_2027", url = "u", stringsAsFactors = FALSE)
  remotos <- list(EXP_2027 = list(last_modified = "X", content_length = "5"))

  pendentes <- precisa_atualizar(fontes, list(arquivos = list()), remotos)

  expect_equal(nrow(pendentes), 1L)
})
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "estado")'`
Esperado: FAIL — `estado.R` não existe.

- [ ] **Step 3: Implementar o estado**

Crie `etl/R/estado.R`:

```r
# Registro do que já foi processado. É este arquivo — e não os dados — que o
# repositório versiona, servindo de rastro auditável das atualizações.

ler_estado <- function(caminho) {
  if (!file.exists(caminho)) {
    return(list(atualizado_em = NULL, arquivos = list(),
                totais_por_ano = list()))
  }

  estado <- jsonlite::fromJSON(caminho, simplifyVector = FALSE)

  list(
    atualizado_em = estado$atualizado_em,
    arquivos = estado$arquivos %||% list(),
    totais_por_ano = estado$totais_por_ano %||% list()
  )
}

gravar_estado <- function(estado, caminho) {
  dir.create(dirname(caminho), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(estado, caminho, auto_unbox = TRUE, pretty = TRUE)
  invisible(caminho)
}

# Compara a versão remota com a registrada. Um arquivo nunca visto, ou cujo
# Last-Modified ou tamanho mudou, entra na fila. Quando o servidor não informa
# esses cabeçalhos, os valores vêm vazios e a comparação falha — reprocessamos
# por precaução.
precisa_atualizar <- function(fontes, estado, remotos) {
  mudou <- vapply(fontes$chave, function(chave) {
    registrado <- estado$arquivos[[chave]]
    if (is.null(registrado)) return(TRUE)

    remoto <- remotos[[chave]]
    if (is.null(remoto)) return(TRUE)

    !identical(as.character(registrado$last_modified),
               as.character(remoto$last_modified)) ||
    !identical(as.character(registrado$content_length),
               as.character(remoto$content_length))
  }, logical(1))

  fontes[mudou, , drop = FALSE]
}

`%||%` <- function(x, y) if (is.null(x)) y else x
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `Rscript -e 'testthat::test_dir("tests/testthat", filter = "estado")'`
Esperado: PASS — 4 testes.

- [ ] **Step 5: Escrever o orquestrador**

Crie `etl/run.R`:

```r
#!/usr/bin/env Rscript
# Orquestrador do pipeline de atualização do Comex Stat.
#
#   Rscript etl/run.R              # processa apenas o que mudou na fonte
#   Rscript etl/run.R --forcar     # reprocessa todos os anos
#
# Sai com código 0 se tudo correu bem (inclusive quando nada mudou) e 1 quando
# a validação reprova — o que impede o deploy no workflow.

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

for (arquivo in list.files("etl/R", pattern = "\\.R$", full.names = TRUE)) {
  source(arquivo)
}

CAMINHO_ESTADO <- "etl/estado.json"
DIR_TRABALHO   <- "etl/.trabalho"
DIR_CACHE      <- file.path(DIR_TRABALHO, "anos")
DIR_AUX        <- file.path(DIR_TRABALHO, "aux")
DIR_SAIDA      <- "dados"

forcar <- "--forcar" %in% commandArgs(trailingOnly = TRUE)

registrar <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "|", ..., "\n")
}

# --- 1. manifesto -----------------------------------------------------------
registrar("Consultando versões remotas...")

fontes <- fontes_anuais()
estado <- ler_estado(CAMINHO_ESTADO)

remotos <- lapply(stats::setNames(fontes$url, fontes$chave), metadados_remotos)

pendentes <- if (forcar) fontes else precisa_atualizar(fontes, estado, remotos)

if (nrow(pendentes) == 0) {
  registrar("Nenhuma mudança na fonte. Encerrando sem reprocessar.")
  quit(status = 0)
}

registrar(nrow(pendentes), "arquivo(s) a processar:",
          paste(pendentes$chave, collapse = ", "))

# --- 2. tabelas auxiliares --------------------------------------------------
registrar("Baixando tabelas auxiliares...")
dir.create(DIR_AUX, recursive = TRUE, showWarnings = FALSE)

auxiliares <- fontes_auxiliares()
for (i in seq_len(nrow(auxiliares))) {
  destino <- file.path(DIR_AUX, paste0(auxiliares$chave[i], ".csv"))
  baixar_arquivo(auxiliares$url[i], destino)
  converter_para_utf8(destino)
}

# --- 3. download e transformação --------------------------------------------
dir.create(DIR_CACHE, recursive = TRUE, showWarnings = FALSE)

for (i in seq_len(nrow(pendentes))) {
  item <- pendentes[i, ]
  registrar("Processando", item$chave, "...")

  csv <- file.path(DIR_TRABALHO, paste0(item$chave, ".csv"))
  baixar_arquivo(item$url, csv)

  parquet_ano <- file.path(DIR_CACHE,
                           paste0(item$fluxo, "_", item$ano, ".parquet"))
  transformar_ano(csv, DIR_AUX, parquet_ano)

  # O CSV bruto chega a 175 MB; o runner do Actions tem disco limitado.
  unlink(csv)

  estado$arquivos[[item$chave]] <- remotos[[item$chave]]
}

# --- 4. consolidação e validação --------------------------------------------
resultado_ok <- TRUE

for (fluxo in c("exportacao", "importacao")) {
  anuais <- sort(list.files(DIR_CACHE, pattern = paste0("^", fluxo, "_"),
                            full.names = TRUE))
  destino <- file.path(DIR_SAIDA, paste0("ncm_", fluxo, "_agrupado.parquet"))

  registrar("Consolidando", fluxo, "-", length(anuais), "anos")
  consolidar_fluxo(anuais, destino)

  relatorio <- validar_parquet(
    destino,
    totais_anteriores = estado$totais_por_ano[[fluxo]]
  )

  if (relatorio$ok) {
    registrar("Validação de", fluxo, "OK")
    estado$totais_por_ano[[fluxo]] <- relatorio$totais_por_ano
  } else {
    resultado_ok <- FALSE
    registrar("VALIDAÇÃO REPROVOU", fluxo, ":")
    for (p in relatorio$problemas) registrar("   -", p)
  }
}

if (!resultado_ok) {
  registrar("Pipeline interrompido: o estado NÃO foi atualizado.")
  quit(status = 1)
}

# --- 5. registro ------------------------------------------------------------
estado$atualizado_em <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
gravar_estado(estado, CAMINHO_ESTADO)

registrar("Concluído.")
quit(status = 0)
```

- [ ] **Step 6: Ignorar o diretório de trabalho**

Acrescente ao `.gitignore`:

```
# Arquivos temporários do ETL (CSVs brutos e cache anual)
etl/.trabalho/
```

- [ ] **Step 7: Executar o pipeline completo pela primeira vez**

```bash
Rscript etl/run.R
```

Esperado: baixa 26 arquivos anuais (2014–2026, dois fluxos), processa e valida. Leva de 30 a 60 minutos na primeira execução por causa do volume — os CSVs somam ~4 GB. Acompanhe os logs.

Na primeira execução não há `totais_anteriores`, então a verificação de regressão não roda — correto, não há com o que comparar.

- [ ] **Step 8: Conferir o resultado contra o parquet antigo**

```bash
Rscript -e '
con <- DBI::dbConnect(duckdb::duckdb())
q <- function(sql) DBI::dbGetQuery(con, sql)
r <- q("SELECT ano, COUNT(*) AS linhas, SUM(valor_fob_dolar) AS total
        FROM read_parquet(\"dados/ncm_exportacao_agrupado.parquet\")
        GROUP BY ano ORDER BY ano")
print(r)
'
```

Esperado: anos de 2014 a 2026, com 2026 parcial. **Compare os totais de 2014–2024 com o backup** (`../backup-worktree-*.tar.gz`): devem bater com diferença inferior a 1%. Divergência maior indica erro nos joins — pare e investigue antes de seguir.

- [ ] **Step 9: Commit**

```bash
git add etl/R/estado.R etl/run.R etl/estado.json tests/testthat/test-estado.R .gitignore
git commit -m "feat(etl): orquestrador e registro de estado"
```

---

## Task 8: Dinamizar o ano de referência no dashboard

**Contexto:** `dashboard.qmd` tem 23 ocorrências de ano literal. Enquanto elas existirem, dados novos não aparecem — o painel continua exibindo 2024.

**Files:**
- Modify: `dashboard.qmd`

**Interfaces:**
- Consumes: os parquets gerados na Task 7.
- Produces: constantes `ANO_MIN` e `ANO_REF` disponíveis a todos os blocos.

- [ ] **Step 1: Acrescentar as constantes ao bloco de setup**

No bloco `#| context: setup` de `dashboard.qmd`, após os `library()`, insira:

```r
# Período derivado dos próprios dados. ANO_REF é o último ano com os 12 meses
# fechados: usar um ano parcial como referência tornaria as comparações anuais
# enganosas, porque o total apareceria menor que o dos anos anteriores.
.cobertura <- arrow::open_dataset("dados/ncm_exportacao_agrupado.parquet") |>
  dplyr::group_by(ano) |>
  dplyr::summarise(meses = dplyr::n_distinct(mes)) |>
  dplyr::collect()

ANO_MIN <- min(.cobertura$ano)
ANO_REF <- max(.cobertura$ano[.cobertura$meses == 12L])
```

- [ ] **Step 2: Substituir as 11 ocorrências que afetam lógica**

| Linha aprox. | De | Para |
|---|---|---|
| 288 | `dplyr::filter(ano == 2024 & uf == input$SelecaoUF)` | `dplyr::filter(ano == ANO_REF & uf == input$SelecaoUF)` |
| 501 | `ano = 2014:2024` | `ano = ANO_MIN:ANO_REF` |
| 632 | `dplyr::filter(ano == 2024 &` | `dplyr::filter(ano == ANO_REF &` |
| 656 | `dplyr::filter(ano == 2024 & no_cuci_grupo %in% lbls &` | `dplyr::filter(ano == ANO_REF & no_cuci_grupo %in% lbls &` |
| 782 | `ano >= 2014 & ano <= 2024` | `ano >= ANO_MIN & ano <= ANO_REF` |
| 809 | `ano >= 2014 & ano <= 2024 &` | `ano >= ANO_MIN & ano <= ANO_REF &` |
| 934 | `dplyr::filter(ano == 2024 &` | `dplyr::filter(ano == ANO_REF &` |
| 958 | `dplyr::filter(ano == 2024 & no_cuci_grupo %in% lbls &` | `dplyr::filter(ano == ANO_REF & no_cuci_grupo %in% lbls &` |
| 1102 | `ano >= 2014 & ano <= 2024` | `ano >= ANO_MIN & ano <= ANO_REF` |
| 1130 | `ano >= 2014 & ano <= 2024 &` | `ano >= ANO_MIN & ano <= ANO_REF &` |

Confirme que nenhuma sobrou:

```bash
grep -nE "ano *(==|>=|<=) *20[0-9]{2}|20[0-9]{2}:20[0-9]{2}" dashboard.qmd
```

Esperado: nenhuma saída.

- [ ] **Step 3: Interpolar os 8 textos visíveis**

| Linha aprox. | De | Para |
|---|---|---|
| 316 | `"Balança Comercial de 2024 do "` | `paste0("Balança Comercial de ", ANO_REF, " do ")` |
| 566 | `"Evolução da balança comercial anual (2014-2024) do"` | `paste0("Evolução da balança comercial anual (", ANO_MIN, "-", ANO_REF, ") do")` |
| 725 | `"Os principais produtos exportados em 2024"` | `paste0("Os principais produtos exportados em ", ANO_REF)` |
| 729 | `"Fonte: Secretaria de Comércio Exterior - SECEX (2024)"` | `paste0("Fonte: Secretaria de Comércio Exterior - SECEX (", ANO_REF, ")")` |
| 877 | `" entre 2014-2024, valores "` | `paste0(" entre ", ANO_MIN, "-", ANO_REF, ", valores ")` |
| 1027 | `"Os principais produtos importados em 2024"` | `paste0("Os principais produtos importados em ", ANO_REF)` |
| 1031 | `"Fonte: Secretaria de Comércio Exterior - SECEX (2024)"` | `paste0("Fonte: Secretaria de Comércio Exterior - SECEX (", ANO_REF, ")")` |
| 1199 | `" entre 2014-2024, valores "` | `paste0(" entre ", ANO_MIN, "-", ANO_REF, ", valores ")` |

- [ ] **Step 4: Renomear os 5 identificadores de output**

Um identificador que carrega um ano fixo convida alguém a reintroduzir o valor literal. Renomeie **cada par UI/server**:

```bash
sed -i '' \
  -e 's/balanca_2014_2024/balanca_anual/g' \
  -e 's/tabela_Exp_Prod2024/tabela_exp_produtos/g' \
  -e 's/tabela_Imp_Prod2024/tabela_imp_produtos/g' \
  -e 's/destinos_2014_2024/destinos_anual/g' \
  -e 's/origens_2014_2024/origens_anual/g' \
  dashboard.qmd

grep -c "2024" dashboard.qmd
```

Esperado: `0`, ou apenas ocorrências em comentários. Verifique o que restou com `grep -n "2024" dashboard.qmd`.

- [ ] **Step 5: Renderizar e conferir visualmente**

```bash
quarto render dashboard.qmd
```

Esperado: renderiza sem erro. Abra `dashboard.html` e confirme que os títulos dizem **2025** (não 2024) e que os gráficos anuais vão de 2014 a 2025.

Se `quarto` não estiver instalado: `brew install quarto`.

- [ ] **Step 6: Commit**

```bash
git add dashboard.qmd dashboard.html
git commit -m "feat(dashboard): deriva o ano de referência dos dados

Remove as 23 ocorrências de ano fixo. O painel passa a acompanhar a
cobertura dos parquets sem alteração de código."
```

---

## Task 9: Medir as duas estratégias de leitura

**Contexto:** o shinyapps.io limita 1 GB de RAM por instância no plano gratuito. Com os dados até 2026 cada parquet chega a ~4,6 milhões de linhas. A variante do branch `paralelizacao` usa `memoise` + `collect()` e pode estourar esse teto; a atual usa Arrow preguiçoso. A decisão sai da medição, não de argumento.

**Files:**
- Create: `scripts/medir_leitura.R`
- Modify: `dashboard.qmd` (apenas se a medição indicar troca de estratégia)
- Modify: `docs/superpowers/specs/2026-08-04-pipeline-mensal-comex-design.md` (registrar o resultado)

**Interfaces:**
- Consumes: os parquets da Task 7.
- Produces: decisão registrada na spec.

- [ ] **Step 1: Escrever o script de medição**

Crie `scripts/medir_leitura.R`:

```r
#!/usr/bin/env Rscript
# Compara o custo de memória e tempo das duas estratégias de leitura dos
# parquets, para decidir qual sobrevive ao teto de 1 GB do shinyapps.io.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
})

ARQUIVO <- "dados/ncm_exportacao_agrupado.parquet"
UFS <- c("Maranhão", "Nordeste", "Brasil")

esquema <- schema(
  no_pais = string(), no_uf = string(), no_regiao = string(),
  no_cuci_grupo = string(), ano = int64(), mes = int64(),
  nome_mes = string(), peso_liquido_kg = float64(), valor_fob_dolar = float64()
)

medir <- function(rotulo, f) {
  gc(full = TRUE, reset = TRUE)
  inicio <- Sys.time()
  for (uf in UFS) f(uf)
  duracao <- as.numeric(difftime(Sys.time(), inicio, units = "secs"))
  pico <- sum(gc()[, "max used"] * c(8, 8)) / 1024^2
  cat(sprintf("%-28s | %6.1f s | pico ~%7.1f MB\n", rotulo, duracao, pico))
}

preguicoso <- function(uf) {
  open_dataset(ARQUIVO, schema = esquema) |>
    filter(no_uf == uf | no_regiao == uf | uf == "Brasil") |>
    group_by(ano, mes) |>
    summarise(v = sum(valor_fob_dolar, na.rm = TRUE), .groups = "drop") |>
    collect()
}

ansioso <- function(uf) {
  open_dataset(ARQUIVO, schema = esquema) |>
    filter(no_uf == uf | no_regiao == uf | uf == "Brasil") |>
    collect() |>
    group_by(ano, mes) |>
    summarise(v = sum(valor_fob_dolar, na.rm = TRUE), .groups = "drop")
}

cat("Linhas:", nrow(open_dataset(ARQUIVO, schema = esquema)), "\n\n")
medir("Arrow preguiçoso (local)", preguicoso)
medir("collect() ansioso (remoto)", ansioso)
```

- [ ] **Step 2: Executar a medição**

```bash
Rscript scripts/medir_leitura.R
```

Esperado: duas linhas com tempo e pico de memória.

- [ ] **Step 3: Decidir com base no número**

Critério explícito, sem margem para interpretação:

- Se o pico do `collect()` ansioso passar de **700 MB**, ele é descartado — a margem até o teto de 1 GB não comporta o overhead do Shiny e do R. Mantenha a versão preguiçosa atual.
- Se ficar abaixo de 700 MB **e** for mais de 2× mais rápido, vale portar o `memoise` do branch `paralelizacao`. Nesse caso, traga **apenas** o `memoise` — `future`/`furrr` paralelizam sobre 3 UFs apenas e não compensam as dependências adicionais.
- Em qualquer outro caso, mantenha a versão atual.

- [ ] **Step 4: Registrar o resultado na spec**

Em `docs/superpowers/specs/2026-08-04-pipeline-mensal-comex-design.md`, substitua a última frase da seção "Decisão pendente: estratégia de leitura" pelos números medidos e pela decisão tomada, no formato:

```markdown
**Resultado (medido em <data>):** leitura preguiçosa — <X> s, pico <Y> MB;
collect() ansioso — <Z> s, pico <W> MB. Decisão: <estratégia escolhida>,
porque <razão ligada ao critério de 700 MB>.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/medir_leitura.R docs/superpowers/specs/2026-08-04-pipeline-mensal-comex-design.md dashboard.qmd
git commit -m "perf: fixa a estratégia de leitura por medição"
```

---

## Task 10: Workflow do GitHub Actions

**Files:**
- Create: `.github/workflows/atualizar-dados.yml`

**Interfaces:**
- Consumes: `etl/run.R` (Task 7) e os secrets já cadastrados.
- Produces: execução mensal automática.

**Pré-requisito já cumprido:** `SHINYAPPS_TOKEN` e `SHINYAPPS_SECRET` foram cadastrados no repositório em 2026-08-04.

- [ ] **Step 1: Escrever o workflow**

Crie `.github/workflows/atualizar-dados.yml`:

```yaml
name: Atualizar dados do Comex Stat

on:
  schedule:
    # Dia 10 de cada mês, 09:00 UTC (06:00 em Brasília). O MDIC não publica em
    # dia fixo; quando nada mudou o job encerra em segundos.
    - cron: '0 9 10 * *'
  workflow_dispatch:
    inputs:
      forcar:
        description: 'Reprocessar todos os anos, ignorando o cache'
        type: boolean
        default: false

# Sem gatilho de pull_request: isso impediria que um PR vindo de um fork
# obtivesse acesso ao token de deploy.

permissions:
  contents: write
  issues: write

jobs:
  atualizar:
    runs-on: ubuntu-latest
    timeout-minutes: 120

    steps:
      - uses: actions/checkout@v4

      - uses: r-lib/actions/setup-r@v2
        with:
          r-version: '4.4.2'
          use-public-rspm: true

      - uses: r-lib/actions/setup-renv@v2

      - name: Restaurar cache dos parquets anuais
        uses: actions/cache@v4
        with:
          path: etl/.trabalho/anos
          key: comex-anos-${{ hashFiles('etl/estado.json') }}
          restore-keys: comex-anos-

      - name: Executar os testes
        run: Rscript -e 'testthat::test_dir("tests/testthat", stop_on_failure = TRUE)'

      - name: Executar o ETL
        run: |
          if [ "${{ inputs.forcar }}" = "true" ]; then
            Rscript etl/run.R --forcar
          else
            Rscript etl/run.R
          fi

      - name: Verificar se houve atualização
        id: mudou
        run: |
          if git diff --quiet etl/estado.json; then
            echo "houve=false" >> "$GITHUB_OUTPUT"
            echo "Nada mudou na fonte; nada a publicar."
          else
            echo "houve=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Registrar o estado no repositório
        if: steps.mudou.outputs.houve == 'true'
        run: |
          git config user.name  'github-actions[bot]'
          git config user.email 'github-actions[bot]@users.noreply.github.com'
          git add etl/estado.json
          git commit -m "chore: atualiza dados do Comex Stat [skip ci]"
          git push

      - name: Publicar os parquets como asset de Release
        if: steps.mudou.outputs.houve == 'true'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG="dados-$(date +%Y-%m)"
          gh release create "$TAG" \
            --title "Dados do Comex Stat — $(date +%Y-%m)" \
            --notes "Gerado automaticamente pelo pipeline mensal." \
            dados/ncm_exportacao_agrupado.parquet \
            dados/ncm_importacao_agrupado.parquet \
          || gh release upload "$TAG" \
            dados/ncm_exportacao_agrupado.parquet \
            dados/ncm_importacao_agrupado.parquet --clobber

      - name: Publicar no shinyapps.io
        if: steps.mudou.outputs.houve == 'true'
        env:
          SHINYAPPS_TOKEN:  ${{ secrets.SHINYAPPS_TOKEN }}
          SHINYAPPS_SECRET: ${{ secrets.SHINYAPPS_SECRET }}
        run: |
          Rscript -e '
            rsconnect::setAccountInfo(
              name   = "observatorioportuario",
              token  = Sys.getenv("SHINYAPPS_TOKEN"),
              secret = Sys.getenv("SHINYAPPS_SECRET")
            )
            rsconnect::deployDoc(
              "dashboard.qmd",
              appName = "balanca_comercial",
              account = "observatorioportuario",
              forceUpdate = TRUE,
              logLevel = "verbose"
            )
          '

      - name: Abrir issue em caso de falha
        if: failure()
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh issue create \
            --title "Falha na atualização mensal do Comex Stat" \
            --body "A execução de $(date +%Y-%m-%d) falhou.

          Log: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}

          O dashboard em produção segue com os dados válidos do mês anterior." \
            --label "automação"
```

- [ ] **Step 2: Verificar a sintaxe antes de enviar**

```bash
Rscript -e 'if (!requireNamespace("yaml", quietly = TRUE)) install.packages("yaml"); yaml::read_yaml(".github/workflows/atualizar-dados.yml"); cat("YAML válido\n")'
```

Esperado: `YAML válido`

- [ ] **Step 3: Commit e envio**

```bash
git add .github/workflows/atualizar-dados.yml
git commit -m "ci: atualização mensal automática do Comex Stat"
git push origin master
```

- [ ] **Step 4: Disparar manualmente para validar o caminho completo**

```bash
gh workflow run atualizar-dados.yml -R tadeugomes/dashboard_balanca_comercial
sleep 60
gh run list --workflow=atualizar-dados.yml -R tadeugomes/dashboard_balanca_comercial --limit 1
```

Acompanhe com `gh run watch -R tadeugomes/dashboard_balanca_comercial`.

Esperado: como o `estado.json` já foi commitado na Task 7 e nada mudou na fonte, o job deve encerrar cedo com "Nenhuma mudança na fonte". Isso valida o caminho de manifesto sem gastar uma hora.

- [ ] **Step 5: Validar o deploy de fato**

```bash
gh workflow run atualizar-dados.yml -R tadeugomes/dashboard_balanca_comercial -f forcar=true
gh run watch -R tadeugomes/dashboard_balanca_comercial
```

Esperado: reprocessa tudo, publica o Release e faz o deploy. Confirme que https://observatorioportuario.shinyapps.io/balanca_comercial/ abre e exibe o ano de referência correto.

Se o deploy falhar com erro de autenticação, o token provavelmente foi colado com quebra de linha — recadastre conforme o Passo 2 do procedimento de secrets.

---

## Task 11: Limpar o histórico do Git

**Contexto:** o `.git` ocupa 484 MB por causa de versões antigas dos parquets, com blobs de até 98 MB. Depois da Task 1 esses arquivos não crescem mais, mas o peso acumulado permanece.

**Atenção:** esta tarefa **reescreve o histórico** e quebra o fork `chicojadson/dashboard_balanca_comercial` e todo clone existente. Só execute após o autor avisar os envolvidos. Ela é independente de todas as anteriores — o pipeline já está funcionando sem ela.

**Files:** nenhum arquivo de código é alterado.

- [ ] **Step 1: Confirmar que o aviso foi dado**

Pergunte ao autor, explicitamente, se os detentores de clones já foram avisados. **Não prossiga sem confirmação.**

- [ ] **Step 2: Fazer um novo backup**

```bash
cd /Users/tgt/Documents/GitHub/dashboard_balanca_comercial
git clone --mirror . ../backup-pre-filter-repo-$(date +%Y%m%d).git
du -sh ../backup-pre-filter-repo-*.git
```

Esperado: ~484 MB.

- [ ] **Step 3: Instalar a ferramenta**

```bash
brew install git-filter-repo
git filter-repo --version
```

- [ ] **Step 4: Medir antes**

```bash
du -sh .git
```

Anote o valor.

- [ ] **Step 5: Remover os parquets de todo o histórico**

```bash
git filter-repo --path dados/ --invert-paths --force
```

- [ ] **Step 6: Medir depois e conferir a integridade**

```bash
du -sh .git
git log --oneline | wc -l
git log -1 --format='%h %s'
ls dados/
```

Esperado: `.git` abaixo de 20 MB; a contagem de commits permanece a mesma; os parquets **continuam em `dados/`** no disco, porque nunca deixaram o diretório de trabalho.

- [ ] **Step 7: Verificar que nenhum blob grande sobreviveu**

```bash
git rev-list --objects --all \
  | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
  | grep '^blob' | sort -k3 -n -r | head -5
```

Esperado: nenhum blob acima de ~2 MB.

- [ ] **Step 8: Reconfigurar o remoto e enviar**

O `filter-repo` remove os remotos por segurança.

```bash
git remote add origin https://github.com/tadeugomes/dashboard_balanca_comercial.git
git push origin --force --all
git push origin --force --tags
```

- [ ] **Step 9: Confirmar que o CI continua verde**

```bash
gh run list -R tadeugomes/dashboard_balanca_comercial --limit 3
```

Esperado: nenhuma execução quebrada pela reescrita.

---

## Verificação final

- [ ] `Rscript -e 'testthat::test_dir("tests/testthat")'` passa inteiro
- [ ] `Rscript etl/run.R` encerra com "Nenhuma mudança na fonte" numa segunda execução seguida
- [ ] `grep -c "2024" dashboard.qmd` devolve 0
- [ ] O dashboard publicado exibe o ano de referência correto
- [ ] `git rev-list --left-right --count origin/master...master` devolve `0	0`
- [ ] O workflow aparece agendado em `gh workflow list`
