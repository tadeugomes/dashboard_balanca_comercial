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
