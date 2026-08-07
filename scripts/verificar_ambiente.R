#!/usr/bin/env Rscript
# Confere se esta máquina está pronta para rodar o dashboard e o ETL, e
# reporta de forma legível o que falta e como corrigir cada item.
#
# Não instala nada, não restaura o renv, não roda testthat -- só
# diagnostica. Pensado para quem acabou de clonar o repositório numa
# máquina nova (ver README, seção "Preparar uma máquina nova").
#
# Uso (a partir da raiz do projeto):
#   Rscript scripts/verificar_ambiente.R
#
# Saída: uma seção por verificação (R, Quarto, pacotes do renv.lock, dados
# em dados/, bibliotecas de sistema quando em Linux) e um veredito final.

# --- utilitários de saída -----------------------------------------------

linha <- function() cat(strrep("-", 70), "\n", sep = "")

titulo <- function(txt) {
  cat("\n")
  cat("== ", txt, " ==\n", sep = "")
}

ok      <- function(...) cat("[OK]    ", ..., "\n", sep = "")
aviso   <- function(...) cat("[AVISO] ", ..., "\n", sep = "")
falha   <- function(...) cat("[FALHA] ", ..., "\n", sep = "")
info    <- function(...) cat("        ", ..., "\n", sep = "")

# Raiz do projeto: assume-se que o script roda a partir dela (mesma
# convenção do resto do repositório -- ver README). Se renv.lock não
# existir no diretório atual, avisa e tenta mesmo assim com o que houver.
raiz_ok <- file.exists("renv.lock") && file.exists("dashboard.qmd")
if (!raiz_ok) {
  aviso(
    "Não encontrei renv.lock e/ou dashboard.qmd no diretório atual (",
    getwd(), ")."
  )
  info("Rode este script a partir da raiz do projeto:")
  info("  Rscript scripts/verificar_ambiente.R")
}

# Acumulador do veredito final: cada verificação empurra "ok", "aviso" ou
# "falha" para cá.
status_geral <- character(0)
registrar <- function(nivel) status_geral <<- c(status_geral, nivel)

cat("Verificação de ambiente -- dashboard_balanca_comercial\n")
linha()

# --- 1. Versão do R -------------------------------------------------------

titulo("1. Versão do R")

versao_r_atual <- paste(R.version$major, R.version$minor, sep = ".")

versao_r_lockfile <- NA_character_
lock <- NULL
if (file.exists("renv.lock")) {
  lock <- tryCatch(jsonlite::fromJSON("renv.lock"), error = function(e) NULL)
  if (!is.null(lock) && !is.null(lock$R$Version)) {
    versao_r_lockfile <- lock$R$Version
  }
}

info("R instalado nesta máquina: ", versao_r_atual)
if (is.na(versao_r_lockfile)) {
  aviso("Não consegui ler a versão travada em renv.lock (arquivo ausente ou ilegível).")
  registrar("aviso")
} else {
  info("R travado em renv.lock:   ", versao_r_lockfile)
  if (identical(versao_r_atual, versao_r_lockfile)) {
    ok("A versão do R bate com o lockfile.")
    registrar("ok")
  } else {
    falha(
      "A versão do R diverge do lockfile (", versao_r_atual, " != ",
      versao_r_lockfile, ")."
    )
    info(
      "Isto é o PONTO CRÍTICO do projeto: renv::restore() foi calibrado para R ",
      versao_r_lockfile, " e tende a FALHAR AO COMPILAR pacotes numa versão mais",
      " nova (testado: magrittr quebra sob R mais novo)."
    )
    info("Como corrigir, em ordem de preferência:")
    info("  a) instalar R ", versao_r_lockfile, " -- ex.: `rig install ", versao_r_lockfile, "` e `rig default ", versao_r_lockfile, "`")
    info("  b) usar o Dockerfile do projeto (`docker build -t dashboard .`), que fixa R ", versao_r_lockfile, " na imagem")
    info("  c) aceitar divergir do lockfile: instalar as versões atuais dos pacotes com renv::restore() ou install.packages(),")
    info("     mas NUNCA rodar renv::snapshot() nessa condição -- isso gravaria as versões novas no lockfile e mudaria")
    info("     o ambiente de produção (shinyapps.io) sem que ninguém tenha decidido isso deliberadamente. Ver README,")
    info("     seção \"A restrição do renv\".")
    registrar("falha")
  }
}

# --- 2. Quarto -------------------------------------------------------------

titulo("2. Quarto")

quarto_bin <- Sys.which("quarto")
if (nzchar(quarto_bin)) {
  versao_quarto <- tryCatch(
    system2("quarto", "--version", stdout = TRUE, stderr = FALSE),
    error = function(e) NA_character_
  )
  ok("Quarto encontrado em ", quarto_bin, " (versão ", versao_quarto, ").")
  if (!is.na(versao_quarto) && !identical(versao_quarto, "1.5.57")) {
    aviso(
      "A versão instalada (", versao_quarto, ") difere da fixada no workflow",
      " (1.5.57, ver .github/workflows/atualizar-dados.yml). Isso normalmente só afeta",
      " a inspeção/empacotamento feitos pelo rsconnect ao publicar -- não deveria",
      " impedir `quarto render` local, mas fique atento a diferenças de saída."
    )
    registrar("aviso")
  } else {
    registrar("ok")
  }
} else {
  falha("Quarto não encontrado no PATH.")
  info("Instale a partir de https://quarto.org/docs/get-started/ (versão 1.5.57, mesma do workflow),")
  info("ou use o Dockerfile do projeto, que já instala essa versão.")
  registrar("falha")
}

# --- 3. Pacotes do renv.lock -------------------------------------------------

titulo("3. Pacotes R do renv.lock")

if (is.null(lock)) {
  aviso("Não foi possível ler renv.lock; pulando a checagem de pacotes.")
  registrar("aviso")
} else {
  pacotes_lock <- lock$Packages
  nomes_lock <- names(pacotes_lock)
  versoes_lock <- vapply(pacotes_lock, function(p) {
    v <- p$Version
    if (is.null(v)) NA_character_ else v
  }, character(1))

  instalados <- as.data.frame(installed.packages()[, c("Package", "Version")],
                               stringsAsFactors = FALSE)
  rownames(instalados) <- NULL

  ausentes <- character(0)
  divergentes <- data.frame(pacote = character(0), lockfile = character(0),
                             instalado = character(0), stringsAsFactors = FALSE)

  for (i in seq_along(nomes_lock)) {
    pkg <- nomes_lock[i]
    # [[i]], não [i]: versoes_lock é um vetor NOMEADO (vapply herda os
    # nomes de pacotes_lock); [i] manteria o atributo "names" no
    # resultado, e identical() abaixo levaria esse atributo em conta,
    # comparando "1.3.0" (com nome) contra "1.3.0" (sem nome) como
    # diferentes mesmo quando o texto é idêntico.
    v_lock <- versoes_lock[[i]]
    linha_inst <- instalados[instalados$Package == pkg, ]
    if (nrow(linha_inst) == 0) {
      ausentes <- c(ausentes, pkg)
    } else if (!is.na(v_lock) && !identical(linha_inst$Version[1], v_lock)) {
      divergentes <- rbind(divergentes, data.frame(
        pacote = pkg, lockfile = v_lock, instalado = linha_inst$Version[1],
        stringsAsFactors = FALSE
      ))
    }
  }

  info(length(nomes_lock), " pacotes no lockfile; ", nrow(instalados), " pacotes instalados nesta biblioteca R.")

  if (length(ausentes) == 0) {
    ok("Nenhum pacote do lockfile está totalmente ausente.")
  } else {
    falha(length(ausentes), " pacote(s) do lockfile NÃO estão instalados:")
    for (p in ausentes) info("  - ", p)
    info("Corrija com: renv::restore(confirm = FALSE)")
    registrar("falha")
  }

  if (nrow(divergentes) == 0) {
    ok("Nenhuma divergência de versão entre o instalado e o lockfile.")
    if (length(ausentes) == 0) registrar("ok")
  } else {
    aviso(nrow(divergentes), " pacote(s) instalados em versão DIFERENTE da travada no lockfile:")
    n_mostrar <- min(nrow(divergentes), 15)
    for (i in seq_len(n_mostrar)) {
      info(
        "  - ", divergentes$pacote[i], ": instalado ", divergentes$instalado[i],
        " / lockfile ", divergentes$lockfile[i]
      )
    }
    if (nrow(divergentes) > n_mostrar) {
      info("  ... e mais ", nrow(divergentes) - n_mostrar, " pacote(s).")
    }
    info(
      "Isso é esperado numa máquina com R mais novo que o lockfile (ver seção 1)."
    )
    info(
      "O dashboard e os testes podem funcionar mesmo assim, mas não há garantia --"
    )
    info(
      "NÃO rode renv::snapshot() para 'corrigir' isto: gravaria essas versões"
    )
    info(
      "novas no lockfile e mudaria o ambiente de produção. Ver README, seção",
      " \"A restrição do renv\"."
    )
    registrar("aviso")
  }
}

# --- 4. Dados (parquets em dados/) ------------------------------------------

titulo("4. Dados (dados/*.parquet)")

arquivos_esperados <- c(
  exportacao = "dados/ncm_exportacao_agrupado.parquet",
  importacao = "dados/ncm_importacao_agrupado.parquet"
)

algum_ausente <- FALSE
for (rotulo in names(arquivos_esperados)) {
  caminho <- arquivos_esperados[[rotulo]]
  if (!file.exists(caminho)) {
    falha("Arquivo ausente: ", caminho)
    algum_ausente <- TRUE
    next
  }
  tamanho_mb <- round(file.info(caminho)$size / 1024^2, 1)
  ok("Encontrado: ", caminho, " (", tamanho_mb, " MB)")

  tem_arrow <- requireNamespace("arrow", quietly = TRUE)
  if (!tem_arrow) {
    aviso("  Pacote 'arrow' não disponível -- não consigo checar a cobertura de anos.")
    next
  }
  anos <- tryCatch({
    ds <- arrow::open_dataset(caminho)
    anos_df <- dplyr::collect(dplyr::distinct(ds, ano))
    sort(anos_df$ano)
  }, error = function(e) {
    aviso("  Não consegui ler ", caminho, " para checar cobertura de anos: ", conditionMessage(e))
    NULL
  })
  if (!is.null(anos) && length(anos) > 0) {
    info(
      "  Cobertura de anos (", rotulo, "): ", min(anos), "-", max(anos),
      " (", length(anos), " ano(s))"
    )
  }
}

if (algum_ausente) {
  info("Os parquets NÃO são versionados no git. Para obtê-los:")
  info("  1) baixar da Release mais recente:")
  info("     gh release download -R tadeugomes/dashboard_balanca_comercial -D dados --clobber -p \"*.parquet\"")
  info("  2) ou gerar rodando o pipeline: Rscript etl/run.R  (ver README, \"Como rodar o pipeline\")")
  registrar("falha")
} else {
  registrar("ok")
}

# --- 5. Bibliotecas de sistema (só em Linux) --------------------------------

titulo("5. Bibliotecas de sistema")

sistema <- Sys.info()[["sysname"]]
if (!identical(sistema, "Linux")) {
  info(
    "Sistema operacional: ", sistema, ". Esta checagem só se aplica a Linux",
    " (a lista abaixo é a que o workflow do GitHub Actions instala via apt-get;",
    " no macOS os equivalentes já vêm com o sistema ou via Homebrew/CRAN binário,",
    " e não há uma lista centralizada aqui para checar automaticamente)."
  )
  info(
    "Se você for rodar isto num container/servidor Linux, ou construir o",
    " Dockerfile, use a lista do README (seção \"Bibliotecas de sistema\") ou",
    " o próprio Dockerfile como referência."
  )
  registrar("aviso")
} else {
  # Mesma lista, pela mesma razão, do passo "Instalar dependências de sistema
  # dos pacotes R" em .github/workflows/atualizar-dados.yml -- fonte da
  # verdade validada em execução real de CI.
  libs_apt <- c(
    "libglpk-dev", "libgdal-dev", "libproj-dev", "libgeos-dev",
    "libudunits2-dev", "libxml2-dev", "libssl-dev", "libcurl4-openssl-dev",
    "libpng-dev", "libfontconfig1-dev", "libharfbuzz-dev", "libfribidi-dev"
  )

  tem_dpkg <- nzchar(Sys.which("dpkg"))
  if (!tem_dpkg) {
    aviso("`dpkg` não encontrado -- não consigo checar pacotes apt automaticamente.")
    info("Lista completa esperada: ", paste(libs_apt, collapse = " "))
    registrar("aviso")
  } else {
    faltando <- character(0)
    for (lib in libs_apt) {
      cod <- suppressWarnings(system2(
        "dpkg", c("-s", lib), stdout = FALSE, stderr = FALSE
      ))
      if (!identical(cod, 0L)) faltando <- c(faltando, lib)
    }
    if (length(faltando) == 0) {
      ok("Todas as ", length(libs_apt), " bibliotecas de sistema esperadas estão instaladas.")
      registrar("ok")
    } else {
      falha(length(faltando), " biblioteca(s) de sistema ausente(s):")
      for (l in faltando) info("  - ", l)
      info("Instale com:")
      info("  sudo apt-get update && sudo apt-get install -y \\")
      info("    ", paste(faltando, collapse = " \\\n    "))
      info(
        "A ausência de libglpk-dev, em particular, já derrubou o CI deste",
        " projeto: o pacote igraph não carrega sem ela (libglpk.so.40 não encontrado)."
      )
      registrar("falha")
    }
  }
}

# --- Veredito final ----------------------------------------------------------

titulo("Veredito")

n_falha <- sum(status_geral == "falha")
n_aviso <- sum(status_geral == "aviso")
n_ok    <- sum(status_geral == "ok")

info(n_ok, " verificação(ões) OK, ", n_aviso, " com aviso, ", n_falha, " com falha.")

if (n_falha > 0) {
  falha("Ambiente NÃO está pronto. Resolva os itens marcados [FALHA] acima antes de rodar o dashboard ou o ETL.")
} else if (n_aviso > 0) {
  aviso("Ambiente utilizável, mas com ressalvas (ver itens [AVISO] acima). Revise antes de confiar os resultados a produção.")
} else {
  ok("Ambiente pronto. Sugestão de próximo passo: Rscript -e 'testthat::test_dir(\"tests/testthat\")' (esperado: PASS 119).")
}

linha()
