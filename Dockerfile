# Reproduz o ambiente do dashboard em qualquer máquina com Docker, sem
# precisar instalar R/Quarto diretamente. NÃO é o caminho usado em
# produção -- o shinyapps.io renderiza dashboard.qmd do lado dele, e o
# workflow .github/workflows/atualizar-dados.yml roda direto num runner do
# GitHub Actions, sem Docker. Esta imagem serve para (a) rodar o dashboard
# localmente numa máquina limpa e (b) documentar, em forma executável, as
# mesmas dependências de sistema que o workflow instala -- ver README,
# seção "Pré-requisitos", para a versão legível fora do Dockerfile.

# rocker/rstudio:4.4.1 -- mesma versão de R travada em renv.lock (campo
# R.Version) e usada pelo workflow (r-lib/actions/setup-r, r-version:
# '4.4.1'). Não suba esta tag sem antes decidir subir o lockfile junto
# (ver README, seção "A restrição do renv") -- as duas coisas precisam
# mudar juntas, deliberadamente, não uma arrastando a outra.
FROM rocker/rstudio:4.4.1

# Dependências de sistema (C/C++) dos pacotes R do lockfile. Lista igual à
# do passo "Instalar dependências de sistema dos pacotes R" em
# .github/workflows/atualizar-dados.yml -- essa é a fonte da verdade,
# validada em execução real de CI (foi a falta de libglpk-dev, em
# particular, que derrubou a primeira execução do workflow: o pacote
# igraph não carrega sem ela). Mapeamento lib -> pacote(s) R, com o motivo
# de cada uma, está comentado no workflow; não remova nada daqui sem
# conferir lá que nenhum pacote do lockfile ainda depende disso.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglpk-dev \
    libgdal-dev libproj-dev libgeos-dev libudunits2-dev \
    libxml2-dev \
    libssl-dev libcurl4-openssl-dev \
    libpng-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Instala o Quarto para a arquitetura da própria imagem -- arm64 em Apple
# Silicon (Docker Desktop em M1-M4) ou amd64 em CI/servidores x86_64.
# `dpkg --print-architecture` devolve exatamente o sufixo usado nos nomes
# dos pacotes .deb do Quarto ("arm64"/"amd64"), então não precisa de
# tradução manual. A versão anterior deste Dockerfile baixava sempre o
# .deb arm64 com URL fixa, o que quebrava a imagem em qualquer host/CI
# x86_64.
#
# Versão travada em 1.5.57 -- mesma versão fixada em
# .github/workflows/atualizar-dados.yml (não "latest"), e pelo mesmo
# motivo explicado lá: o workflow usa o binário `quarto` só para inspeção
# e empacotamento do bundle antes do deploy (rsconnect::deployDoc), e uma
# mudança de formato entre versões do Quarto poderia quebrar isso
# silenciosamente num job mensal sem supervisão. Reprodutibilidade pesa
# mais que ganhar correções automáticas. Atualize as duas junto, de
# propósito, com um teste manual do deploy.
RUN ARCH="$(dpkg --print-architecture)" && \
    curl -LO "https://github.com/quarto-dev/quarto-cli/releases/download/v1.5.57/quarto-1.5.57-linux-${ARCH}.deb" && \
    dpkg -i "quarto-1.5.57-linux-${ARCH}.deb" && \
    rm "quarto-1.5.57-linux-${ARCH}.deb"

# Mesma URL de repositório registrada em renv.lock (campo Repositories) --
# o Posit Package Manager, equivalente ao use-public-rspm: true do
# r-lib/actions/setup-r no workflow. O renv detecta a distribuição Linux
# da imagem e reescreve isto para a URL de binários pré-compilados
# correspondente automaticamente (comportamento padrão do renv em hosts
# Linux suportados) -- sem isto, o renv::restore() abaixo compilaria do
# zero pacotes pesados como arrow, terra e sf, o que pode levar dezenas de
# minutos a mais por build.
RUN echo "options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/latest'))" >> /usr/local/lib/R/etc/Rprofile.site

# remotes + sass 0.4.9 instalados antes do renv::restore, na mesma versão
# já travada em renv.lock: pré-condição desta imagem para o restore
# completar sem falhar ao compilar sass a partir do código-fonte.
RUN R -e "install.packages('remotes')" && \
    R -e "remotes::install_version('sass', '0.4.9', dependencies = TRUE)"

WORKDIR /app
COPY . .

# Restaura os pacotes R nas versões travadas em renv.lock. Não há
# .dockerignore neste repositório, então COPY . . acima já inclui
# dados/*.parquet se eles existirem no diretório local no momento do
# build -- ver README, seção "Onde estão os dados", para como obtê-los
# antes de construir a imagem (eles não estão versionados no git).
RUN R -e "renv::restore(confirm = FALSE, clean = TRUE)"

# Porta padrão do Shiny.
EXPOSE 3838

# Roda o dashboard Quarto/Shiny.
CMD ["quarto", "run", "dashboard.qmd"]
