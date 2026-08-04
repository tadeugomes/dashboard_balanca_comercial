source(file.path("..", "..", "etl", "R", "fontes.R"))

test_that("fontes_anuais gera duas linhas por ano, uma por fluxo", {
  f <- fontes_anuais(ano_min = 2014L, ano_max = 2016L)
  expect_equal(nrow(f), 6L)
  expect_setequal(unique(f$fluxo), c("exportacao", "importacao"))
  expect_setequal(unique(f$ano), 2014:2016)
})

test_that("fontes_anuais monta a URL e a chave no formato do MDIC", {
  f <- fontes_anuais(ano_min = 2025L, ano_max = 2025L)
  exp <- f[f$fluxo == "exportacao", ]
  expect_equal(exp$chave, "EXP_2025")
  expect_equal(
    exp$url,
    "https://balanca.economia.gov.br/balanca/bd/comexstat-bd/ncm/EXP_2025.csv"
  )
  imp <- f[f$fluxo == "importacao", ]
  expect_equal(imp$chave, "IMP_2025")
})

test_that("fontes_auxiliares lista as quatro tabelas necessárias", {
  a <- fontes_auxiliares()
  expect_setequal(a$chave, c("PAIS", "UF", "NCM", "NCM_CUCI"))
  expect_true(all(grepl("^https://.*/tabelas/[A-Z_]+\\.csv$", a$url)))
})

test_that("fontes_anuais rejeita intervalo invertido", {
  expect_error(fontes_anuais(2020L, 2015L), "ano_max")
})
