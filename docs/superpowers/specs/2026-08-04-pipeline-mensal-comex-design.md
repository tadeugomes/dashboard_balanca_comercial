# Pipeline mensal de atualização dos dados do Comex Stat

**Data:** 2026-08-04
**Estado:** aprovado, aguardando plano de implementação

## Problema

O dashboard da balança comercial exibe dados que terminam em dezembro de 2024. Três obstáculos impedem a atualização:

1. **O ETL não existe no repositório.** O `rascunho.R` faz a agregação, mas chama `source("lendo_arquivos.R")` — arquivo que nunca foi versionado em nenhum dos 14 commits. A etapa de leitura dos dados brutos se perdeu.
2. **O ano de referência está fixo no código.** Há 23 ocorrências de anos literais no `dashboard.qmd`. Atualizar apenas os parquets não mudaria nada do que o usuário vê: o painel continuaria dizendo "2024".
3. **Os dados estão versionados no Git.** Os dois parquets somam 97 MB e o repositório já ocupa 484 MB por causa de versões antigas. Atualizar mensalmente por commit levaria o repositório a mais de 1,5 GB em um ano.

Há ainda uma divergência pendente: o clone local está 2 commits atrás de `origin/master`, com modificações não commitadas nos mesmos arquivos que os commits remotos alteram.

## Objetivo

Atualizar os dados até o mês mais recente disponível e estabelecer um fluxo mensal automático que não dependa de intervenção manual nem da máquina do autor.

## Decisões tomadas

| Questão | Decisão |
|---|---|
| Fonte dos dados | Comex Stat / MDIC direto, sem credenciais |
| Onde a automação roda | GitHub Actions, cron mensal |
| Armazenamento dos parquets | Fora do Git: asset de Release + bundle de deploy |
| Motor do ETL | DuckDB com cache por ano |
| Histórico do Git | Limpar com `git filter-repo` |
| Período de referência dos painéis | Último ano completo, detectado dos dados |
| Estratégia de leitura no dashboard | A decidir por medição na Fase 3 |

## Fonte de dados

Todos os arquivos vêm de `https://balanca.economia.gov.br/balanca/bd/`, são públicos e não exigem autenticação. A cadeia de joins foi verificada em 2026-08-04:

```
comexstat-bd/ncm/{EXP,IMP}_<ano>.csv
  colunas: CO_ANO, CO_MES, CO_NCM, CO_UNID, CO_PAIS,
           SG_UF_NCM, CO_VIA, CO_URF, QT_ESTAT, KG_LIQUIDO, VL_FOB

  ├─ CO_PAIS    → tabelas/PAIS.csv                    → NO_PAIS
  ├─ SG_UF_NCM  → tabelas/UF.csv (por SG_UF)          → NO_UF, NO_REGIAO
  └─ CO_NCM     → tabelas/NCM.csv                     → CO_CUCI_ITEM
                    └─ tabelas/NCM_CUCI.csv           → NO_CUCI_GRUPO
```

Separador `;`, campos entre aspas duplas.

**Codificação (verificado em 2026-08-04):** os arquivos `{EXP,IMP}_<ano>.csv` são ASCII puro — contêm apenas códigos numéricos e siglas. Já as tabelas auxiliares são **ISO-8859-1**: é delas que vêm "África do Sul", "Áustria", "Índia" e os nomes de grupo CUCI. Como o DuckDB assume UTF-8 por padrão, as auxiliares são convertidas para UTF-8 (`iconv`) na etapa de download, antes de qualquer leitura. Sem isso, nomes acentuados chegariam corrompidos ao dashboard — falha que passaria por todas as validações numéricas.

As tabelas `VIA.csv`, `URF.csv` e `NCM_CGCE.csv` existem e foram verificadas, mas **não são necessárias**: as colunas correspondentes foram removidas do parquet no commit `d786ece` e o dashboard não as utiliza.

Volume: os CSVs anuais somam ~4 GB para 2014–2026. `IMP_2025.csv` tem 175 MB; `EXP_2025.csv`, 113 MB.

## Arquitetura

```
etl/
├── run.R                 # orquestrador
├── R/
│   ├── fontes.R          # catálogo de URLs; HEAD para Last-Modified/Content-Length
│   ├── baixar.R          # download com retry e verificação de integridade
│   ├── transformar.R     # executa o SQL por ano → parquet anual
│   ├── consolidar.R      # une os anos → os 2 parquets finais
│   └── validar.R         # portão de sanidade
├── sql/agregado_ncm.sql  # joins + agregação
└── estado.json           # Last-Modified de cada arquivo processado (versionado)
.github/workflows/atualizar-dados.yml
```

Cada módulo tem uma responsabilidade única e uma interface explícita: `baixar.R` não sabe o que é NCM, `validar.R` não sabe de onde veio o arquivo. Isso permite testar a validação com parquets sintéticos, sem rede.

### Fluxo de execução

1. **Manifesto** — requisição `HEAD` em cada `EXP_<ano>.csv` e `IMP_<ano>.csv` de 2014 até o ano corrente. Compara `Last-Modified` com o registrado em `etl/estado.json`. Se nada mudou, o workflow encerra com sucesso sem baixar nada.
2. **Download seletivo** — baixa apenas os anos alterados, mais as tabelas auxiliares (sempre; somam menos de 4 MB).
3. **Transformação** — para cada ano alterado, o DuckDB executa `agregado_ncm.sql`, gravando um parquet anual no cache do Actions.
4. **Consolidação** — une os anos nos dois arquivos finais.
5. **Validação** — portão obrigatório. Falha interrompe o workflow.
6. **Publicação** — asset em GitHub Release e deploy no shinyapps.io com os parquets no bundle.
7. **Registro** — commita `etl/estado.json`. O repositório guarda o rastro das atualizações, não os dados.

Em um mês típico apenas dois anos mudam: cerca de 600 MB baixados em vez de 4 GB.

### Por que cache por ano

O MDIC republica os arquivos anuais inteiros e **revisa meses anteriores retroativamente**. Uma estratégia incremental que apenas anexasse o mês novo produziria números divergentes da fonte. O cache invalidado por `Last-Modified` captura essas revisões automaticamente e ainda assim evita o rebuild completo.

### Schema de saída

Idêntico ao dos parquets atuais — o dashboard não precisa de adaptação para lê-los:

| Coluna | Tipo |
|---|---|
| `no_pais` | string |
| `no_uf` | string |
| `no_regiao` | string |
| `no_cuci_grupo` | string |
| `ano` | int64 |
| `mes` | int64 |
| `nome_mes` | string |
| `peso_liquido_kg` | float64 |
| `valor_fob_dolar` | float64 |

Agregação por todas as colunas não numéricas; `peso_liquido_kg` e `valor_fob_dolar` somados. `nome_mes` derivado de `CO_MES`, em português.

Saída: `dados/ncm_exportacao_agrupado.parquet` e `dados/ncm_importacao_agrupado.parquet`.

## Portão de validação

O deploy **só ocorre** se todas as verificações passarem. Qualquer falha interrompe o workflow e abre uma issue automática; o dashboard no ar permanece com os dados válidos do mês anterior.

| Verificação | Falha se |
|---|---|
| Schema | nomes ou tipos divergem do esperado |
| Cobertura | há buraco na série de anos, ou um ano fechado sem os 12 meses |
| Integridade | `valor_fob_dolar` ou `peso_liquido_kg` nulos ou negativos |
| Join | `no_uf`, `no_regiao` ou `no_cuci_grupo` nulos acima do limiar conhecido |
| Codificação | algum valor de `no_pais` ou `no_cuci_grupo` contém o caractere de substituição `U+FFFD` |
| Regressão | o total anual de anos já fechados varia mais de 1% frente à execução anterior |

A verificação de regressão é a mais importante: detecta join quebrado ou arquivo truncado — falhas que passariam por todas as outras produzindo números plausíveis mas errados.

Os códigos `EX` (exterior), `ND` (não declarada) e `ZN` em `SG_UF_NCM` não têm correspondência em `UF.csv`. São esperados e tratados explicitamente, não contando como falha de join. O limiar exato será fixado na Fase 1, a partir da proporção observada nos dados reais.

## Mudanças no dashboard

Um bloco `context: setup` deriva os períodos dos próprios dados, uma única vez:

```r
ANO_MIN <- # menor ano presente nos parquets
ANO_REF <- # maior ano com os 12 meses completos
```

As 23 ocorrências de ano literal em `dashboard.qmd` se distribuem assim:

- **11 afetam lógica** — `filter(ano == 2024)` (6), `ano >= 2014 & ano <= 2024` (4), `ano = 2014:2024` (1). Passam a referenciar as constantes.
- **8 são texto visível** — "Balança Comercial de 2024", "Os principais produtos exportados em 2024", "Fonte: SECEX (2024)", "entre 2014-2024". Passam a ser interpolados.
- **5 são identificadores de output** — `balanca_2014_2024`, `tabela_Exp_Prod2024`, `destinos_2014_2024`, `tabela_Imp_Prod2024`, `origens_2014_2024`. Renomeados para nomes sem ano (`balanca_anual`, `tabela_exp_produtos`, `destinos_anual`, `tabela_imp_produtos`, `origens_anual`).

A renomeação dos identificadores não é cosmética: um nome que mente sobre o período é o tipo de coisa que leva alguém a reintroduzir o valor fixo no futuro.

Com `ANO_REF` derivado dos dados, o dashboard passa a mostrar 2025 imediatamente e 2026 quando o ano fechar, sem alteração de código.

## Decisão pendente: estratégia de leitura

As versões local e remota do `dashboard.qmd` divergem em como leem os parquets:

- **Local:** `open_dataset()` preguiçoso do Arrow, sem `collect()`, sem `future`/`furrr`.
- **Remota (`origin/master`):** `memoise()` + `collect()`, com `plan(multicore)` e `future_map()`.

O shinyapps.io no plano gratuito limita **1 GB de RAM por instância**. Com os dados até 2026 cada parquet chega a cerca de 4,6 milhões de linhas. A versão remota carrega tudo em memória e cacheia por UF, o que pode estourar esse teto e derrubar o app; a local não carrega, mas responde mais devagar a cada interação.

A escolha será feita na Fase 3 por medição de memória e tempo de resposta com os dados atualizados, não por argumento. O resultado será registrado neste documento.

## Faseamento

| Fase | Escopo | Entregável verificável |
|---|---|---|
| 0 | Backup espelhado; branch de reconciliação a partir de `origin/master`; reaplicar as mudanças locais | histórico local e remoto convergidos |
| 1 | Construir o `etl/` e executar localmente até gerar parquets que passem na validação | dados de 2014 a 2026 no disco |
| 2 | Dinamizar os 23 pontos de ano em `dashboard.qmd` | dashboard sem ano fixo |
| 3 | Executar o dashboard com os dados novos; medir as duas estratégias de leitura e fixar a vencedora | decisão registrada com números |
| 4 | Workflow do Actions: cron, secrets, cache por ano, issue automática em falha | atualização mensal no ar |
| 5 | `git filter-repo` removendo `dados/` do histórico e force-push | repositório reduzido a poucos MB |

Cada fase termina em algo verificável. Se a Fase 4 travar, as Fases 1 a 3 já terão entregado dados atualizados no ar.

## Agendamento

Cron no **dia 10 de cada mês**. O MDIC republicou em 03/07/2026 e antes em 05/02/2026, sem dia fixo confiável. Quando o manifesto não detecta mudança, o workflow encerra em segundos sem custo — uma publicação atrasada é capturada no mês seguinte.

Gatilhos: `schedule` e `workflow_dispatch` apenas. **Sem** `pull_request`, para que nenhum PR vindo do fork obtenha acesso ao token de deploy.

## Segurança dos secrets

Cadastrados no repositório em 2026-08-04:

- `SHINYAPPS_TOKEN`
- `SHINYAPPS_SECRET`

O nome da conta (`observatorioportuario`) não é sigiloso — aparece na URL pública do app — e fica escrito no próprio workflow.

O repositório é público. O Actions mascara os valores na saída e não os expõe a workflows disparados por forks. Em caso de suspeita de vazamento, basta remover o token em shinyapps.io → Tokens e gerar outro.

## Riscos

| Risco | Mitigação |
|---|---|
| Teto de 1 GB de RAM no shinyapps.io derruba o app com os dados maiores | Fase 3 mede antes de publicar; a estratégia de leitura é escolhida pelo resultado |
| Servidor do MDIC lento ou instável durante o job | Download seletivo reduz o volume a ~600 MB; `baixar.R` faz retry com backoff |
| MDIC muda o layout dos CSVs ou o endereço dos arquivos | Validação de schema falha e bloqueia o deploy; o app no ar permanece íntegro |
| `git filter-repo` quebra o fork `chicojadson` e clones existentes | Backup espelhado antes; a Fase 5 é a última e independente das demais |
| Revisão retroativa legítima do MDIC dispara o alerta de regressão de 1% | O workflow falha e abre issue; a revisão é confirmada manualmente e o limiar reavaliado |

## Fora de escopo

- Retomar os parquets municipais (`m_exportacao`, `m_importacao`), removidos no commit `d3572ee`.
- Alterar visualizações, layout ou paleta do dashboard.
- Migrar de shinyapps.io para outra hospedagem.
- Reescrever `rascunho.R` e `teste.qmd`, que permanecem como estão.

## Ação pendente do autor

Antes da Fase 5, avisar os detentores de clones — em particular o fork `chicojadson/dashboard_balanca_comercial` — de que o histórico será reescrito.
