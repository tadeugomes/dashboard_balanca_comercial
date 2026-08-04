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
