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
