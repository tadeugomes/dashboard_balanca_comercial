#!/usr/bin/env Rscript
# Compara o custo de memória e tempo das duas estratégias de leitura dos
# parquets de comércio exterior, para decidir qual sobrevive ao teto de
# 1 GB de RAM do plano gratuito do shinyapps.io.
#
# Estratégias comparadas (mesmo trabalho útil nas duas: para cada UF em
# c("Maranhão", "Nordeste", "Brasil"), filtrar e agregar valor_fob_dolar
# por ano/mês):
#
#   - "preguiçoso": open_dataset() sem collect() — filtra e agrega dentro
#     do Arrow, só materializa o resultado final (pequeno). É o que está
#     em produção hoje (dashboard.qmd).
#   - "ansioso": collect() do recorte inteiro por UF, cacheado com
#     memoise::memoise() — é o que existe no branch `paralelizacao`. Como
#     o cache do memoise nunca é limpo em produção, a segunda troca de UF
#     na mesma sessão do Shiny é instantânea, mas os dados coletados
#     ficam retidos em memória. O pior caso real é uma sessão que já
#     visitou as três UFs de exportação e importação — todas cacheadas
#     simultaneamente.
#
# Duas medidas de memória são reportadas para cada cenário:
#
#   - "gc pico" = coluna "max used (Mb)" de gc(), somando Ncells e Vcells,
#     lida depois de gc(reset = TRUE) no início do cenário. É o pico do
#     heap gerenciado pelo R. Não enxerga buffers nativos do Arrow (ex.:
#     memory-map do parquet, buffers do C++), então subestima o custo
#     real de estratégias que passam mais tempo dentro do Arrow.
#   - "rss pico" = maior leitura de RSS (memória residente do processo)
#     via `ps -o rss=` no PID do R, amostrada depois de cada UF. Inclui
#     heap do R, buffers nativos do Arrow e todo o overhead do processo —
#     é o número que efetivamente conta contra o teto de RAM do
#     shinyapps.io.
#
# Quando os dois números divergem, "rss pico" é a fonte de verdade.
#
# IMPORTANTE sobre isolamento: RSS não cai de volta ao patamar anterior só
# porque o R rodou gc() — o alocador do sistema tipicamente não devolve
# páginas ao SO. Medir vários cenários dentro do MESMO processo R
# contaminaria o "pico" de um cenário com o resíduo do anterior (isso foi
# observado na prática: o cenário preguiçoso rodado depois do ansioso
# herdava ~500 MB de base). Por isso este script roda cada cenário em um
# processo `Rscript` novo (via system2()) quando chamado sem argumentos —
# cada linha da tabela final é uma medição isolada, com RSS partindo do
# zero real do processo.
#
# Uso:
#   Rscript scripts/medir_leitura.R                    # roda tudo, imprime a tabela
#   Rscript scripts/medir_leitura.R <variante>:<escopo> # roda 1 cenário (uso interno)

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(memoise)
})

ARQUIVOS <- c(
  exportacao = "dados/ncm_exportacao_agrupado.parquet",
  importacao = "dados/ncm_importacao_agrupado.parquet"
)
UFS <- c("Maranhão", "Nordeste", "Brasil")

ESQUEMA <- schema(
  no_pais = string(), no_uf = string(), no_regiao = string(),
  no_cuci_grupo = string(), ano = int64(), mes = int64(),
  nome_mes = string(), peso_liquido_kg = float64(), valor_fob_dolar = float64()
)

# --- Medição de memória -----------------------------------------------

rss_mb <- function() {
  pid <- Sys.getpid()
  saida <- tryCatch(
    system(sprintf("ps -o rss= -p %d", pid), intern = TRUE, ignore.stderr = TRUE),
    error = function(e) NA_character_
  )
  valor <- suppressWarnings(as.numeric(trimws(saida[1])))
  if (length(valor) == 0 || is.na(valor)) return(NA_real_)
  valor / 1024 # KB -> MB
}

gc_peak_mb <- function() {
  g <- gc()
  sum(g[, ncol(g)]) # soma as colunas "(Mb)" de "max used" (Ncells + Vcells)
}

# --- Estratégia 1: Arrow preguiçoso ------------------------------------

preguicoso_uf <- function(arquivo, uf) {
  open_dataset(arquivo, schema = ESQUEMA) |>
    filter(no_uf == uf | no_regiao == uf | uf == "Brasil") |>
    group_by(ano, mes) |>
    summarise(v = sum(valor_fob_dolar, na.rm = TRUE), .groups = "drop") |>
    collect()
}

# --- Estratégia 2: collect() ansioso com memoise ------------------------
# Um único cache compartilhado entre exportação e importação, como
# aconteceria em produção (ncm_data_loader() é memoizada uma vez só e
# recebe tipo + uf).

carregar_uf_memo <- memoise::memoise(function(arquivo, uf) {
  open_dataset(arquivo, schema = ESQUEMA) |>
    filter(no_uf == uf | no_regiao == uf | uf == "Brasil") |>
    collect()
})

ansioso_uf <- function(arquivo, uf) {
  dados <- carregar_uf_memo(arquivo, uf) # fica retido no cache do memoise
  dados |>
    group_by(ano, mes) |>
    summarise(v = sum(valor_fob_dolar, na.rm = TRUE), .groups = "drop")
}

# --- Execução de um cenário -----------------------------------------------

medir <- function(rotulo, arquivos, ufs, f) {
  gc(full = TRUE, reset = TRUE)
  rss_base <- rss_mb()
  amostras_rss <- numeric(0)

  inicio <- Sys.time()
  for (arquivo in arquivos) {
    for (uf in ufs) {
      invisible(f(arquivo, uf))
      amostras_rss <- c(amostras_rss, rss_mb())
    }
  }
  duracao <- as.numeric(difftime(Sys.time(), inicio, units = "secs"))

  pico_gc <- gc_peak_mb()
  pico_rss <- max(amostras_rss, na.rm = TRUE)

  list(
    rotulo = rotulo, duracao = duracao,
    gc_pico_mb = pico_gc, rss_pico_mb = pico_rss, rss_base_mb = rss_base
  )
}

CENARIOS <- list(
  "preguicoso:exportacao"  = list(variante = "preguicoso", arquivos = ARQUIVOS[["exportacao"]]),
  "preguicoso:importacao"  = list(variante = "preguicoso", arquivos = ARQUIVOS[["importacao"]]),
  "preguicoso:combinado"   = list(variante = "preguicoso", arquivos = ARQUIVOS),
  "ansioso:exportacao"     = list(variante = "ansioso", arquivos = ARQUIVOS[["exportacao"]]),
  "ansioso:importacao"     = list(variante = "ansioso", arquivos = ARQUIVOS[["importacao"]]),
  "ansioso:combinado"      = list(variante = "ansioso", arquivos = ARQUIVOS)
)

rodar_cenario <- function(chave) {
  cfg <- CENARIOS[[chave]]
  f <- if (cfg$variante == "preguicoso") preguicoso_uf else ansioso_uf
  r <- medir(chave, cfg$arquivos, UFS, f)
  # Linha em formato fixo para o processo-pai (orquestrador) parsear.
  cat(sprintf(
    "RESULTADO|%s|%.4f|%.2f|%.2f|%.2f\n",
    chave, r$duracao, r$gc_pico_mb, r$rss_pico_mb, r$rss_base_mb
  ))
}

orquestrar <- function() {
  args_completos <- commandArgs(trailingOnly = FALSE)
  arquivo_script <- sub("^--file=", "", grep("^--file=", args_completos, value = TRUE)[1])

  cat("Linhas exportação:", nrow(open_dataset(ARQUIVOS[["exportacao"]], schema = ESQUEMA)), "\n")
  cat("Linhas importação:", nrow(open_dataset(ARQUIVOS[["importacao"]], schema = ESQUEMA)), "\n\n")
  cat("Cada linha abaixo roda em um processo Rscript novo (isolamento de RSS).\n\n")

  linhas <- list()
  for (chave in names(CENARIOS)) {
    cat(sprintf("-- %s --\n", chave))
    saida <- system2("Rscript", c(shQuote(arquivo_script), chave), stdout = TRUE, stderr = TRUE)
    cat(paste(saida, collapse = "\n"), "\n\n")
    linha_resultado <- grep("^RESULTADO\\|", saida, value = TRUE)
    if (length(linha_resultado) == 0) {
      stop(sprintf("Cenário %s não produziu RESULTADO (ver saída acima).", chave))
    }
    partes <- strsplit(linha_resultado[1], "\\|")[[1]]
    linhas[[chave]] <- list(
      cenario = partes[2],
      duracao = as.numeric(partes[3]),
      gc_pico_mb = as.numeric(partes[4]),
      rss_pico_mb = as.numeric(partes[5]),
      rss_base_mb = as.numeric(partes[6])
    )
  }

  cat("======================================================================\n")
  cat("TABELA FINAL (cada linha = processo Rscript isolado)\n")
  cat("======================================================================\n")
  cat(sprintf("%-28s | %9s | %14s | %14s\n", "cenário", "tempo (s)", "gc pico (MB)", "rss pico (MB)"))
  for (l in linhas) {
    cat(sprintf("%-28s | %9.2f | %14.1f | %14.1f\n", l$cenario, l$duracao, l$gc_pico_mb, l$rss_pico_mb))
  }

  invisible(linhas)
}

# --- Entrada -----------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0) {
  orquestrar()
} else {
  chave <- args[1]
  if (!chave %in% names(CENARIOS)) {
    stop(sprintf("Cenário desconhecido: %s. Opções: %s", chave, paste(names(CENARIOS), collapse = ", ")))
  }
  rodar_cenario(chave)
}
