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
#
# `dir_cache` é obrigatório e é o que fecha o defeito "consolidação a partir
# de cache expirado": não basta o estado.json dizer que um ano já foi visto,
# o parquet daquele ano tem que EXISTIR em dir_cache, senão a consolidação em
# run.R monta a série com esse ano faltando. No GitHub Actions o diretório de
# cache (etl/.trabalho/anos) vive só no actions/cache, que expira depois de 7
# dias sem uso — como o cron é mensal, ele está garantidamente frio em toda
# execução agendada. Cache frio deixa de significar "saída truncada" e passa
# a significar apenas "reprocessamento completo" (mais lento, mas correto).
# A verificação fica aqui — e não como filtro posterior em run.R — porque é
# esta função, e só ela, quem decide "pendente ou não"; um filtro externo
# duplicaria a regra de nome do parquet (fluxo + ano) e criaria uma segunda
# fonte de verdade que um autor futuro poderia esquecer de chamar.
#
# Exceção: um registro com `nao_publicado = TRUE` (ver run.R, ramo de
# "Conteúdo inválido") nunca terá parquet em dir_cache — o MDIC ainda não
# publicou aquele ano, não há dado para gerar. Para esses, a ausência de
# parquet é esperada e não deve reenfileirar o ano; só a mudança dos
# metadados remotos (Last-Modified/Content-Length, quando o MDIC finalmente
# publica o arquivo de verdade) o traz de volta à fila. Sem essa distinção, a
# checagem de cache do parágrafo acima reinseriria esse ano na fila para
# sempre, e o atalho "nenhuma mudança na fonte" (que é o que torna o cron
# barato) nunca mais dispararia a partir do primeiro ano ainda não publicado.
precisa_atualizar <- function(fontes, estado, remotos, dir_cache) {
  mudou <- vapply(seq_len(nrow(fontes)), function(i) {
    chave <- fontes$chave[i]
    registrado <- estado$arquivos[[chave]]
    if (is.null(registrado)) return(TRUE)

    remoto <- remotos[[chave]]
    if (is.null(remoto)) return(TRUE)

    metadados_mudaram <-
      !identical(as.character(registrado$last_modified),
                 as.character(remoto$last_modified)) ||
      !identical(as.character(registrado$content_length),
                 as.character(remoto$content_length))

    if (metadados_mudaram) return(TRUE)

    # Metadados batem. "Não publicado" nunca vai ter parquet -- e está certo
    # não ter; não é pendência.
    if (isTRUE(registrado$nao_publicado)) return(FALSE)

    caminho_parquet <- file.path(
      dir_cache, paste0(fontes$fluxo[i], "_", fontes$ano[i], ".parquet")
    )
    !file.exists(caminho_parquet)
  }, logical(1))

  fontes[mudou, , drop = FALSE]
}

`%||%` <- function(x, y) if (is.null(x)) y else x
