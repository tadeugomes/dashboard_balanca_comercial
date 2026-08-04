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
validar_parquet <- function(caminho, totais_anteriores = NULL,
                            tolerancia = 0.01, ano_inicial = ANO_INICIAL) {
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
    "SELECT ano, COUNT(DISTINCT mes) AS meses, SUM(valor_fob_dolar) AS total
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

  # --- integridade ----------------------------------------------------------
  ruins <- DBI::dbGetQuery(con, sprintf(
    "SELECT
       COUNT(*) FILTER (WHERE valor_fob_dolar IS NULL
                           OR peso_liquido_kg IS NULL) AS nulos,
       COUNT(*) FILTER (WHERE valor_fob_dolar < 0
                           OR peso_liquido_kg < 0)     AS negativos,
       COUNT(*) FILTER (WHERE no_pais IS NULL OR no_uf IS NULL
                           OR no_regiao IS NULL
                           OR no_cuci_grupo IS NULL)   AS chaves_nulas
     FROM %s", fonte))

  if (ruins$nulos > 0) {
    problemas <- c(problemas, paste0(ruins$nulos, " linhas com medida nula"))
  }
  if (ruins$negativos > 0) {
    problemas <- c(problemas, paste0(ruins$negativos,
                                     " linhas com medida negativa"))
  }
  if (ruins$chaves_nulas > 0) {
    problemas <- c(problemas, paste0(ruins$chaves_nulas,
                                     " linhas com chave nula (join falhou)"))
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
