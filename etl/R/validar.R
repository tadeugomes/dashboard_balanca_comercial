# Portão de sanidade sobre o parquet consolidado.
# Não sabe de onde o arquivo veio — recebe um caminho e devolve um relatório.
# Isso permite testá-lo com dados sintéticos, sem rede.

SCHEMA_ESPERADO <- c(
  no_pais         = "VARCHAR",
  no_uf           = "VARCHAR",
  no_regiao       = "VARCHAR",
  no_cuci_grupo   = "VARCHAR",
  ano             = "BIGINT",
  mes             = "BIGINT",
  nome_mes        = "VARCHAR",
  peso_liquido_kg = "DOUBLE",
  valor_fob_dolar = "DOUBLE"
)

ANO_INICIAL <- 2014L

# ano_inicial é parâmetro para que os testes possam usar fixtures curtos sem
# que a verificação de lacuna acuse todos os anos ausentes desde 2014.
#
# limiar_vazio (verificação de join, ver seção abaixo): medição nos parquets
# de produção em 2026-08 encontrou 0 linhas vazias em 8.932.660 (4.537.239 de
# exportação + 4.395.421 de importação) nas três colunas monitoradas. Com
# essa base zero, 0,5% já é um limiar folgado -- e um join realmente quebrado
# (ex.: mudança de formato em CO_CUCI_ITEM que para de casar com a tabela
# auxiliar) produz perto de 100% de linhas vazias na coluna afetada, não uma
# fração marginal perto do limiar.
validar_parquet <- function(caminho, totais_anteriores = NULL,
                            tolerancia = 0.01, ano_inicial = ANO_INICIAL,
                            faixa_valor = c(50e3, 800e3),
                            faixa_peso  = c(50, 2000),
                            limiar_vazio = 0.005) {
  if (!file.exists(caminho)) {
    stop("Parquet não encontrado: ", caminho)
  }

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  fonte <- sprintf("read_parquet('%s')", normalizePath(caminho))
  problemas <- character(0)

  # --- schema ---------------------------------------------------------------
  # DESCRIBE devolve column_name/column_type nesta versão do DuckDB (1.5.5);
  # o alias abaixo preserva o restante do código, que usa name/type.
  colunas <- DBI::dbGetQuery(con, sprintf(
    "SELECT column_name AS name, column_type AS type
     FROM (DESCRIBE SELECT * FROM %s)", fonte))

  if (!identical(colunas$name, names(SCHEMA_ESPERADO))) {
    problemas <- c(problemas, paste0(
      "schema divergente: esperado [", paste(names(SCHEMA_ESPERADO), collapse = ", "),
      "], obtido [", paste(colunas$name, collapse = ", "), "]"))
    # Sem o schema correto as demais verificações não fazem sentido.
    return(list(ok = FALSE, problemas = problemas, totais_por_ano = list()))
  }

  divergentes <- colunas$name[colunas$type != unname(SCHEMA_ESPERADO)]
  if (length(divergentes) > 0) {
    problemas <- c(problemas, paste0(
      "schema divergente nos tipos: ", paste(divergentes, collapse = ", ")))
  }

  # --- cobertura ------------------------------------------------------------
  cobertura <- DBI::dbGetQuery(con, sprintf(
    "SELECT ano, COUNT(DISTINCT mes) AS meses,
            SUM(valor_fob_dolar)  AS total,
            SUM(peso_liquido_kg)  AS peso_total
     FROM %s GROUP BY ano ORDER BY ano", fonte))

  anos <- cobertura$ano
  esperados <- seq(ano_inicial, max(anos))
  faltando <- setdiff(esperados, anos)
  if (length(faltando) > 0) {
    problemas <- c(problemas, paste0(
      "lacuna na série de anos: ", paste(faltando, collapse = ", ")))
  }

  # O ano mais recente pode estar em andamento; os anteriores, não.
  fechados <- cobertura[cobertura$ano < max(anos), ]
  incompletos <- fechados$ano[fechados$meses != 12L]
  if (length(incompletos) > 0) {
    problemas <- c(problemas, paste0(
      "ano fechado sem os 12 meses: ", paste(incompletos, collapse = ", ")))
  }

  # --- ordem de grandeza ------------------------------------------------------
  # Erro de escala (ex.: agregação que soma sem dividir por 1e6/1e9) produz um
  # número plausível o bastante para passar por todas as outras verificações
  # — em especial na primeira execução, quando ainda não existe
  # totais_anteriores para a regressão comparar. Vale só para anos fechados
  # com os 12 meses (mesmo critério da checagem acima): o ano corrente é
  # parcial por natureza e ficaria abaixo da faixa em janeiro, o que não é
  # um erro.
  fechados_completos <- fechados[fechados$meses == 12L, ]

  verificar_faixa <- function(valores, anos_ref, faixa, medida) {
    if (is.null(faixa)) return(character(0))
    fora <- which(valores < faixa[1] | valores > faixa[2])
    if (length(fora) == 0) return(character(0))
    sprintf(
      "ano %s: %s fora da faixa plausível [%.0f, %.0f] (observado %.0f)",
      anos_ref[fora], medida, faixa[1], faixa[2], valores[fora])
  }

  problemas <- c(problemas,
    verificar_faixa(fechados_completos$total, fechados_completos$ano,
                     faixa_valor, "valor_fob_dolar"),
    verificar_faixa(fechados_completos$peso_total, fechados_completos$ano,
                     faixa_peso, "peso_liquido_kg"))

  # --- integridade ----------------------------------------------------------
  ruins <- DBI::dbGetQuery(con, sprintf(
    "SELECT
       COUNT(*) FILTER (WHERE valor_fob_dolar IS NULL
                           OR peso_liquido_kg IS NULL) AS nulos,
       COUNT(*) FILTER (WHERE valor_fob_dolar < 0
                           OR peso_liquido_kg < 0)     AS negativos
     FROM %s", fonte))

  if (ruins$nulos > 0) {
    problemas <- c(problemas, paste0(ruins$nulos, " linhas com medida nula"))
  }
  if (ruins$negativos > 0) {
    problemas <- c(problemas, paste0(ruins$negativos,
                                     " linhas com medida negativa"))
  }

  # --- join (chaves de texto vazias) -----------------------------------------
  # A spec original pedia checar no_uf/no_regiao/no_cuci_grupo NULOS. Mas o
  # SQL de agregação (etl/sql/agregado_ncm.sql) faz COALESCE(..., '') nessas
  # colunas -- de propósito, para o dashboard nunca mostrar "NA" na legenda.
  # Consequência colateral: NULL é impossível nelas, então a verificação
  # antiga (WHERE ... IS NULL) nunca disparava, mesmo com o LEFT JOIN
  # 100% quebrado. Por isso medimos STRING VAZIA, não NULL.
  total_linhas <- DBI::dbGetQuery(con, sprintf(
    "SELECT COUNT(*) AS n FROM %s", fonte))$n

  if (total_linhas > 0) {
    vazios <- DBI::dbGetQuery(con, sprintf(
      "SELECT
         COUNT(*) FILTER (WHERE no_uf = '')        AS no_uf,
         COUNT(*) FILTER (WHERE no_regiao = '')     AS no_regiao,
         COUNT(*) FILTER (WHERE no_cuci_grupo = '') AS no_cuci_grupo
       FROM %s", fonte))

    for (coluna in c("no_uf", "no_regiao", "no_cuci_grupo")) {
      n_vazios <- vazios[[coluna]]
      proporcao <- n_vazios / total_linhas
      if (proporcao > limiar_vazio) {
        problemas <- c(problemas, sprintf(
          "coluna %s: %d de %d linhas vazias (%.2f%%), acima do limiar de %.2f%% -- possível join quebrado",
          coluna, n_vazios, total_linhas, 100 * proporcao, 100 * limiar_vazio))
      }
    }
  }

  # --- codificação ----------------------------------------------------------
  # U+FFFD indica que um byte latin1 foi lido como UTF-8. Nenhuma verificação
  # numérica detectaria isso, e o resultado seria "Ãfrica do Sul" no painel.
  # chr(65533) em vez do literal: evita depender da codificação com que este
  # arquivo-fonte foi salvo.
  corrompidos <- DBI::dbGetQuery(con, sprintf(
    "SELECT COUNT(*) AS n FROM %s
     WHERE contains(no_pais, chr(65533))
        OR contains(no_uf, chr(65533))
        OR contains(no_cuci_grupo, chr(65533))", fonte))

  if (corrompidos$n > 0) {
    problemas <- c(problemas, paste0(
      corrompidos$n, " linhas com falha de codificação (U+FFFD)"))
  }

  # --- regressão ------------------------------------------------------------
  totais <- as.list(stats::setNames(cobertura$total, as.character(cobertura$ano)))

  if (!is.null(totais_anteriores)) {
    ano_corrente <- as.character(max(anos))
    for (ano in names(totais_anteriores)) {
      # O ano em andamento cresce a cada mês; comparar seria falso positivo.
      if (ano == ano_corrente || is.null(totais[[ano]])) next

      antes <- totais_anteriores[[ano]]
      agora <- totais[[ano]]
      if (antes > 0 && abs(agora - antes) / antes > tolerancia) {
        problemas <- c(problemas, sprintf(
          "regressão em %s: total variou %.2f%% (de %.0f para %.0f)",
          ano, 100 * (agora - antes) / antes, antes, agora))
      }
    }
  }

  list(
    ok = length(problemas) == 0,
    problemas = problemas,
    totais_por_ano = totais
  )
}

# Consolida um fluxo (lista de parquets anuais) e só publica o resultado em
# `destino` se ele passar por validar_parquet(). Escreve o consolidado num
# arquivo TEMPORÁRIO -- nunca direto em `destino` -- para que uma validação
# reprovada não destrua um parquet bom já publicado ali antes: sem essa
# guarda, `consolidar_fluxo()` gravava direto no destino e a decisão de
# aceitar ou não vinha só depois, tarde demais. No CI isso é inofensivo (o
# checkout é efêmero), mas numa execução local -- justamente a que o
# operador usa para investigar quando o workflow reprova -- é destrutivo.
#
# O temporário é criado com tmpdir = dirname(destino), e não em tempdir():
# file.rename() só é atômico quando origem e destino compartilham o mesmo
# sistema de arquivos. Mesmo padrão de gravar_estado(), em etl/R/estado.R.
#
# Depende de consolidar_fluxo() (etl/R/consolidar.R) já estar carregada no
# ambiente -- run.R garante isso sourceando etl/R/*.R inteiro antes de
# chamar esta função; os testes fazem o mesmo explicitamente.
consolidar_e_validar <- function(parquets_anuais, destino,
                                 totais_anteriores = NULL,
                                 ano_inicial = ANO_INICIAL,
                                 tolerancia = 0.01,
                                 limiar_vazio = 0.005,
                                 faixa_valor = c(50e3, 800e3),
                                 faixa_peso  = c(50, 2000)) {
  dir.create(dirname(destino), recursive = TRUE, showWarnings = FALSE)
  temporario <- tempfile(pattern = ".consolidar_tmp_",
                        tmpdir = dirname(destino), fileext = ".parquet")

  # Cobre tanto a reprovação esperada (validação com problemas) quanto uma
  # falha inesperada (ex.: erro do DuckDB durante a consolidação): em ambos
  # os casos o temporário não deve sobreviver, e `destino` não deve ser
  # tocado.
  relatorio <- tryCatch({
    consolidar_fluxo(parquets_anuais, temporario)
    validar_parquet(temporario, totais_anteriores = totais_anteriores,
                    ano_inicial = ano_inicial, tolerancia = tolerancia,
                    limiar_vazio = limiar_vazio,
                    faixa_valor = faixa_valor, faixa_peso = faixa_peso)
  }, error = function(e) {
    unlink(temporario)
    stop(e)
  })

  if (relatorio$ok) {
    sucesso <- file.rename(temporario, destino)
    if (!sucesso) {
      unlink(temporario)
      stop(sprintf("Falha ao mover '%s' para '%s'.", temporario, destino))
    }
  } else {
    unlink(temporario)
  }

  relatorio
}
