#!/usr/bin/env Rscript
# Orquestrador do pipeline de atualização do Comex Stat.
#
#   Rscript etl/run.R              # processa apenas o que mudou na fonte
#   Rscript etl/run.R --forcar     # reprocessa todos os anos
#
# Sai com código 0 se tudo correu bem (inclusive quando nada mudou) e 1 quando
# a validação reprova ou nenhum ano pôde ser processado — o que impede o
# deploy no workflow.
#
# NOTA SOBRE O SERVIDOR DO MDIC: ele não devolve 404 para arquivo inexistente
# — responde HTTP 200, text/plain, com o código-fonte PHP do Joomla (~1420
# bytes). Como fontes_anuais() gera candidatos até o ano corrente, um arquivo
# ainda não publicado (comum em janeiro, por exemplo) resultaria nesse corpo
# sendo baixado como se fosse dado válido. Por isso todo baixar_arquivo()
# abaixo recebe um `validador`, que confere o cabeçalho da primeira linha do
# CSV antes de aceitar o download.
#
# NOTA SOBRE RESUMABILIDADE (rodada de correção 1): a primeira execução real
# dos 13 anos mostrou que o servidor do MDIC derruba conexões nos arquivos de
# importação, que chegam a ser o dobro dos de exportação (IMP_2014 tem 133 MB
# contra 68 MB de EXP_2014). Duas mudanças tratam isso:
#   (a) `estado$arquivos[[chave]]` é gravado em disco logo depois de cada ano
#       ser transformado com sucesso, não só no fim do script. Assim, se a
#       execução abortar mais adiante (rede ruim num arquivo grande, por
#       exemplo), os anos já processados NÃO são rebaixados na próxima
#       tentativa — só o que falhou. `totais_por_ano` (a referência de
#       regressão) continua só sendo gravado quando a validação do parquet
#       consolidado passa: são garantias distintas, e só a segunda depende do
#       resultado da validação.
#   (b) os downloads de arquivo ANUAL (não das tabelas auxiliares, que são
#       pequenas) usam mais tentativas e mais espera entre elas do que o
#       default de `baixar_arquivo()` — ver TENTATIVAS_ANUAIS/ESPERA_ANUAIS
#       abaixo. Os defaults do módulo baixar.R não mudam: os testes de
#       backoff dependem deles, e o módulo não precisa saber que existem
#       arquivos grandes.

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

for (arquivo in list.files("etl/R", pattern = "\\.R$", full.names = TRUE)) {
  source(arquivo)
}

# Variáveis de ambiente ETL_* existem só para permitir validar este
# orquestrador sem rodar os 13 anos completos (~4 GB, 30-60 min) nem
# sobrescrever os parquets de produção em dados/. Uso:
#
#   ETL_ANO_MIN=2014 ETL_ANO_MAX=2014 ETL_DIR_SAIDA=/tmp/saida-teste \
#     ETL_CAMINHO_ESTADO=/tmp/estado-teste.json Rscript etl/run.R
#
# Sem nenhuma delas definida, o comportamento é idêntico ao original:
# intervalo 2014..ano corrente, saída em dados/, estado em etl/estado.json.
CAMINHO_ESTADO <- Sys.getenv("ETL_CAMINHO_ESTADO", "etl/estado.json")
DIR_TRABALHO   <- Sys.getenv("ETL_DIR_TRABALHO", "etl/.trabalho")
DIR_CACHE      <- file.path(DIR_TRABALHO, "anos")
DIR_AUX        <- file.path(DIR_TRABALHO, "aux")
DIR_SAIDA      <- Sys.getenv("ETL_DIR_SAIDA", "dados")

ANO_MIN_ENV <- Sys.getenv("ETL_ANO_MIN", "")
ANO_MAX_ENV <- Sys.getenv("ETL_ANO_MAX", "")

# Colunas mínimas esperadas no cabeçalho de cada fonte. Servem só para
# distinguir um CSV real do corpo de erro do Joomla — não são uma validação
# de schema completa (isso é papel de validar_parquet, no fim do pipeline).
COLUNAS_ANUAIS <- c("CO_ANO", "CO_MES", "CO_NCM", "SG_UF_NCM", "CO_PAIS",
                    "KG_LIQUIDO", "VL_FOB")

COLUNAS_AUXILIARES <- list(
  PAIS     = c("CO_PAIS", "NO_PAIS"),
  UF       = c("CO_UF", "SG_UF", "NO_UF", "NO_REGIAO"),
  NCM      = c("CO_NCM", "CO_CUCI_ITEM"),
  NCM_CUCI = c("CO_CUCI_ITEM", "NO_CUCI_GRUPO")
)

# Arquivos anuais de importação chegam a 175 MB e o servidor do MDIC derruba
# conexões neles com alguma frequência. 5 tentativas com espera_base = 15
# dão esperas de 15s, 30s, 45s e 60s entre tentativas (~2,5 min de paciência
# por arquivo), contra os 3 tentativas / 5s-10s do default de baixar_arquivo,
# calibrado para as tabelas auxiliares (poucos MB). As auxiliares continuam
# usando o default do módulo.
TENTATIVAS_ANUAIS <- 5L
ESPERA_ANUAIS      <- 15

forcar <- "--forcar" %in% commandArgs(trailingOnly = TRUE)

registrar <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "|", ..., "\n")
}

# --- 1. manifesto -----------------------------------------------------------
registrar("Consultando versões remotas...")

fontes <- if (nzchar(ANO_MIN_ENV) || nzchar(ANO_MAX_ENV)) {
  args_ano <- list()
  if (nzchar(ANO_MIN_ENV)) args_ano$ano_min <- as.integer(ANO_MIN_ENV)
  if (nzchar(ANO_MAX_ENV)) args_ano$ano_max <- as.integer(ANO_MAX_ENV)
  do.call(fontes_anuais, args_ano)
} else {
  fontes_anuais()
}
estado <- ler_estado(CAMINHO_ESTADO)

remotos <- lapply(stats::setNames(fontes$url, fontes$chave), metadados_remotos)

pendentes <- if (forcar) fontes else {
  precisa_atualizar(fontes, estado, remotos, dir_cache = DIR_CACHE)
}

if (nrow(pendentes) == 0) {
  registrar("Nenhuma mudança na fonte. Encerrando sem reprocessar.")
  quit(status = 0)
}

registrar(nrow(pendentes), "arquivo(s) a processar:",
          paste(pendentes$chave, collapse = ", "))

# --- 2. tabelas auxiliares --------------------------------------------------
registrar("Baixando tabelas auxiliares...")
dir.create(DIR_AUX, recursive = TRUE, showWarnings = FALSE)

auxiliares <- fontes_auxiliares()
for (i in seq_len(nrow(auxiliares))) {
  chave_aux <- auxiliares$chave[i]
  destino <- file.path(DIR_AUX, paste0(chave_aux, ".csv"))
  baixar_arquivo(auxiliares$url[i], destino,
                 validador = validador_csv(COLUNAS_AUXILIARES[[chave_aux]]))
  converter_para_utf8(destino)
}

# --- 3. download e transformação --------------------------------------------
dir.create(DIR_CACHE, recursive = TRUE, showWarnings = FALSE)

anos_pulados <- character(0)

for (i in seq_len(nrow(pendentes))) {
  item <- pendentes[i, ]
  registrar("Processando", item$chave, "...")

  csv <- file.path(DIR_TRABALHO, paste0(item$chave, ".csv"))

  # "Conteúdo inválido" (validador_csv rejeitou o cabeçalho) é falha do
  # ano — em geral porque o MDIC ainda não publicou o arquivo — mas não da
  # execução mensal como um todo: registramos e seguimos com os demais anos.
  # "Falha ao baixar" (esgotadas as tentativas de rede) é problema
  # transitório de infraestrutura, não do dado em si; não faz sentido varrer
  # os 26 arquivos sabendo que a rede está com problema, então interrompemos
  # a execução para que o operador investigue.
  tryCatch({
    baixar_arquivo(item$url, csv, tentativas = TENTATIVAS_ANUAIS,
                   espera_base = ESPERA_ANUAIS,
                   validador = validador_csv(COLUNAS_ANUAIS))

    parquet_ano <- file.path(DIR_CACHE,
                             paste0(item$fluxo, "_", item$ano, ".parquet"))
    transformar_ano(csv, DIR_AUX, parquet_ano)

    # O CSV bruto chega a 175 MB; o runner do Actions tem disco limitado.
    unlink(csv)

    # Grava AGORA, não só no fim: se a execução abortar mais adiante (outro
    # ano com falha de rede, por exemplo), este ano já não precisa ser
    # rebaixado na próxima tentativa. totais_por_ano (a referência de
    # regressão) é coisa distinta e só é gravado depois que a validação do
    # parquet consolidado passa, lá na etapa 4 -- não aqui.
    estado$arquivos[[item$chave]] <- remotos[[item$chave]]
    gravar_estado(estado, CAMINHO_ESTADO)
  }, error = function(e) {
    msg <- conditionMessage(e)
    unlink(csv)

    if (grepl("^Conteúdo inválido", msg)) {
      registrar("AVISO:", item$chave,
                "não publicado ou com conteúdo inválido -- pulando este ano.")
      anos_pulados <<- c(anos_pulados, item$chave)

      # Registra que este metadado remoto (o do corpo inválido, ex.: o PHP
      # do Joomla que o MDIC devolve para ano ainda não publicado) já foi
      # visto, marcando nao_publicado = TRUE. Isso NÃO é o mesmo que
      # registrar sucesso: não há parquet nem totais_por_ano para este ano.
      # É só "não adianta tentar de novo com este mesmo Last-Modified e
      # Content-Length" -- quando o MDIC publicar o arquivo de verdade, os
      # metadados remotos mudam e precisa_atualizar() reenfileira o ano
      # sozinho (ver estado.R). Sem isto, o ano fica pendente para sempre:
      # o atalho "nenhuma mudança na fonte" nunca mais dispara a partir do
      # primeiro ano não publicado, e toda execução mensal baixa auxiliares,
      # consolida e reimplanta mesmo sem dado novo algum.
      # <<- é obrigatório aqui: este bloco é o corpo de error = function(e)
      # {...}, então uma atribuição composta com <- comum (estado$arquivos[[
      # chave]] <- valor) criaria um `estado` local a essa função e nunca
      # chegaria ao `estado` do script (mesmo problema que anos_pulados <<-
      # já resolve acima). Com <<-, a atualização é feita no `estado` do
      # escopo delimitador, que é o que gravar_estado() usa a seguir.
      estado$arquivos[[item$chave]] <<- c(remotos[[item$chave]],
                                          list(nao_publicado = TRUE))
      gravar_estado(estado, CAMINHO_ESTADO)
    } else {
      registrar("ERRO ao processar", item$chave, ":", msg)
      registrar("Falha de rede (ou erro inesperado) -- interrompendo a execução.",
                "Os anos já processados nesta execução ficam registrados em",
                CAMINHO_ESTADO, "e a próxima tentativa retoma daqui.")
      quit(status = 1)
    }
  })
}

if (length(anos_pulados) > 0) {
  registrar(length(anos_pulados), "ano(s) pulado(s) por conteúdo inválido:",
            paste(anos_pulados, collapse = ", "))
}

# --- 4. consolidação e validação --------------------------------------------
resultado_ok <- TRUE

for (fluxo in c("exportacao", "importacao")) {
  anuais <- sort(list.files(DIR_CACHE, pattern = paste0("^", fluxo, "_"),
                            full.names = TRUE))

  if (length(anuais) == 0) {
    registrar("Nenhum ano disponível para consolidar em", fluxo,
              "-- nenhum ano pôde ser processado. Abortando.")
    quit(status = 1)
  }

  destino <- file.path(DIR_SAIDA, paste0("ncm_", fluxo, "_agrupado.parquet"))

  registrar("Consolidando", fluxo, "-", length(anuais), "anos")
  consolidar_fluxo(anuais, destino)

  relatorio <- validar_parquet(
    destino,
    totais_anteriores = estado$totais_por_ano[[fluxo]],
    ano_inicial = 2014L
  )

  if (relatorio$ok) {
    registrar("Validação de", fluxo, "OK")
    estado$totais_por_ano[[fluxo]] <- relatorio$totais_por_ano
  } else {
    resultado_ok <- FALSE
    registrar("VALIDAÇÃO REPROVOU", fluxo, ":")
    for (p in relatorio$problemas) registrar("   -", p)
  }
}

if (!resultado_ok) {
  registrar("Pipeline interrompido: totais de referência NÃO foram",
            "atualizados (os anos processados nesta execução já estão",
            "registrados em", CAMINHO_ESTADO, "e não serão rebaixados).")
  quit(status = 1)
}

# --- 5. registro ------------------------------------------------------------
estado$atualizado_em <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
gravar_estado(estado, CAMINHO_ESTADO)

registrar("Concluído.")
quit(status = 0)
