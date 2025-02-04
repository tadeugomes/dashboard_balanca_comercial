library(leaflet)
library(htmlwidgets)

mapa <- leaflet() |>
    addTiles() |>
    setView(lng = -44.36672, lat = -2.57678, zoom = 15) |>
    addProviderTiles(providers$Esri.WorldImagery) |>
    addMiniMap(
        width = 100,
        height = 100,
        zoomLevelOffset = -5,
        zoomAnimation = TRUE,
        toggleDisplay = TRUE
    )

saveWidget(mapa, "www/mapa_itaqui.html", selfcontained = TRUE)