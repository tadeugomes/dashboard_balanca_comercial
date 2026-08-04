# Registro do que já foi processado. É este arquivo — e não os dados — que o
# repositório versiona, servindo de rastro auditável das atualizações.

estado_vazio <- function() {
  list(atualizado_em = NULL, arquivos = list(), totais_por_ano = list())
}

ler_estado <- function(caminho) {
  if (!file.exists(caminho)) {
    return(estado_vazio())
  }

  estado <- tryCatch(
    jsonlite::fromJSON(caminho, simplifyVector = FALSE),
    error = function(e) {
      warning(sprintf(
        "Estado em '%s' está corrompido (%s); tratando como vazio — os anos afetados serão reprocessados.",
        caminho, conditionMessage(e)
      ), call. = FALSE)
      NULL
    }
  )

  if (is.null(estado)) {
    return(estado_vazio())
  }

  list(
    atualizado_em = estado$atualizado_em,
    arquivos = estado$arquivos %||% list(),
    totais_por_ano = estado$totais_por_ano %||% list()
  )
}

# Grava de forma atômica: escreve num arquivo temporário no mesmo diretório
# do destino e só então renomeia. file.rename() é atômico em POSIX quando
# origem e destino compartilham o sistema de arquivos — por isso o temporário
# não pode ir para tempdir(). Se a escrita falhar, o temporário é removido.
gravar_estado <- function(estado, caminho) {
  dir.create(dirname(caminho), recursive = TRUE, showWarnings = FALSE)

  temporario <- tempfile(pattern = ".estado_tmp_", tmpdir = dirname(caminho))
  on.exit(if (file.exists(temporario)) file.remove(temporario), add = TRUE)

  jsonlite::write_json(estado, temporario, auto_unbox = TRUE, pretty = TRUE)

  sucesso <- file.rename(temporario, caminho)
  if (!sucesso) {
    stop(sprintf("Falha ao renomear '%s' para '%s'.", temporario, caminho))
  }

  invisible(caminho)
}

# Compara a versão remota com a registrada. Um arquivo nunca visto, ou cujo
# Last-Modified ou tamanho mudou, entra na fila. Quando o servidor não informa
# esses cabeçalhos, os valores vêm vazios e a comparação falha — reprocessamos
# por precaução.
precisa_atualizar <- function(fontes, estado, remotos) {
  mudou <- vapply(fontes$chave, function(chave) {
    registrado <- estado$arquivos[[chave]]
    if (is.null(registrado)) return(TRUE)

    remoto <- remotos[[chave]]
    if (is.null(remoto)) return(TRUE)

    !identical(as.character(registrado$last_modified),
               as.character(remoto$last_modified)) ||
    !identical(as.character(registrado$content_length),
               as.character(remoto$content_length))
  }, logical(1))

  fontes[mudou, , drop = FALSE]
}

`%||%` <- function(x, y) if (is.null(x)) y else x
