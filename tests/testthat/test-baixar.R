source(file.path("..", "..", "etl", "R", "baixar.R"))

test_that("converter_para_utf8 traduz acentos de ISO-8859-1", {
  origem <- tempfile(fileext = ".csv")
  # Grava "Índia" e "África" em latin1, como o MDIC publica.
  con <- file(origem, open = "wb")
  writeBin(iconv("NO_PAIS\nÍndia\nÁfrica do Sul\n", "UTF-8", "ISO-8859-1",
                 toRaw = TRUE)[[1]], con)
  close(con)

  converter_para_utf8(origem)

  linhas <- readLines(origem, encoding = "UTF-8")
  expect_equal(linhas[2], "Índia")
  expect_equal(linhas[3], "África do Sul")
  expect_false(any(grepl("�", linhas)))
})

test_that("converter_para_utf8 é idempotente em arquivo já ASCII", {
  origem <- tempfile(fileext = ".csv")
  writeLines(c("CO_ANO;CO_MES", "2026;01"), origem)
  antes <- readLines(origem)

  converter_para_utf8(origem)

  expect_equal(readLines(origem), antes)
})

test_that("baixar_arquivo desiste após esgotar as tentativas", {
  destino <- tempfile(fileext = ".csv")
  expect_error(
    baixar_arquivo("https://balanca.economia.gov.br/inexistente-xyz.csv",
                   destino, tentativas = 2L),
    "Falha ao baixar"
  )
})
