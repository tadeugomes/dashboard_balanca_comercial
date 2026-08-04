# Download dos arquivos da fonte e normalização de codificação.
# Este módulo não sabe o que os arquivos contêm — recebe URL e destino.

# Baixa com repetição e espera crescente. O servidor do MDIC é lento e derruba
# conexões em arquivos grandes; desistir na primeira falha tornaria o pipeline
# não confiável.
baixar_arquivo <- function(url, destino, tentativas = 3L, espera_base = 5,
                           validador = NULL) {
  dir.create(dirname(destino), recursive = TRUE, showWarnings = FALSE)

  for (tentativa in seq_len(tentativas)) {
    parcial <- paste0(destino, ".parcial")
    resultado <- try(
      curl::curl_download(url, parcial, quiet = TRUE, mode = "wb"),
      silent = TRUE
    )

    if (!inherits(resultado, "try-error") && file.exists(parcial) &&
        file.size(parcial) > 0) {
      # Se há validador, aplica agora. Conteúdo inválido é falha permanente.
      if (!is.null(validador)) {
        if (!validador(parcial)) {
          unlink(parcial)
          stop("Conteúdo inválido em ", url)
        }
      }

      file.rename(parcial, destino)
      return(invisible(destino))
    }

    unlink(parcial)
    if (tentativa < tentativas) {
      espera <- espera_base * tentativa
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

# Retorna uma função validadora que verifica se um arquivo CSV contém
# todas as colunas esperadas na primeira linha. Uso: passar o resultado
# como argumento `validador` para `baixar_arquivo()`.
validador_csv <- function(colunas_esperadas) {
  function(caminho) {
    linhas <- tryCatch(
      readLines(caminho, n = 1, encoding = "UTF-8"),
      error = function(e) ""
    )

    if (length(linhas) == 0) {
      return(FALSE)
    }

    primeira_linha <- linhas[1]
    all(sapply(colunas_esperadas, function(coluna) {
      grepl(coluna, primeira_linha, fixed = TRUE)
    }))
  }
}
