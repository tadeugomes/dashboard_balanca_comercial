source(file.path("..", "..", "etl", "R", "estado.R"))

test_that("ler_estado devolve estrutura vazia quando não há arquivo", {
  e <- ler_estado(file.path(tempdir(), "inexistente.json"))
  expect_equal(length(e$arquivos), 0L)
  expect_equal(length(e$totais_por_ano), 0L)
})

test_that("gravar e reler preserva o conteúdo", {
  caminho <- tempfile(fileext = ".json")
  estado <- list(
    atualizado_em = "2026-08-04T12:00:00Z",
    arquivos = list(EXP_2025 = list(last_modified = "Thu, 05 Feb 2026 18:21:06 GMT",
                                    content_length = "113715007")),
    totais_por_ano = list(exportacao = list("2024" = 1200))
  )

  gravar_estado(estado, caminho)
  lido <- ler_estado(caminho)

  expect_equal(lido$arquivos$EXP_2025$content_length, "113715007")
  expect_equal(lido$totais_por_ano$exportacao[["2024"]], 1200)
})

test_that("precisa_atualizar seleciona apenas o que mudou", {
  fontes <- data.frame(
    chave = c("EXP_2025", "EXP_2026"),
    url = c("u1", "u2"),
    stringsAsFactors = FALSE
  )
  estado <- list(arquivos = list(
    EXP_2025 = list(last_modified = "A", content_length = "1"),
    EXP_2026 = list(last_modified = "B", content_length = "2")
  ))
  remotos <- list(
    EXP_2025 = list(last_modified = "A", content_length = "1"),  # igual
    EXP_2026 = list(last_modified = "C", content_length = "9")   # mudou
  )

  pendentes <- precisa_atualizar(fontes, estado, remotos)

  expect_equal(pendentes$chave, "EXP_2026")
})

test_that("precisa_atualizar inclui arquivo nunca visto", {
  fontes <- data.frame(chave = "EXP_2027", url = "u", stringsAsFactors = FALSE)
  remotos <- list(EXP_2027 = list(last_modified = "X", content_length = "5"))

  pendentes <- precisa_atualizar(fontes, list(arquivos = list()), remotos)

  expect_equal(nrow(pendentes), 1L)
})
