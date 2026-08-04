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
