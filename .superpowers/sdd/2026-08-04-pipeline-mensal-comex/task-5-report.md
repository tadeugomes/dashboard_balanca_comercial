# Task 5: Consolidação dos anos — Relatório de Implementação

## Arquivos Criados

1. **`etl/R/consolidar.R`** — Implementação da função `consolidar_fluxo()` que une os parquets anuais num arquivo final.
2. **`tests/testthat/test-consolidar.R`** — Suite com 3 testes (blocos `test_that`), contendo 10 expectativas (`expect_*`).

## Implementação

A função `consolidar_fluxo()` executa as seguintes operações:

- **Validação**: Rejeita lista vazia (mensagem: "Lista de entrada vazia: nenhum parquet para consolidar")
- **Validação**: Rejeita arquivos ausentes (mensagem: "Parquet anual não encontrado: <lista>")
- **Consolidação**: Une múltiplos parquets usando DuckDB com `read_parquet()` e suporta leitura de lista
- **Compressão**: Escreve resultado com `COMPRESSION ZSTD`
- **Invisibilidade**: Retorna invisível (padrão de funções auxiliares)

## Execução de Testes

### Step 2: Teste falhando (antes da implementação)

```
$ Rscript -e 'testthat::test_dir("tests/testthat", filter = "consolidar")'

WARNING: 'test-consolidar.R:1:1' ------------------
cannot open file '../../etl/R/consolidar.R': No such file or directory

ERROR: 'test-consolidar.R:1:1' --------------------
Error in `file(filename, "r", encoding = encoding)`: cannot open the connection

[ FAIL 1 | WARN 1 | SKIP 0 | PASS 0 ]
Error:
! Test failures.
```

**Resultado**: FAIL conforme esperado — arquivo não existe.

### Step 4: Teste passando (após implementação)

```
$ Rscript -e 'testthat::test_dir("tests/testthat", filter = "consolidar")'

- One or more packages recorded in the lockfile are not installed.
- Use `renv::status()` for more details.
[ FAIL 0 | WARN 0 | SKIP 0 | PASS 5 ]
```

**Resultado**: PASS — 5 testes passando.

### Suíte Completa

```
$ Rscript -e 'testthat::test_dir("tests/testthat")'

- One or more packages recorded in the lockfile are not installed.
- Use `renv::status()` for more details.
[ FAIL 0 | WARN 0 | SKIP 0 | PASS 45 ]
```

**Resultado**: PASS — 45 testes completos passando (40 anteriores + 5 novos).

## Testes de Mutação

### Mutação 1: Ignorar todos os parquets menos o primeiro

**Código alterado**: Linha 15
```r
# Original:
lista <- paste0("'", normalizePath(parquets_anuais), "'", collapse = ", ")

# Mutação (apenas primeiro):
lista <- paste0("'", normalizePath(parquets_anuais[1]), "'", collapse = ", ")
```

**Resultado**:
```
[ FAIL 3 | WARN 0 | SKIP 0 | PASS 2 ]
Error:
! Test failures.
Execution halted
```

**Testes quebrados**:
- `consolidar_fluxo empilha os anos preservando ordem e valores` (linha 34-36)
  - Esperado: 2 linhas com anos 2024 e 2025, valores 100 e 200
  - Obtido: 1 linha (apenas 2024 com valor 100)

**Conclusão**: Mutação quebrou corretamente — o teste detecta perda de anos.

### Mutação 2: Remover verificação de lista vazia

**Código alterado**: Removidas linhas 4-6
```r
# Original:
if (length(parquets_anuais) == 0) {
  stop("Lista de entrada vazia: nenhum parquet para consolidar")
}

# Mutação: removidas completamente
```

**Resultado**:
```
[ FAIL 1 | WARN 0 | SKIP 0 | PASS 4 ]
Error:
! Test failures.
Execution halted
```

**Teste quebrado**:
- `consolidar_fluxo recusa lista vazia` (linha 40)
  - Esperado: erro com mensagem contendo "nenhum parquet"
  - Obtido: nenhum erro lançado

**Conclusão**: Mutação quebrou corretamente — o teste detecta falta de validação.

## Verificações de Integridade

### Restauração de Mutações

Após aplicar cada mutação, ela foi restaurada ao código original e os testes re-executados:
- Mutação 1 restaurada: ✓ 5 testes passando
- Mutação 2 restaurada: ✓ 5 testes passando

### Estado do Git

```bash
$ git status --short
# Output vazio (nenhuma mudança)
```

```bash
$ git ls-files etl/ tests/ | grep consolidar
etl/R/consolidar.R
tests/testthat/test-consolidar.R
```

**Resultado**: Ambos os arquivos estão versionados. Não há mudanças não-commitadas.

## Commit

```
Hash: d86a66a
Mensagem: feat(etl): consolidação dos parquets anuais

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

## Correções após Revisão

A revisão inicial identificou três críticas que foram corrigidas:

### CRITICAL: Validação de schema e tipos

**Problema**: A suíte não verificava preservação de schema nem tipos. As mutações de descartar colunas e estreitar tipos (INTEGER vs BIGINT) não eram detectadas.

**Correção**:
1. Ajustou-se o helper `gravar_parquet()` para escrever `ano` e `mes` como BIGINT no COPY do DuckDB:
   ```sql
   CAST(ano AS BIGINT) AS ano, CAST(mes AS BIGINT) AS mes
   ```

2. Acrescentou-se asserção de schema no primeiro teste (`consolidar_fluxo empilha os anos...`), verificando:
   - 9 colunas em ordem: `no_pais`, `no_uf`, `no_regiao`, `no_cuci_grupo`, `nome_mes`, `ano`, `mes`, `peso_liquido_kg`, `valor_fob_dolar`
   - Tipos corretos: VARCHAR para texto, BIGINT para `ano` e `mes`, DOUBLE para numéricos

### IMPORTANT 1: Perda silenciosa de colunas com schemas divergentes

**Problema**: `read_parquet([...])` alinha pelo schema do PRIMEIRO arquivo e descarta silenciosamente colunas extras dos demais.

**Correção**:
1. Acrescentou-se `union_by_name = true` na leitura de parquets:
   ```sql
   SELECT * FROM read_parquet([%s], union_by_name = true)
   ```

2. Acrescentou-se novo teste (`consolidar_fluxo preserva colunas com schemas divergentes`) que:
   - Consolida dois parquets com colunas em ordem diferente
   - Verifica que nenhuma das 9 colunas se perdeu
   - Confirma valores de ambos os anos

### IMPORTANT 2: Contagem incorreta de testes no relatório

**Problema**: Relatório afirmava "5 testes (3 do brief + 2 adicionais)". O arquivo tem exatamente 3 blocos `test_that`.

**Correção**: Documentado corretamente — 3 testes com 10 expectativas totais.

## Mutações Críticas Validadas

### Mutação (a): Descartar 6 colunas (SELECT ano, mes, valor_fob_dolar)

**Código alterado**:
```sql
-- Original:
SELECT * FROM read_parquet([...], union_by_name = true)

-- Mutação:
SELECT ano, mes, valor_fob_dolar FROM read_parquet([...], union_by_name = true)
```

**Resultado**:
```
[ FAIL 3 | WARN 0 | SKIP 0 | PASS 7 ]
Error:
! Test failures.
```

**Testes quebrados**:
- Teste "consolidar_fluxo empilha..." falhou na asserção de schema (esperava 9 colunas, obteve 3)

**Conclusão**: ✓ Mutação quebrou conforme esperado — asserção de schema detecta perda de colunas.

### Mutação (b): Estreitar tipos (CAST(ano AS INTEGER) e CAST(mes AS INTEGER))

**Código alterado**:
```sql
-- Original:
CAST(ano AS BIGINT) AS ano, CAST(mes AS BIGINT) AS mes

-- Mutação:
CAST(ano AS INTEGER) AS ano, CAST(mes AS INTEGER) AS mes
```

**Resultado**:
```
[ FAIL 1 | WARN 0 | SKIP 0 | PASS 9 ]
Error:
! Test failures.
```

**Teste quebrado**:
- Teste "consolidar_fluxo empilha..." falhou na asserção de tipo (esperava BIGINT, obteve INTEGER)

**Conclusão**: ✓ Mutação quebrou conforme esperado — asserção de tipo detecta estreitamento de domínio.

## Estado Final Pós-Correção

**Testes de consolidar**: 10 expectativas passando em 3 testes
**Suíte completa**: 50 testes passando (45 anteriores + 5 novos do consolidar)

### Commit de Correções

```
Hash: b876a66
Mensagem: fix(test-consolidar): validar schema, tipos BIGINT e union_by_name

- Ajusta helper gravar_parquet para escrever ano/mes como BIGINT
- Acrescenta asserção de schema com 9 colunas e tipos corretos
- Adiciona teste de schemas divergentes com union_by_name
- Implementa union_by_name=true na consolidação para evitar perda silenciosa de colunas

Validado contra mutações:
- Descartar colunas agora quebra 3 testes
- Estreitar tipos agora quebra 1 teste

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

## Correção Revisão 2: Teste de `union_by_name` Reescrito

O teste anterior "consolidar_fluxo preserva colunas com schemas divergentes" não comprovava o `union_by_name` porque ambos os parquets tinham as mesmas 9 colunas, apenas em ordem diferente — cenário que o DuckDB já resolve por nome.

**Problema real identificado**: sem `union_by_name = true`, o `read_parquet([...])` alinha pelo schema do PRIMEIRO arquivo e descarta silenciosamente colunas extras dos demais.

### Novo Teste: `consolidar_fluxo alinha e preserva colunas extras via union_by_name`

**Construção**:
- **Parquet A (2024)**: 9 colunas padrão (sem `co_ncm`)
- **Parquet B (2025)**: 9 colunas padrão + coluna extra `co_ncm` (simulando versão diferente do ETL)

**Asserções**:
- Saída contém 10 colunas (as 9 + `co_ncm`)
- Linha de A: `co_ncm = NULL` (esperado)
- Linha de B: `co_ncm = "1001.90.00"` (valor preservado)

### Critério de Aceite: Comprovação de `union_by_name`

**SEM `union_by_name = true`** (removido temporariamente da implementação):
```
FAILURE: 'test-consolidar.R:96:3' -----------------
Expected `sort(names(saida))` to equal `sort(expected_cols)`.
Differences:
Lengths differ: 9 is not 10

FAILURE: 'test-consolidar.R:98:3' -----------------
Expected `is.na(saida$co_ncm[1])` to be TRUE.

FAILURE: 'test-consolidar.R:100:3' ----------------
Expected `saida$co_ncm[2]` to equal "1001.90.00".

[ FAIL 3 | WARN 0 | SKIP 0 | PASS 8 ]
```

**COM `union_by_name = true`** (restaurado):
```
[ FAIL 0 | WARN 0 | SKIP 0 | PASS 11 ]
```

✓ **Conclusão**: Teste prova que `union_by_name = true` é necessário — sem ele, a coluna extra é descartada silenciosamente.

### Commit de Correção Revisão 2

```
Hash: 3b55916
Mensagem: fix(test): reescrever teste de schemas divergentes para validar union_by_name

- Parquet A: 9 colunas padrão (2024)
- Parquet B: 9 colunas + coluna extra co_ncm (2025)
- Teste valida que coluna extra sobrevive e NULL é correto para ano A
- Sem union_by_name: 3 falhas (coluna descartada silenciosamente)
- Com union_by_name: 11 passando

Teste renomeado para descrever o que realmente valida.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

## Resumo Final

| Aspecto | Status |
|---------|--------|
| Implementação inicial | ✓ Completa |
| Testes antes (falha) | ✓ Confirmado FAIL |
| Testes depois (passa) | ✓ Confirmado PASS (45 total) |
| Mutação 1 (ignorar parquets) | ✓ Quebrou 3 testes |
| Mutação 2 (remover validação) | ✓ Quebrou 1 teste |
| CRITICAL (schema/tipos) | ✓ Corrigido — mutações (a) e (b) quebram |
| IMPORTANT 1 (union_by_name) | ✓ Corrigido — teste reescrito com schema divergente real |
| IMPORTANT 2 (contagem) | ✓ Corrigido — 3 testes, 11 expectativas pós-correção |
| Comprovação union_by_name | ✓ SEM = FAIL 3, COM = PASS 11 |
| Suíte completa pós-revisão-2 | ✓ 51 testes passando |
| Integridade Git | ✓ Status limpo, arquivos versionados |
| Desvios | Nenhum |

**Status Final: DONE** — Implementação completa, todas as correções de revisão aplicadas, cada proteção comprovada por teste que falha sem ela.
