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

test_that("gravar_estado não deixa arquivo temporário residual no diretório de destino", {
  dir_destino <- tempfile()
  dir.create(dir_destino)
  caminho <- file.path(dir_destino, "estado.json")
  estado <- list(atualizado_em = "2026-08-04T12:00:00Z",
                 arquivos = list(), totais_por_ano = list())

  gravar_estado(estado, caminho)

  arquivos_no_dir <- list.files(dir_destino, all.files = TRUE, no.. = TRUE)
  expect_equal(arquivos_no_dir, "estado.json")
})

test_that("gravar_estado sobre arquivo já existente substitui o conteúdo", {
  caminho <- tempfile(fileext = ".json")
  estado_antigo <- list(atualizado_em = "2026-01-01T00:00:00Z",
                         arquivos = list(EXP_2020 = list(last_modified = "A",
                                                          content_length = "1")),
                         totais_por_ano = list())
  gravar_estado(estado_antigo, caminho)

  estado_novo <- list(atualizado_em = "2026-08-04T12:00:00Z",
                       arquivos = list(EXP_2025 = list(last_modified = "B",
                                                        content_length = "2")),
                       totais_por_ano = list())
  gravar_estado(estado_novo, caminho)

  lido <- ler_estado(caminho)
  expect_null(lido$arquivos$EXP_2020)
  expect_equal(lido$arquivos$EXP_2025$content_length, "2")
})

test_that("gravar_estado não corrompe o arquivo de destino se a escrita falhar no meio do caminho", {
  dir_destino <- tempfile()
  dir.create(dir_destino)
  caminho <- file.path(dir_destino, "estado.json")
  estado_original <- list(
    atualizado_em = "2026-01-01T00:00:00Z",
    arquivos = list(EXP_2020 = list(last_modified = "A", content_length = "1")),
    totais_por_ano = list()
  )
  gravar_estado(estado_original, caminho)
  conteudo_original <- readLines(caminho)

  # Simula uma escrita interrompida: grava conteúdo truncado/inválido no
  # arquivo que jsonlite::write_json recebeu e então falha, como aconteceria
  # com uma queda de energia ou processo morto no meio da gravação. Se
  # gravar_estado escrever direto no destino, é o destino que fica truncado;
  # se escrever num temporário, é só o temporário que fica truncado.
  testthat::local_mocked_bindings(
    write_json = function(x, path, ...) {
      writeLines('{"arquivos": {', path)
      stop("falha simulada no meio da escrita")
    },
    .package = "jsonlite"
  )

  expect_error(
    gravar_estado(list(atualizado_em = "Y", arquivos = list(), totais_por_ano = list()),
                  caminho)
  )

  # O destino não pode ter sido corrompido pela escrita malsucedida.
  expect_equal(readLines(caminho), conteudo_original)

  # Nenhum arquivo temporário residual, mesmo após a falha.
  arquivos_no_dir <- list.files(dirname(caminho), all.files = TRUE, no.. = TRUE)
  expect_equal(arquivos_no_dir, basename(caminho))
})

test_that("ler_estado devolve estrutura vazia e avisa quando o JSON está corrompido", {
  caminho <- tempfile(fileext = ".json")
  writeLines('{"arquivos": {', caminho)

  expect_warning(e <- ler_estado(caminho))
  expect_equal(length(e$arquivos), 0L)
  expect_equal(length(e$totais_por_ano), 0L)
  expect_null(e$atualizado_em)
})
