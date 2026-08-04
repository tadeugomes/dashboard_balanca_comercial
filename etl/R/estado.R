# Registro do que já foi processado. É este arquivo — e não os dados — que o
# repositório versiona, servindo de rastro auditável das atualizações.

ler_estado <- function(caminho) {
  if (!file.exists(caminho)) {
    return(list(atualizado_em = NULL, arquivos = list(),
                totais_por_ano = list()))
  }

  estado <- jsonlite::fromJSON(caminho, simplifyVector = FALSE)

  list(
    atualizado_em = estado$atualizado_em,
    arquivos = estado$arquivos %||% list(),
    totais_por_ano = estado$totais_por_ano %||% list()
  )
}

gravar_estado <- function(estado, caminho) {
  dir.create(dirname(caminho), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(estado, caminho, auto_unbox = TRUE, pretty = TRUE)
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
