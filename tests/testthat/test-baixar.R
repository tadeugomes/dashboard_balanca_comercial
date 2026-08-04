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
    baixar_arquivo("http://127.0.0.1:1/arquivo.csv",
                   destino, tentativas = 2L, espera_base = 0.1),
    "Falha ao baixar"
  )
})

test_that("baixar_arquivo sem tentativas repetidas não espera", {
  destino <- tempfile(fileext = ".csv")
  tempo <- system.time(
    tryCatch(
      baixar_arquivo("http://127.0.0.1:1/arquivo.csv",
                     destino, tentativas = 1L, espera_base = 100),
      error = function(e) NULL
    )
  )
  # Com tentativas = 1, não há espera. Mesmo com espera_base = 100,
  # deve ser bem rápido (< 1 segundo).
  expect_lt(tempo["elapsed"], 1.0)
})

test_that("baixar_arquivo com múltiplas tentativas espera de forma crescente", {
  destino <- tempfile(fileext = ".csv")
  tempo <- system.time(
    tryCatch(
      baixar_arquivo("http://127.0.0.1:1/arquivo.csv",
                     destino, tentativas = 4L, espera_base = 0.2),
      error = function(e) NULL
    )
  )
  # Com tentativas = 4L e espera_base = 0.2:
  # Espera crescente: 0.2*1 + 0.2*2 + 0.2*3 = 0.2 + 0.4 + 0.6 = 1.2s
  # Espera constante: 0.2 + 0.2 + 0.2 = 0.6s
  # Limiar 0.9s separa bem as duas hipóteses, com ~0.3s de margem em cada lado.
  # Sys.sleep nunca demora menos que o pedido, máquina lenta empurra para cima (sem falso negativo).
  expect_gt(tempo["elapsed"], 0.9)
})

test_that("validador_csv aceita CSV com colunas esperadas", {
  arquivo <- tempfile(fileext = ".csv")
  writeLines("CO_ANO;CO_MES;VL_EXPORTACAO\n2026;01;1000", arquivo)

  validador <- validador_csv(c("CO_ANO", "CO_MES", "VL_EXPORTACAO"))
  expect_true(validador(arquivo))
})

test_that("validador_csv rejeita CSV faltando colunas", {
  arquivo <- tempfile(fileext = ".csv")
  writeLines("CO_ANO;CO_MES\n2026;01", arquivo)

  validador <- validador_csv(c("CO_ANO", "VL_EXPORTACAO"))
  expect_false(validador(arquivo))
})

test_that("validador_csv é função que retorna função", {
  validador <- validador_csv(c("COL1", "COL2"))
  expect_true(is.function(validador))

  # Arquivo com colunas esperadas
  arquivo_ok <- tempfile(fileext = ".csv")
  writeLines("COL1;COL2;COL3", arquivo_ok)
  expect_true(validador(arquivo_ok))

  # Arquivo faltando coluna
  arquivo_invalido <- tempfile(fileext = ".csv")
  writeLines("COL1;COL3", arquivo_invalido)
  expect_false(validador(arquivo_invalido))
})
