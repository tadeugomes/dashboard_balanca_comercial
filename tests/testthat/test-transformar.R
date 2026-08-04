source(file.path("..", "..", "etl", "R", "transformar.R"))

# O testthat roda a partir de tests/testthat, então o default de CAMINHO_SQL
# (relativo à raiz do projeto) não resolveria daqui.
SQL_TESTE <- file.path("..", "..", "etl", "sql", "agregado_ncm.sql")

# Monta um conjunto mínimo de arquivos no formato exato do MDIC.
montar_fixture <- function() {
  dir <- tempfile("fixture")
  dir.create(file.path(dir, "aux"), recursive = TRUE)

  writeLines(c(
    '"CO_ANO";"CO_MES";"CO_NCM";"CO_UNID";"CO_PAIS";"SG_UF_NCM";"CO_VIA";"CO_URF";"QT_ESTAT";"KG_LIQUIDO";"VL_FOB"',
    '"2025";"01";"10011000";"10";"063";"MA";"01";"0817800";100;200;3000',
    '"2025";"01";"10011000";"10";"063";"MA";"01";"0817800";50;100;1000',
    '"2025";"05";"99999999";"10";"063";"CB";"01";"0817800";10;20;70'
  ), file.path(dir, "EXP_2025.csv"))

  writeLines(c(
    '"CO_PAIS";"CO_PAIS_ISON3";"CO_PAIS_ISOA3";"NO_PAIS";"NO_PAIS_ING";"NO_PAIS_ESP"',
    '"063";"076";"BRA";"Índia";"India";"India"'
  ), file.path(dir, "aux", "PAIS.csv"))

  writeLines(c(
    '"CO_UF";"SG_UF";"NO_UF";"NO_REGIAO"',
    '"21";"MA";"Maranhão";"REGIAO NORDESTE"',
    '"94";"CB";"Consumo de Bordo";"CONSUMO DE BORDO"'
  ), file.path(dir, "aux", "UF.csv"))

  writeLines(c(
    '"CO_NCM";"CO_UNID";"CO_SH6";"CO_PPE";"CO_PPI";"CO_FAT_AGREG";"CO_CUCI_ITEM";"CO_CGCE_N3";"CO_SIIT";"CO_ISIC_CLASSE";"CO_EXP_SUBSET";"NO_NCM_POR";"NO_NCM_ESP";"NO_NCM_ING"',
    '"10011000";"10";"100110";"0";"0";"1";"04110";"210";"1";"0111";"0";"Trigo";"Trigo";"Wheat"',
    '"99999999";"10";"999999";"0";"0";"1";"99999";"999";"1";"9999";"0";"Outros";"Otros";"Other"'
  ), file.path(dir, "aux", "NCM.csv"))

  writeLines(c(
    '"CO_CUCI_ITEM";"NO_CUCI_ITEM";"CO_CUCI_SUB";"NO_CUCI_SUB";"CO_CUCI_GRUPO";"NO_CUCI_GRUPO";"CO_CUCI_DIVISAO";"NO_CUCI_DIVISAO";"CO_CUCI_SEC";"NO_CUCI_SEC"',
    '"04110";"Trigo";"041";"Trigo";"041";"Trigo e centeio, não moídos";"04";"Cereais";"0";"Alimentos"'
  ), file.path(dir, "aux", "NCM_CUCI.csv"))

  dir
}

ler_saida <- function(caminho) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s') ORDER BY mes",
                               caminho))
}

test_that("transformar_ano agrega e produz o schema exato do dashboard", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")

  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  expect_equal(
    names(saida),
    c("no_pais", "no_uf", "no_regiao", "no_cuci_grupo",
      "ano", "mes", "nome_mes", "peso_liquido_kg", "valor_fob_dolar")
  )
  # As duas linhas de janeiro compartilham todas as chaves e devem somar.
  expect_equal(nrow(saida), 2L)
  expect_equal(saida$valor_fob_dolar[1], 4000)
  expect_equal(saida$peso_liquido_kg[1], 300)
})

test_that("transformar_ano normaliza a região e preserva acentos", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  expect_equal(saida$no_regiao[1], "Nordeste")   # de "REGIAO NORDESTE"
  expect_equal(saida$no_uf[1], "Maranhão")
  expect_equal(saida$no_pais[1], "Índia")
})

test_that("códigos especiais de UF caem em Não Declarada", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  linha <- saida[saida$mes == 5, ]
  expect_equal(linha$no_uf, "Consumo de Bordo")
  expect_equal(linha$no_regiao, "Não Declarada")  # de "CONSUMO DE BORDO"
})

test_that("NCM sem grupo CUCI recebe string vazia, nunca NA", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  linha <- saida[saida$mes == 5, ]
  expect_equal(linha$no_cuci_grupo, "")
  expect_false(anyNA(saida))
})

test_that("nome_mes usa os rótulos abreviados do dashboard", {
  dir <- montar_fixture()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  expect_equal(saida$nome_mes[saida$mes == 1], "jan.")
  expect_equal(saida$nome_mes[saida$mes == 5], "maio")  # sem ponto
})

# Teste adicional (fora do brief): a fixture original de montar_fixture()
# só cobre a região Nordeste e o caso especial "Não Declarada". Um teste de
# mutação em 'Centro-Oeste' (trocado por 'Centro Oeste', sem hífen) passou
# batido pela suíte original porque nenhuma linha exercitava esse ramo do
# CASE. Este teste cobre as cinco regiões nomeadas para fechar essa lacuna.
montar_fixture_regioes <- function() {
  dir <- tempfile("fixture_regioes")
  dir.create(file.path(dir, "aux"), recursive = TRUE)

  writeLines(c(
    '"CO_ANO";"CO_MES";"CO_NCM";"CO_UNID";"CO_PAIS";"SG_UF_NCM";"CO_VIA";"CO_URF";"QT_ESTAT";"KG_LIQUIDO";"VL_FOB"',
    '"2025";"01";"10011000";"10";"063";"PA";"01";"0817800";1;1;1',
    '"2025";"02";"10011000";"10";"063";"MA";"01";"0817800";1;1;1',
    '"2025";"03";"10011000";"10";"063";"SP";"01";"0817800";1;1;1',
    '"2025";"04";"10011000";"10";"063";"RS";"01";"0817800";1;1;1',
    '"2025";"05";"10011000";"10";"063";"GO";"01";"0817800";1;1;1'
  ), file.path(dir, "EXP_2025.csv"))

  writeLines(c(
    '"CO_PAIS";"CO_PAIS_ISON3";"CO_PAIS_ISOA3";"NO_PAIS";"NO_PAIS_ING";"NO_PAIS_ESP"',
    '"063";"076";"BRA";"Índia";"India";"India"'
  ), file.path(dir, "aux", "PAIS.csv"))

  writeLines(c(
    '"CO_UF";"SG_UF";"NO_UF";"NO_REGIAO"',
    '"15";"PA";"Pará";"REGIAO NORTE"',
    '"21";"MA";"Maranhão";"REGIAO NORDESTE"',
    '"35";"SP";"São Paulo";"REGIAO SUDESTE"',
    '"43";"RS";"Rio Grande do Sul";"REGIAO SUL"',
    '"52";"GO";"Goiás";"REGIAO CENTRO OESTE"'
  ), file.path(dir, "aux", "UF.csv"))

  writeLines(c(
    '"CO_NCM";"CO_UNID";"CO_SH6";"CO_PPE";"CO_PPI";"CO_FAT_AGREG";"CO_CUCI_ITEM";"CO_CGCE_N3";"CO_SIIT";"CO_ISIC_CLASSE";"CO_EXP_SUBSET";"NO_NCM_POR";"NO_NCM_ESP";"NO_NCM_ING"',
    '"10011000";"10";"100110";"0";"0";"1";"04110";"210";"1";"0111";"0";"Trigo";"Trigo";"Wheat"'
  ), file.path(dir, "aux", "NCM.csv"))

  writeLines(c(
    '"CO_CUCI_ITEM";"NO_CUCI_ITEM";"CO_CUCI_SUB";"NO_CUCI_SUB";"CO_CUCI_GRUPO";"NO_CUCI_GRUPO";"CO_CUCI_DIVISAO";"NO_CUCI_DIVISAO";"CO_CUCI_SEC";"NO_CUCI_SEC"',
    '"04110";"Trigo";"041";"Trigo";"041";"Trigo e centeio, não moídos";"04";"Cereais";"0";"Alimentos"'
  ), file.path(dir, "aux", "NCM_CUCI.csv"))

  dir
}

test_that("de-para de região cobre as cinco regiões, inclusive Centro-Oeste com hífen", {
  dir <- montar_fixture_regioes()
  destino <- file.path(dir, "saida.parquet")
  transformar_ano(file.path(dir, "EXP_2025.csv"), file.path(dir, "aux"),
                  destino, caminho_sql = SQL_TESTE)
  saida <- ler_saida(destino)

  esperado <- c("1" = "Norte", "2" = "Nordeste", "3" = "Sudeste",
                "4" = "Sul", "5" = "Centro-Oeste")
  for (mes in names(esperado)) {
    linha <- saida[saida$mes == as.integer(mes), ]
    expect_equal(linha$no_regiao, unname(esperado[mes]),
                 info = paste("mes", mes))
  }
})
