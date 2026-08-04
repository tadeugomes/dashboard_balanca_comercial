source(file.path("..", "..", "etl", "R", "validar.R"))

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
