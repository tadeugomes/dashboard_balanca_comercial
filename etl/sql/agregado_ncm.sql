-- Agrega um arquivo anual do Comex Stat no schema consumido pelo dashboard.
-- Os rótulos de mês e o de-para de região são fixos de propósito: o dashboard
-- filtra por esses valores literais.
COPY (
  WITH dados AS (
    SELECT
      CAST(CO_ANO AS BIGINT)     AS ano,
      CAST(CO_MES AS BIGINT)     AS mes,
      CO_PAIS,
      SG_UF_NCM,
      CO_NCM,
      CAST(KG_LIQUIDO AS DOUBLE) AS peso_liquido_kg,
      CAST(VL_FOB AS DOUBLE)     AS valor_fob_dolar
    FROM read_csv(
      '{{csv_dados}}',
      delim = ';', header = true, quote = '"', all_varchar = true
    )
  ),
  ncm_grupo AS (
    SELECT n.CO_NCM, c.NO_CUCI_GRUPO
    FROM read_csv('{{dir_aux}}/NCM.csv',
                  delim = ';', header = true, quote = '"', all_varchar = true) n
    LEFT JOIN read_csv('{{dir_aux}}/NCM_CUCI.csv',
                  delim = ';', header = true, quote = '"', all_varchar = true) c
      ON n.CO_CUCI_ITEM = c.CO_CUCI_ITEM
  )
  SELECT
    COALESCE(p.NO_PAIS, '')  AS no_pais,
    COALESCE(u.NO_UF, '')    AS no_uf,
    CASE u.NO_REGIAO
      WHEN 'REGIAO NORTE'        THEN 'Norte'
      WHEN 'REGIAO NORDESTE'     THEN 'Nordeste'
      WHEN 'REGIAO SUDESTE'      THEN 'Sudeste'
      WHEN 'REGIAO SUL'          THEN 'Sul'
      WHEN 'REGIAO CENTRO OESTE' THEN 'Centro-Oeste'
      ELSE 'Não Declarada'
    END                      AS no_regiao,
    COALESCE(g.NO_CUCI_GRUPO, '') AS no_cuci_grupo,
    d.ano                    AS ano,
    d.mes                    AS mes,
    CASE d.mes
      WHEN 1 THEN 'jan.' WHEN 2 THEN 'fev.' WHEN 3  THEN 'mar.'
      WHEN 4 THEN 'abr.' WHEN 5 THEN 'maio' WHEN 6  THEN 'jun.'
      WHEN 7 THEN 'jul.' WHEN 8 THEN 'ago.' WHEN 9  THEN 'set.'
      WHEN 10 THEN 'out.' WHEN 11 THEN 'nov.' WHEN 12 THEN 'dez.'
    END                      AS nome_mes,
    -- Escala legada preservada de propósito: o ETL original gravava peso em
    -- milhões de toneladas e valor em milhões de dólares, apesar dos nomes
    -- de coluna sugerirem kg e dólar. dashboard.qmd rotula os eixos nessas
    -- unidades; mudar a escala aqui sem mudar os nomes quebraria o dashboard.
    SUM(d.peso_liquido_kg) / 1000000000 AS peso_liquido_kg,
    SUM(d.valor_fob_dolar) / 1000000    AS valor_fob_dolar
  FROM dados d
  LEFT JOIN read_csv('{{dir_aux}}/PAIS.csv',
                     delim = ';', header = true, quote = '"',
                     all_varchar = true) p
    ON d.CO_PAIS = p.CO_PAIS
  LEFT JOIN read_csv('{{dir_aux}}/UF.csv',
                     delim = ';', header = true, quote = '"',
                     all_varchar = true) u
    ON d.SG_UF_NCM = u.SG_UF
  LEFT JOIN ncm_grupo g
    ON d.CO_NCM = g.CO_NCM
  GROUP BY ALL
) TO '{{destino}}' (FORMAT PARQUET, COMPRESSION ZSTD);
