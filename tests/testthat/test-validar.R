source(file.path("..", "..", "etl", "R", "validar.R"))
# consolidar_e_validar() (em validar.R) chama consolidar_fluxo() internamente
# -- precisa estar carregada para os testes de I2/I6 abaixo, do mesmo jeito
# que run.R garante isso sourceando etl/R/*.R inteiro antes de usá-la.
source(file.path("..", "..", "etl", "R", "consolidar.R"))

gravar_parquet <- function(df, caminho) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb::duckdb_register(con, "tmp", df)
  # CAST explícito: duckdb_register() preserva o tipo integer do R (INTEGER),
  # mas SCHEMA_ESPERADO exige BIGINT para ano/mes. Sem o CAST, a fixture
  # "válida" reprovaria por divergência de tipo — armadilha já vista em
  # tarefas anteriores deste projeto.
  DBI::dbExecute(con, sprintf(
    "COPY (SELECT * REPLACE (CAST(ano AS BIGINT) AS ano,
                              CAST(mes AS BIGINT) AS mes)
           FROM tmp) TO '%s' (FORMAT PARQUET)", caminho))
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
# faixa_valor/faixa_peso ficam NULL por padrão (verificação de grandeza
# desativada): os fixtures acima somam poucas dezenas ou centenas de
# dólares/kg, muito abaixo de qualquer faixa plausível real, e não é isso
# que esses testes verificam. Os testes de grandeza abaixo passam essas
# faixas explicitamente.
validar_fixture <- function(caminho, ..., faixa_valor = NULL, faixa_peso = NULL) {
  validar_parquet(caminho, ano_inicial = 2024L,
                   faixa_valor = faixa_valor, faixa_peso = faixa_peso, ...)
}

# Constrói n_meses linhas de um ano com o total informado dividido igualmente
# entre os meses — usado só pelos testes de ordem de grandeza, que precisam
# controlar o total anual exato.
linhas_ano <- function(ano, n_meses, valor_total, peso_total) {
  do.call(rbind, lapply(seq_len(n_meses), function(m) {
    data.frame(
      no_pais = "Índia", no_uf = "Maranhão", no_regiao = "Nordeste",
      no_cuci_grupo = "Trigo", ano = ano, mes = m, nome_mes = MESES[m],
      peso_liquido_kg = peso_total / n_meses, valor_fob_dolar = valor_total / n_meses,
      stringsAsFactors = FALSE
    )
  }))
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

# --- ordem de grandeza -------------------------------------------------------
# Detecta erro de escala (ex.: agregação que soma sem dividir por 1e6/1e9) já
# na primeira execução, quando totais_anteriores ainda não existe e a
# verificação de regressão não tem contra o que comparar.

test_that("ano fechado com valor abaixo do mínimo reprova", {
  df <- rbind(
    linhas_ano(2024L, 12L, valor_total = 10000,  peso_total = 500),
    linhas_ano(2025L, 12L, valor_total = 200000, peso_total = 500)
  )
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, faixa_valor = c(50e3, 800e3))

  expect_false(r$ok)
  expect_true(any(grepl("2024", r$problemas) & grepl("faixa", r$problemas)))
})

test_that("ano fechado com valor acima do máximo reprova", {
  df <- rbind(
    linhas_ano(2024L, 12L, valor_total = 900000, peso_total = 500),
    linhas_ano(2025L, 12L, valor_total = 200000, peso_total = 500)
  )
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, faixa_valor = c(50e3, 800e3))

  expect_false(r$ok)
  expect_true(any(grepl("2024", r$problemas) & grepl("faixa", r$problemas)))
})

test_that("ano fechado com peso fora da faixa reprova", {
  df <- rbind(
    linhas_ano(2024L, 12L, valor_total = 200000, peso_total = 5000),
    linhas_ano(2025L, 12L, valor_total = 200000, peso_total = 500)
  )
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, faixa_peso = c(50, 2000))

  expect_false(r$ok)
  expect_true(any(grepl("2024", r$problemas) & grepl("peso_liquido_kg", r$problemas)))
})

test_that("ano em andamento com total baixo não dispara alerta de grandeza", {
  # 2025 é o ano mais recente (parcial, só 2 meses): em janeiro o total real
  # também fica bem abaixo da faixa plausível anual, e isso não é um erro.
  df <- rbind(
    linhas_ano(2024L, 12L, valor_total = 200000, peso_total = 500),
    linhas_ano(2025L, 2L,  valor_total = 20,      peso_total = 2)
  )
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, faixa_valor = c(50e3, 800e3), faixa_peso = c(50, 2000))

  expect_true(r$ok)
})

test_that("faixa_valor = NULL desativa a verificação de grandeza", {
  df <- rbind(
    linhas_ano(2024L, 12L, valor_total = 10000,  peso_total = 500),
    linhas_ano(2025L, 12L, valor_total = 200000, peso_total = 500)
  )
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  # faixa_peso continua ativa e o peso está dentro dela: prova que só a
  # verificação de valor foi desligada, não as duas por engano.
  r <- validar_fixture(p, faixa_valor = NULL, faixa_peso = c(50, 2000))

  expect_true(r$ok)
})

# --- I1: verificação de join mede string vazia, não NULL --------------------
# O SQL de agregação faz COALESCE(..., '') em no_uf/no_cuci_grupo (e um CASE
# com ELSE não-nulo em no_regiao) -- NULL é impossível nessas colunas, então
# uma verificação "IS NULL" nunca dispara, mesmo com o LEFT JOIN 100%
# quebrado. A verificação corrigida mede a PROPORÇÃO de string vazia contra
# um limiar explícito (limiar_vazio).

test_that("proporção de string vazia acima do limiar de join reprova", {
  df <- base_valida()
  # 2 das 24 linhas com no_cuci_grupo vazio -> 8,33%, acima de um limiar de 5%.
  df$no_cuci_grupo[1:2] <- ""
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, limiar_vazio = 0.05)

  expect_false(r$ok)
  problema <- r$problemas[grepl("no_cuci_grupo", r$problemas)]
  expect_length(problema, 1)
  expect_true(grepl("join", problema, ignore.case = TRUE))
  expect_true(grepl("2 de 24", problema))
})

test_that("proporção de string vazia dentro do limiar de join passa", {
  df <- base_valida()
  # 1 das 24 linhas vazia -> 4,17%, abaixo de um limiar de 5%.
  df$no_cuci_grupo[1] <- ""
  p <- gravar_parquet(df, tempfile(fileext = ".parquet"))
  r <- validar_fixture(p, limiar_vazio = 0.05)

  expect_true(r$ok)
})

# --- I2: consolidar_e_validar() nunca sobrescreve um destino bom com um ----
# --- consolidado reprovado ---------------------------------------------------
# Antes, consolidar_fluxo() gravava direto no parquet de destino e
# validar_parquet() só decidia DEPOIS se prestava -- uma execução reprovada
# já tinha destruído o parquet bom anterior. consolidar_e_validar() escreve
# num temporário no mesmo diretório do destino e só promove (file.rename)
# se a validação passar.

test_that("consolidar_e_validar não sobrescreve o parquet de destino quando a validação reprova", {
  dir <- tempfile("consolidar_e_validar_falha"); dir.create(dir)
  destino <- file.path(dir, "final.parquet")

  # "Parquet bom" já publicado -- é o que consolidar_e_validar() não pode
  # destruir numa reprovação. valor_fob_dolar = 999 (em vez dos 100 do
  # fixture-padrão) de propósito: se o destino for indevidamente sobrescrito
  # pelo consolidado abaixo, a soma muda de forma detectável -- sem essa
  # diferença, os dois fixtures teriam totais coincidentemente iguais e a
  # asserção passaria mesmo com a proteção quebrada.
  bom <- base_valida()
  bom$valor_fob_dolar <- 999
  gravar_parquet(bom, destino)

  # Fonte que reprova de propósito: sem passar ano_inicial (default é 2014,
  # ANO_INICIAL), a lacuna 2014-2023 garante reprovação sem depender de mais
  # nenhum detalhe da fixture.
  anual <- gravar_parquet(base_valida(), file.path(dir, "anos.parquet"))

  r <- consolidar_e_validar(c(anual), destino)

  expect_false(r$ok)
  expect_true(file.exists(destino))

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  total <- DBI::dbGetQuery(con, sprintf(
    "SELECT SUM(valor_fob_dolar) AS total FROM read_parquet('%s')", destino))$total
  expect_equal(total, sum(bom$valor_fob_dolar))

  # Nenhum temporário deve sobrar no diretório de destino.
  restantes <- list.files(dir, pattern = "^\\.consolidar_tmp_")
  expect_length(restantes, 0)
})

test_that("consolidar_e_validar promove o consolidado para o destino quando a validação passa", {
  dir <- tempfile("consolidar_e_validar_ok"); dir.create(dir)
  destino <- file.path(dir, "final.parquet")
  anual <- gravar_parquet(base_valida(), file.path(dir, "anos.parquet"))

  # faixa_valor/faixa_peso = NULL: mesmo motivo de validar_fixture() acima --
  # os totais do fixture (dezenas/centenas de dólares) ficam bem abaixo de
  # qualquer faixa plausível real, e não é isso que este teste verifica.
  r <- consolidar_e_validar(c(anual), destino, ano_inicial = 2024L,
                            faixa_valor = NULL, faixa_peso = NULL)

  expect_true(r$ok)
  expect_true(file.exists(destino))
  restantes <- list.files(dir, pattern = "^\\.consolidar_tmp_")
  expect_length(restantes, 0)
})

# --- I6: tolerância de regressão customizável --------------------------------
# etl/run.R lê ETL_TOLERANCIA_REGRESSAO (default 0,01) e repassa como
# `tolerancia` para consolidar_e_validar()/validar_parquet(). Isto prova que
# o parâmetro é de fato respeitado: uma variação que reprova com a
# tolerância default passa quando uma tolerância maior é informada.

test_that("tolerância customizada em consolidar_e_validar é respeitada", {
  dir <- tempfile("consolidar_e_validar_tol"); dir.create(dir)
  destino <- file.path(dir, "final.parquet")
  anual <- gravar_parquet(base_valida(), file.path(dir, "anos.parquet"))

  # Total real de 2024 no fixture é 1200 (ver "parquet íntegro passa" acima).
  # totais_anteriores$"2024" = 1140 -> variação de +5,26%: reprova com a
  # tolerância default (1%) e passa com uma tolerância maior (10%).
  totais_ref <- list("2024" = 1140)

  r_default <- consolidar_e_validar(c(anual), destino, ano_inicial = 2024L,
                                    totais_anteriores = totais_ref,
                                    faixa_valor = NULL, faixa_peso = NULL)
  expect_false(r_default$ok)
  expect_true(any(grepl("regress", r_default$problemas, ignore.case = TRUE)))
  expect_false(file.exists(destino))

  r_tolerante <- consolidar_e_validar(c(anual), destino, ano_inicial = 2024L,
                                      totais_anteriores = totais_ref,
                                      tolerancia = 0.10,
                                      faixa_valor = NULL, faixa_peso = NULL)
  expect_true(r_tolerante$ok)
  expect_true(file.exists(destino))
})
