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

test_that("consolidar_fluxo preserva colunas com schemas divergentes", {
  dir <- tempfile("consolidar"); dir.create(dir)

  # Parquet 1: 9 colunas padrão
  a <- gravar_parquet(linha(2024, 100), file.path(dir, "2024.parquet"))

  # Parquet 2: colunas em ordem diferente (simula arquivo legado)
  df2 <- data.frame(
    valor_fob_dolar = 200,
    ano = 2025L,
    mes = 1L,
    peso_liquido_kg = 10,
    nome_mes = "jan.",
    no_cuci_grupo = "Trigo",
    no_regiao = "Nordeste",
    no_uf = "Maranhão",
    no_pais = "Índia",
    stringsAsFactors = FALSE
  )
  b <- gravar_parquet(df2, file.path(dir, "2025.parquet"))

  destino <- file.path(dir, "final.parquet")

  consolidar_fluxo(c(a, b), destino)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Verificar que nenhuma coluna se perdeu
  saida <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM read_parquet('%s') ORDER BY ano", destino))

  expect_equal(nrow(saida), 2L)
  # Verificar que todas as 9 colunas estão presentes
  expected_cols <- c("no_pais", "no_uf", "no_regiao", "no_cuci_grupo", "nome_mes", "ano", "mes", "peso_liquido_kg", "valor_fob_dolar")
  expect_equal(sort(names(saida)), sort(expected_cols))
  # Verificar valores de ambos os anos
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
