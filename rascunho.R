# agrupando os dados

source("lendo_arquivos.R")


### NCM_EXPORTACAO ############
ncm_exportacao <- ler_dados("ncm_exportacao")


# dplyr::glimpse(ncm_exportacao)

ncm_exportacao <- 
ncm_exportacao |> 
    dplyr::select(
        ano, mes,
        no_cuci_grupo, no_cgce_n1, 
        no_pais, no_bloco, no_via, no_urf,
        sigla_uf_ncm, no_uf, no_regiao,
        peso_liquido_kg, valor_fob_dolar)


ncm_exportacao <- 
    ncm_exportacao |> 
    dplyr::group_by(ano, mes,
                    no_cuci_grupo, no_cgce_n1,
                    no_pais, no_bloco, no_via, no_urf,
                    sigla_uf_ncm, no_uf, no_regiao
                    ) |> 
    dplyr::summarise(
        peso_liquido_kg = sum(peso_liquido_kg),
        valor_fob_dolar = sum(valor_fob_dolar)
                     )

arrow::write_parquet(ncm_exportacao,  "dados/ncm_exportacao_agrupado.parquet")

rm(ncm_exportacao)
gc() 

#### NCM_IMPORTACAO ###########
ncm_importacao <- ler_dados("ncm_importacao")

# object.size(ncm_importacao)

# dplyr::glimpse(ncm_importacao)


ncm_importacao <- 
    ncm_importacao |> 
    dplyr::select(
        ano, mes,
        no_cuci_grupo, no_cgce_n1,
        no_pais, no_bloco, no_via, no_urf,
        sigla_uf_ncm, no_uf, no_regiao,
        peso_liquido_kg, valor_fob_dolar)


ncm_importacao <- 
    ncm_importacao |> 
    dplyr::group_by(ano, mes,
                    no_cuci_grupo, no_cgce_n1, no_pais, 
                   no_bloco, no_via, no_urf, 
                   sigla_uf_ncm, no_uf, no_regiao
                   ) |> 
    dplyr::summarise(
        peso_liquido_kg = sum(peso_liquido_kg),
        valor_fob_dolar = sum(valor_fob_dolar)
    )


arrow::write_parquet(ncm_importacao,  "dados/ncm_importacao_agrupado.parquet")
rm(ncm_importacao)
gc() 

####### M_EXPORTACAO ################

m_exportacao <- ler_dados("m_exportacao")

dplyr::glimpse(m_exportacao)

m_exportacao <- 
    m_exportacao |> 
    dplyr::select(
        ano, mes,
        no_pais, no_bloco, 
        no_mun_min, sigla_uf, no_uf, no_regiao,
        peso_liquido_kg, valor_fob_dolar
        )


m_exportacao <- 
    m_exportacao |> 
    dplyr::group_by(
        ano, mes,
        no_pais, no_bloco, 
        no_mun_min, sigla_uf, no_uf, no_regiao
    ) |> 
    dplyr::summarise(
        peso_liquido_kg = sum(peso_liquido_kg),
        valor_fob_dolar = sum(valor_fob_dolar)
    )

arrow::write_parquet(m_exportacao,  "dados/m_exportacao_agrupado.parquet")

rm(m_exportacao)
gc() 
############## M_IMPORTACAO ###########
m_importacao <- ler_dados("m_importacao")

# object.size(m_importacao)

m_importacao |> head(1000) |> dplyr::glimpse()


m_importacao <- 
    m_importacao |> 
    dplyr::select(
        ano, mes,
        no_pais, no_bloco, 
        no_mun_min, sigla_uf, no_uf, no_regiao,
        peso_liquido_kg, valor_fob_dolar
    )


m_importacao <- 
    m_importacao |> 
    dplyr::group_by(
        ano, mes,
        no_pais, no_bloco, 
        no_mun_min, sigla_uf, no_uf, no_regiao
    ) |> 
    dplyr::summarise(
        peso_liquido_kg = sum(peso_liquido_kg),
        valor_fob_dolar = sum(valor_fob_dolar)
    )


arrow::write_parquet(m_importacao,  "dados/m_importacao_agrupado.parquet")
rm(m_importacao)
gc() 

################################################################################
library(arrow)
library(tidyr)
library(dplyr)

schema <- schema(
    no_pais = string(),
    no_bloco = string(),
    no_uf = string(),
    no_regiao = string(),
    no_urf = string(),
    no_cuci_grupo = string(),
    ano = int64(),
    mes = int64(),
    nome_mes = string(),
    peso_liquido_kg = float64(),
    valor_fob_dolar = float64()
)


ncm_exportacao <- 
    open_dataset(
        paste0("dados/ncm_exportacao_agrupado.parquet"), 
        schema = schema
    ) |>
    collect() 


# apenas estas colunas foram utilizadas
# ncm_exportacao |> colnames()
# ncm_exportacao <- 
# ncm_exportacao |> 
#     group_by(
#         no_pais, no_bloco, no_uf,
#         no_regiao, no_urf, no_cuci_grupo,
#         ano, mes, nome_mes
#     ) |> 
#     summarise(
#         peso_liquido_kg = sum(peso_liquido_kg),
#         valor_fob_dolar = sum(valor_fob_dolar)
#     ) 


# arrow::write_parquet(ncm_exportacao,  "dados/ncm_exportacao_agrupado.parquet")



###----------------------------------------------------------------------------##
library(arrow)
library(tidyr)
library(dplyr)

schema <- schema(
    no_pais = string(),
    no_bloco = string(),
    no_uf = string(),
    no_regiao = string(),
    no_urf = string(),
    no_cuci_grupo = string(),
    ano = int64(),
    mes = int64(),
    nome_mes = string(),
    peso_liquido_kg = float64(),
    valor_fob_dolar = float64()
)


ncm_importacao <- 
    open_dataset(
        paste0("dados/ncm_importacao_agrupado.parquet"), 
        schema = schema
    ) |>
    collect() 


# apenas estas colunas foram utilizadas
# ncm_exportacao |> colnames()
ncm_importacao <- 
    ncm_importacao |> 
    group_by(
        no_pais, no_bloco, no_uf,
        no_regiao, no_urf, no_cuci_grupo,
        ano, mes, nome_mes
    ) |> 
    summarise(
        peso_liquido_kg = sum(peso_liquido_kg),
        valor_fob_dolar = sum(valor_fob_dolar)
    ) 


# arrow::write_parquet(ncm_importacao,  "dados/ncm_importacao_agrupado.parquet")



###############


criar_acumulado <- function(ncm_exportacao, ncm_importacao) {
    # Função auxiliar para agrupar e resumir dados
    processar_dados <- function(dados, uf) {
        dados |>
            filter(no_uf == uf | no_regiao == uf | uf == "Brasil") |>
            group_by(ano, mes, nome_mes, uf = uf) |>
            summarise(
                valor_fob_dolar = sum(valor_fob_dolar, na.rm = TRUE),
                peso_liquido_kg = sum(peso_liquido_kg, na.rm = TRUE),
                .groups = "drop"
            )
    }
    
    # Processar exportações e importações
    exportacoes <- bind_rows(
        processar_dados(ncm_exportacao, "Maranhão"),
        processar_dados(ncm_exportacao, "Nordeste"),
        processar_dados(ncm_exportacao, "Brasil")
    ) |>
        rename(exp_valor = valor_fob_dolar) |> 
        rename(exp_peso = peso_liquido_kg)
    
    importacoes <- bind_rows(
        processar_dados(ncm_importacao, "Maranhão"),
        processar_dados(ncm_importacao, "Nordeste"),
        processar_dados(ncm_importacao, "Brasil")
    ) |>
        rename(imp_valor = valor_fob_dolar) |> 
        rename(imp_peso = peso_liquido_kg)    
    # Juntar dados e calcular saldo e corrente
    acumulado <- exportacoes |>
        left_join(importacoes, by = c("ano", "mes", "nome_mes", "uf")) |>
        mutate(
            saldo_valor = exp_valor - imp_valor,
            saldo_peso = exp_peso - imp_peso,
            corrente_valor = exp_valor + imp_valor,
            corrente_peso = exp_peso + imp_peso
        )
    
    return(acumulado)
}

# 4. Objeto reativo para dados acumulados
acumulado_reativo <- criar_acumulado(ncm_exportacao, ncm_importacao)


########
schema <- schema(
    no_pais = string(),
    no_bloco = string(),
    no_uf = string(),
    no_regiao = string(),
    no_urf = string(),
    no_cuci_grupo = string(),
    ano = int64(),
    mes = int64(),
    nome_mes = string(),
    peso_liquido_kg = float64(),
    valor_fob_dolar = float64()
)

ncm_exportacao_agrupado <- 
open_dataset(
    paste0("dados/ncm_exportacao_agrupado.parquet"), 
    schema = schema
) |>
    collect()

ncm_exportacao_agrupado |>
    filter(no_uf == "Maranhão") |> 
    group_by(no_urf) |> 
    summarise(valor_fob_dolar = sum(valor_fob_dolar)) |> 
    arrange(desc(valor_fob_dolar))

