# Dashboard da Balança Comercial

Dashboard Quarto/Shiny em R sobre a balança comercial brasileira (exportação e
importação por NCM, país, UF e região), com recorte adicional para o Maranhão
e o Nordeste. No ar em:

**https://observatorioportuario.shinyapps.io/balanca_comercial/**

Os dados vêm do [Comex Stat](https://balanca.economia.gov.br/balanca/bd/) do
MDIC (Ministério do Desenvolvimento, Indústria, Comércio e Serviços),
públicos e sem necessidade de credenciais. Um pipeline em `etl/` baixa,
transforma e valida esses dados uma vez por mês via GitHub Actions — ver
"Atualização mensal" abaixo.

Este README cobre o essencial para operar o projeto. O desenho da
arquitetura e as decisões que levaram a ela estão em
[`docs/superpowers/specs/2026-08-04-pipeline-mensal-comex-design.md`](docs/superpowers/specs/2026-08-04-pipeline-mensal-comex-design.md).

## Onde estão os dados

O dashboard lê dois arquivos parquet:

```
dados/ncm_exportacao_agrupado.parquet
dados/ncm_importacao_agrupado.parquet
```

Eles **não estão no repositório** — `dados/*.parquet` está no `.gitignore`.
Cada parquet consolidado soma dezenas de MB e cresce a cada atualização;
versioná-los faria o `.git` inchar rapidamente (foi exatamente o problema que
motivou tirá-los do histórico — ver a spec). Em vez disso, são gerados pelo
pipeline (`etl/`) e distribuídos como **asset de uma GitHub Release**, uma
por mês, com tag no formato `dados-AAAA-MM`.

**O dashboard não roda sem esses dois arquivos em `dados/`.** Para obtê-los,
duas opções:

**1. Baixar da Release mais recente** (rápido, recomendado para só rodar o
dashboard localmente):

```bash
gh release download -R tadeugomes/dashboard_balanca_comercial \
  -D dados --clobber -p "*.parquet"
```

**2. Gerar rodando o pipeline** (necessário se você quer dados mais novos que
a última Release, ou está depurando o próprio ETL) — ver "Como rodar o
pipeline" abaixo.

## A armadilha das unidades

Este é o ponto mais importante e menos óbvio do projeto: **os nomes das
colunas mentem sobre a unidade dos valores.**

| Coluna | Nome sugere | Unidade real |
|---|---|---|
| `valor_fob_dolar` | dólares | **milhões de dólares** |
| `peso_liquido_kg` | quilogramas | **milhões de toneladas** |

O ETL agrega os valores brutos do MDIC (`VL_FOB` em dólares, `KG_LIQUIDO` em
kg) e depois divide `valor_fob_dolar` por 10⁶ e `peso_liquido_kg` por 10⁹
(ver `etl/sql/agregado_ncm.sql`, comentário "Escala legada preservada de
propósito"). É herança do ETL original do projeto — os nomes de coluna nunca
foram corrigidos, e o dashboard depende dessa escala: os seletores da
interface já dizem "Valor (em milhões de dólares)" e "Peso (em milhões de
toneladas)" (`dashboard.qmd`), e os textos e eixos assumem essa unidade.

Se você for consumir esses parquets fora do dashboard — outro script,
outra análise — **não assuma que `peso_liquido_kg` está em kg**. Multiplique
por 10⁹ para voltar a kg, ou por 10⁶ para voltar a dólares em
`valor_fob_dolar`, antes de comparar com qualquer outra fonte que use as
unidades literais do nome da coluna.

## Como rodar o pipeline

O orquestrador precisa ser executado **a partir da raiz do projeto** — ele usa
caminhos relativos (`etl/R`, `etl/sql/agregado_ncm.sql`, `dados/`, etc.):

```bash
Rscript etl/run.R              # processa só o que mudou na fonte desde a última execução
Rscript etl/run.R --forcar     # reprocessa todos os anos, ignorando o cache/estado
```

- **Sem mudança nenhuma na fonte**, o pipeline consulta os metadados remotos
  (HEAD, `Last-Modified`/`Content-Length`) de cada arquivo anual, não detecta
  diferença e encerra em segundos.
- **Uma execução completa** (todos os anos, 2014 até o ano corrente, exportação
  e importação) baixa e processa da ordem de **4 GB** de CSVs do servidor do
  MDIC e leva **30–60 minutos** — o servidor é lento e derruba conexões com
  alguma frequência nos arquivos maiores (importação chega a ~175 MB por ano).
  Em um mês típico, quando só um ou dois anos foram republicados, o volume
  baixado cai para algo em torno de 600 MB.
- Ao final, os dois parquets são escritos em `dados/`.

### Rodar com escopo reduzido (para testes)

Variáveis de ambiente `ETL_*` permitem limitar o que o pipeline processa, sem
tocar nos parquets de produção nem no `etl/estado.json` real:

```bash
ETL_ANO_MIN=2014 ETL_ANO_MAX=2014 \
  ETL_DIR_SAIDA=/tmp/saida-teste \
  ETL_CAMINHO_ESTADO=/tmp/estado-teste.json \
  Rscript etl/run.R
```

Variáveis disponíveis (todas opcionais, com o comportamento de produção como
default): `ETL_ANO_MIN`, `ETL_ANO_MAX` (intervalo de anos a processar),
`ETL_DIR_SAIDA` (onde gravar os parquets finais), `ETL_CAMINHO_ESTADO` (onde
ler/gravar o registro de estado), `ETL_DIR_TRABALHO` (diretório de CSVs
brutos e cache anual) e `ETL_TOLERANCIA_REGRESSAO` (ver "Revisão retroativa"
abaixo).

**Nunca defina nenhuma dessas variáveis no workflow do GitHub Actions.** Sem
elas, o comportamento é o de produção (intervalo 2014..ano corrente, saída em
`dados/`, estado em `etl/estado.json`); definir qualquer uma no workflow
faria a atualização mensal rodar com escopo reduzido ou apontar para outro
lugar, silenciosamente.

## Como rodar os testes

```bash
Rscript -e 'testthat::test_dir("tests/testthat", stop_on_failure = TRUE)'
```

São testes do módulo ETL (`etl/R/*.R`) com fixtures sintéticas — não batem na
rede nem tocam nos parquets de produção. É o mesmo comando que o workflow do
GitHub Actions roda antes do ETL, e ele deve ficar verde antes de processar
qualquer dado.

## A restrição do `renv`

O `renv.lock` trava as versões de todos os pacotes R (incluindo `arrow`,
`dplyr`, `shiny`) na combinação calibrada para **R 4.4.1** — a versão usada
tanto pelo workflow do GitHub Actions quanto pelo shinyapps.io em produção.

Se você estiver numa máquina com uma versão de R mais nova, `renv::restore()`
provavelmente vai falhar tentando compilar pacotes antigos contra um
toolchain que não os suporta mais, ou instalar versões atuais dos pacotes por
fora do lockfile.

**Por isso, `renv::snapshot()` não deve ser rodado sem uma decisão explícita.**
Um snapshot cru, nessa situação, capturaria as versões instaladas
localmente — mais novas — e as gravaria no `renv.lock`. Isso não é uma
atualização inofensiva: o próximo deploy no shinyapps.io passaria a instalar
essas versões novas, incluindo pacotes com saltos grandes (ex.: `arrow` pode
saltar várias major versions), alterando o ambiente de produção sem que
ninguém tenha decidido isso deliberadamente — literalmente pela porta dos
fundos do lockfile. Se alguma dependência nova precisar entrar no lockfile,
adicione só o que falta preservando as versões já travadas dos pacotes
existentes, e trate qualquer atualização de versão como uma decisão à parte,
testada contra o deploy.

## Atualização mensal

O workflow `.github/workflows/atualizar-dados.yml` roda no **dia 10 de cada
mês, às 09:00 UTC** (06:00 em Brasília) e também pode ser disparado
manualmente.

O que ele faz, em ordem: instala as dependências de sistema e os pacotes R do
lockfile, roda os testes, instala o certificado intermediário que o servidor
do MDIC não envia (sem isso o download falha só no CI, nunca localmente),
executa `etl/run.R`, e — só se algo mudou em `etl/estado.json` — publica os
parquets como asset de uma nova GitHub Release, faz o deploy no
shinyapps.io e, por último, commita `etl/estado.json`. Essa ordem é
deliberada: só registrar o estado como "processado" depois que Release e
deploy tiverem tido sucesso evita que uma falha de publicação fique mascarada
como sucesso na próxima execução.

**Quando falha, o workflow abre uma issue automaticamente** no repositório,
com o link do log e orientação de recuperação. Se a falha foi antes da
publicação, os dados em produção continuam os do mês anterior e a próxima
execução agendada tenta de novo sozinha. Se foi depois (por exemplo, o
deploy no shinyapps.io falhou sozinho), o mesmo vale, mas só no próximo dia
10 — para não esperar, dispare manualmente:

```bash
gh workflow run atualizar-dados.yml -R tadeugomes/dashboard_balanca_comercial
```

Isso reprocessa só o que ainda não foi confirmado (mesmo comportamento da
execução agendada). Para ignorar o cache e reprocessar todos os anos do zero
(mais lento, 30–60 min):

```bash
gh workflow run atualizar-dados.yml -R tadeugomes/dashboard_balanca_comercial -f forcar=true
```

## Quando a validação reprova por revisão retroativa

O MDIC revisa dados de anos já fechados — republica o arquivo anual inteiro
com correções. Isso já aconteceu na prática: o peso agregado de exportação de
2024 mudou -1,27% entre uma execução do pipeline e outra seguinte, contra a
tolerância default de 1% do portão de validação (`etl/R/validar.R`,
verificação de regressão), e o workflow corretamente falhou e abriu uma
issue.

Esse comportamento é desenhado, não um defeito: o portão existe para pegar
join quebrado ou arquivo truncado, que também produzem uma variação nos
totais. Cabe ao operador diferenciar as duas situações antes de contornar a
reprovação — por exemplo, comparando o total revisado contra o valor
publicado diretamente no [Comex Stat](https://balanca.economia.gov.br/balanca/bd/)
para o mesmo ano, para confirmar que a mudança é uma revisão legítima do
MDIC e não uma quebra no pipeline.

Uma vez confirmada a legitimidade da revisão, a variável de ambiente
`ETL_TOLERANCIA_REGRESSAO` permite rodar novamente com uma tolerância maior
só para essa execução, sem editar código nem mexer no `etl/estado.json` à
mão:

```bash
ETL_TOLERANCIA_REGRESSAO=0.02 Rscript etl/run.R
```

O default, sem a variável definida, é 0.01 (1%). Como em qualquer variável
`ETL_*`, **não a defina no workflow do GitHub Actions** — isso afrouxaria a
proteção silenciosamente, todo mês, em vez de exigir confirmação manual do
operador a cada revisão real do MDIC.

## Estrutura do projeto

```
dashboard.qmd                 # o dashboard Quarto/Shiny (fonte)
dashboard.html                # artefato de preview da última renderização local
                               # (não é o que está no ar — shinyapps.io renderiza
                               # o .qmd dinamicamente)
dados/                        # parquets consolidados (gitignored, gerados pelo ETL)
etl/
├── run.R                     # orquestrador do pipeline
├── R/
│   ├── fontes.R               # catálogo de URLs do Comex Stat; consulta metadados remotos
│   ├── baixar.R                # download com retry, validação de conteúdo, conversão de codificação
│   ├── transformar.R           # roda o SQL sobre um ano bruto -> parquet anual
│   ├── consolidar.R            # une os parquets anuais nos 2 arquivos finais
│   ├── validar.R               # portão de sanidade (schema, cobertura, escala, regressão...)
│   └── estado.R                # leitura/gravação atômica de etl/estado.json; decide o que está pendente
├── sql/agregado_ncm.sql       # joins e agregação (é aqui que vive a divisão por 1e6/1e9)
└── estado.json                 # registro do que já foi processado — versionado; os dados, não
tests/testthat/               # suíte de testes do etl/ (fixtures sintéticas, sem rede)
.github/workflows/atualizar-dados.yml   # cron mensal + workflow_dispatch
scripts/medir_leitura.R       # script usado para medir a estratégia de leitura do dashboard (Arrow preguiçoso vs. collect()+memoise)
docs/superpowers/specs/       # spec de arquitetura e decisões do pipeline
renv.lock                     # versões travadas dos pacotes R (ver "A restrição do renv")
www/                          # imagens e assets estáticos do dashboard
rascunho.R, teste.qmd         # protótipos antigos, fora de escopo de manutenção
```

## Limitações conhecidas

- **Memória no shinyapps.io.** O plano gratuito limita 1 GB de RAM por
  instância. A leitura do dashboard (Arrow preguiçoso, sem `collect()`) usa
  cerca de **534 MB** medidos — já mais da metade do teto. Os dados crescem
  em torno de **500 mil linhas por ano**; em alguns anos isso pode se
  aproximar do limite e exigir um plano pago ou uma mudança de estratégia
  (por exemplo, particionar os parquets por ano). Uma estratégia alternativa
  com `collect()` + `memoise` foi medida e descartada por estourar tanto o
  critério de corte quanto o próprio teto do shinyapps.io.
- **Retry no CI reprocessa desde o início.** O cache de parquets anuais do
  GitHub Actions (`etl/.trabalho/anos`) expira depois de 7 dias sem uso; como
  o cron é mensal (30 dias), ele está sempre frio nas execuções agendadas.
  Isso não quebra a correção do pipeline (o cache frio só significa
  reprocessamento completo, não dado incompleto), mas significa que uma
  retentativa depois de uma falha de rede no meio da execução refaz o
  trabalho já feito naquela mesma tentativa, em vez de retomar de onde parou
  — o estado.json só é commitado no repositório ao final, e enquanto isso não
  acontece, o cache do Actions é o único lugar onde o progresso intermediário
  vive.
- **Os arquivos `VIA.csv`, `URF.csv` e `NCM_CGCE.csv`** existem na fonte do
  MDIC mas não são usados — as colunas correspondentes foram removidas do
  schema de saída antes do ETL atual existir, e o dashboard não as consome.
- **`rascunho.R` e `teste.qmd`** são protótipos anteriores ao pipeline atual
  e não fazem parte do fluxo de produção; ficaram deliberadamente fora do
  escopo da reconstrução do ETL.
