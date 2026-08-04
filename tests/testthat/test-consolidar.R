source(file.path("..", "..", "etl", "R", "consolidar.R"))

gravar_parquet <- function(df, caminho) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb::duckdb_register(con, "tmp", df)
  DBI::dbExecute(con, sprintf(
    "COPY (SELECT no_pais, no_uf, no_regiao, no_cuci_grupo, nome_mes, CAST(ano AS BIGINT) AS ano, CAST(mes AS BIGINT) AS mes, peso_liquido_kg, valor_fob_dolar FROM tmp) TO '%s' (FORMAT PARQUET)", caminho))
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

test_that("consolidar_fluxo empilha os anos preservando ordem, valores, schema e tipos", {
  dir <- tempfile("consolidar"); dir.create(dir)
  a <- gravar_parquet(linha(2024, 100), file.path(dir, "2024.parquet"))
  b <- gravar_parquet(linha(2025, 200), file.path(dir, "2025.parquet"))
  destino <- file.path(dir, "final.parquet")

  consolidar_fluxo(c(a, b), destino)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Verificar dados
  saida <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM read_parquet('%s') ORDER BY ano", destino))

  expect_equal(nrow(saida), 2L)
  expect_equal(saida$ano, c(2024L, 2025L))
  expect_equal(saida$valor_fob_dolar, c(100, 200))

  # Verificar schema e tipos
  DBI::dbExecute(con, sprintf(
    "CREATE TEMP TABLE tmp_schema AS SELECT * FROM read_parquet('%s')", destino))
  schema <- DBI::dbGetQuery(con, "DESCRIBE tmp_schema")

  # Esperado: 9 colunas em ordem
  esperado <- data.frame(
    column_name = c("no_pais", "no_uf", "no_regiao", "no_cuci_grupo", "nome_mes", "ano", "mes", "peso_liquido_kg", "valor_fob_dolar"),
    column_type = c("VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "BIGINT", "BIGINT", "DOUBLE", "DOUBLE"),
    stringsAsFactors = FALSE
  )

  expect_equal(schema$column_name, esperado$column_name)
  expect_equal(schema$column_type, esperado$column_type)
})

test_that("consolidar_fluxo alinha e preserva colunas extras via union_by_name", {
  dir <- tempfile("consolidar"); dir.create(dir)

  # Parquet A (ano 2024): 9 colunas padrão
  a <- gravar_parquet(linha(2024, 100), file.path(dir, "2024.parquet"))

  # Parquet B (ano 2025): 9 colunas padrão + coluna extra co_ncm
  # Simula arquivo gerado por versão diferente do ETL que inclui código NCM
  df_com_ncm <- data.frame(
    no_pais = "Índia", no_uf = "Maranhão", no_regiao = "Nordeste",
    no_cuci_grupo = "Trigo", ano = 2025L, mes = 1L,
    nome_mes = "jan.", peso_liquido_kg = 10, valor_fob_dolar = 200,
    co_ncm = "1001.90.00",
    stringsAsFactors = FALSE
  )

  # Grava parquet B com coluna extra
  con_aux <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con_aux, shutdown = TRUE), add = TRUE)
  duckdb::duckdb_register(con_aux, "tmp", df_com_ncm)
  DBI::dbExecute(con_aux, sprintf(
    "COPY (SELECT no_pais, no_uf, no_regiao, no_cuci_grupo, nome_mes, CAST(ano AS BIGINT) AS ano, CAST(mes AS BIGINT) AS mes, peso_liquido_kg, valor_fob_dolar, co_ncm FROM tmp) TO '%s' (FORMAT PARQUET)",
    file.path(dir, "2025.parquet")))
  b <- file.path(dir, "2025.parquet")

  destino <- file.path(dir, "final.parquet")

  # Consolidar com union_by_name=true protege a coluna extra
  consolidar_fluxo(c(a, b), destino)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Verificar dados e schema
  saida <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM read_parquet('%s') ORDER BY ano", destino))

  expect_equal(nrow(saida), 2L)
  # Verificar que a coluna extra sobreviveu
  expected_cols <- c("no_pais", "no_uf", "no_regiao", "no_cuci_grupo", "nome_mes", "ano", "mes", "peso_liquido_kg", "valor_fob_dolar", "co_ncm")
  expect_equal(sort(names(saida)), sort(expected_cols))
  # Linha de A tem NULL na coluna extra
  expect_true(is.na(saida$co_ncm[1]))
  # Linha de B tem valor na coluna extra
  expect_equal(saida$co_ncm[2], "1001.90.00")
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
