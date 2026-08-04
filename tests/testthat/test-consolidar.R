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
