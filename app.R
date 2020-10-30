# Crear app: photon:::photon_rstudioaddin()

library(dplyr)
library(tidyr)
library(readxl)
library(openxlsx)
library(lubridate)

library(shiny)
options(shiny.maxRequestSize = 10*1024^2)

# Funcion para nombrar meses
mes2txt <- function(tmp_mes){
  case_when(
    tmp_mes == 1 ~ "Ene", tmp_mes == 2 ~ "Feb", tmp_mes == 3 ~ "Mar",
    tmp_mes == 4 ~ "Abr", tmp_mes == 5 ~ "May", tmp_mes == 6 ~ "Jun",
    tmp_mes == 7 ~ "Jul", tmp_mes == 8 ~ "Ago", tmp_mes == 9 ~ "Sep",
    tmp_mes == 10 ~ "Oct",tmp_mes == 11 ~"Nov",tmp_mes == 12 ~ "Dic"
  )
}

# Funcion para generar campos calculados
calcular_campos <- function(tmp_data) {
  tmp_data %>%
    mutate(
      medicion_mensual = as.logical(medicion_mensual),
      fuente_indicador = trimws(fuente_indicador),
      lb = round(as.numeric(lb), 4),
      valor_denominador = as.numeric(valor_denominador),
      meta = round(as.numeric(meta), 4),
      valor_numerador = as.numeric(valor_numerador),
      valor_indicador = round(as.numeric(valor_indicador), 4),
      # Se agrega una constante para dar visibilidad a los ceros en grafico comparativo
      valor_propmax =
        case_when(
          tipo_indicador == "porcentaje" ~ valor_indicador,
          tipo_indicador == "conteo" ~ valor_indicador / meta
        ) + 0.1,
      valor_propmeta = valor_indicador / meta,
      cierre_indicador_txt =
        mes2txt(month(cierre_indicador)) %>% paste(year(cierre_indicador)),
      lb_formato =
        case_when(
          tipo_indicador == "conteo" ~
            as.character(round(lb, 2)),
          tipo_indicador == "porcentaje" ~
            paste(round(100 * lb, 2), "%")
        ),
      meta_formato =
        case_when(
          tipo_indicador == "conteo" ~
            as.character(round(meta, 2)),
          tipo_indicador == "porcentaje" ~
            paste(round(100 * meta, 2), "%")
        ),
      valor_indicador_formato =
        case_when(
          tipo_indicador == "conteo" & !is.na(valor_indicador) ~
            as.character(round(valor_indicador, 2)),
          tipo_indicador == "porcentaje" &
            !is.na(valor_indicador) ~
            paste(round(100 * valor_indicador, 2), "%"),
          TRUE ~ "-"
        ),
      semaforo_bien = as.integer(0.9 <= valor_propmeta),
      semaforo_regular = as.integer(0.7 <= valor_propmeta &
                                      valor_propmeta < 0.9),
      semaforo_mal = as.integer(valor_propmeta < 0.7),
      semaforo_txt =
        case_when(
          semaforo_bien == 1 ~ "Buen avance",
          semaforo_regular == 1 ~ "Avance regular",
          semaforo_mal == 1 ~ "En riesgo"
        ),
      detalle_txt =
        case_when(
          tipo_indicador == "porcentaje" ~
            paste0(
              "Numerador:     ",
              ifelse(is.na(valor_numerador), "-", valor_numerador),
              "\nDenominador: ",
              ifelse(is.na(valor_denominador), "-", valor_denominador)
            ),
          tipo_indicador == "conteo" ~
            paste0("Numerador:     ",
                   ifelse(
                     is.na(valor_indicador), "-", valor_indicador
                   ))
        )
    )
}

# Funcion para procesar datos
procesar <- function(t1, t2, t3){
    # CARGA DE DATOS
    # 1. Lineas de base, metas e indicador de muni inscrita
    read_xlsx(t1,
              skip = 6, col_types = "text") %>%
        filter(!is.na(Nº)) -> basales
    # 2. Valores
    read_xlsx(t2,
              skip = 5, col_types = "text", sheet = "Seguimiento") %>%
        filter(!is.na(Nº)) -> valores
    # 3. Descripcion de indicadores
    read_xlsx(t3) %>%
        mutate(cierre_indicador = ymd(cierre_indicador)) -> indicadores
    
    ### PROCESAMIENTO
    ### Limpiar tabla de basales
    basales[, c(
        # Detectar columnas de ubigeo
        names(basales) %>%
            grep(pattern = "^UBIGEO|REGION|PROVINCIA|DISTRITO", .),
        # Detectar columnas de inscripcion mas reciente
        names(basales) %>%
            grep(pattern = paste("Inscritas SM", year(Sys.Date())), .),
        # Detectar columnas de basal y meta
        names(basales) %>%
            grep(pattern = "LINEA DE BASE|META", .))] %>%
        # Transformar a formato long
        pivot_longer(
            cols = !contains(c("UBIGEO", "REGION", "PROVINCIA", "DISTRITO", "Inscritas SM"))) %>%
        mutate(
            # Colocar ID de indicador en cada fila
            # (OJO: se asume que tabla 1 y 3 colocan indicadores en el mismo orden)
            id_indicador =
                indicadores %>%
                pull(id_indicador) %>% rep(each = 2) %>% rep(times = nrow(basales)),
            # Renombrar filas (que pasaran a columnas)
            name =
                case_when(
                    substr(name, 1, 13) == "LINEA DE BASE" ~ "lb",
                    substr(name, 1, 4) == "META" ~ "meta",
                    )) %>%
        # Regresar a formato wide
        pivot_wider(names_from = "name", values_from = "value") %>%
        # Excluir indicadores que no aplican para el municipio
        filter(!(lb == "N.C." & meta == "N.C.")) -> basales_limpio
    # Editar formatos de columnas
    names(basales_limpio)[1:5] <- c(tolower(names(basales_limpio))[1:4],"participa")
    
    ### Extraer valores de reporte de seguimiento
    valores[, c(
        # Detectar columna de ubigeo
        names(valores) %>%
            grep(pattern = "UBIGEO", .),
        # Detectar rango de columnas con valores
        `:`(names(valores) %>%
                grep(pattern = "LINEA DE BASE", .) %>% min,
            names(valores) %>%
                grep(pattern = "Calificaci", .) %>% max))] -> valores_limpio
    
    # Calcular numero de periodos de medicion
    (ncol(valores_limpio) - 1 - (indicadores %>% filter(medicion_mensual == 1) %>% nrow)*2)/
        ((indicadores %>%
              filter(medicion_mensual == 1 & tipo_indicador == "porcentaje") %>% nrow)*4 +
             (indicadores %>%
                  filter(medicion_mensual == 1 & tipo_indicador == "conteo") %>% nrow)*2
         ) -> num_mediciones
    
    ### Continuar procesamiento de tabla de valores
    valores_limpio %>%
        pivot_longer(cols = !contains(c("UBIGEO"))) %>%
        # Renombrar filas (que pasaran a columnas)
        mutate(
            new_names =
                case_when(
                    substr(name, 1, 13) == "LINEA DE BASE" ~ "lb",
                    substr(name, 1, 4) == "META" ~ "meta",
                    substr(name, 1, 2) == "N_" ~ "valor_numerador",
                    substr(name, 1, 2) == "D_" ~ "valor_denominador",
                    substr(name, 1, 6) == "Valor " ~ "valor_indicador",
                    substr(name, 1, 13) == "Calificación " ~ "semaforo",
                    TRUE ~ name
                    )) %>%
        # Excluir filas con informacion que no sera usada
        filter(!(new_names %in% c("lb", "meta", "semaforo"))) %>%
        # Colocar ID de indicador en cada fila
        mutate(
            id_indicador =
                indicadores %>%
                filter(medicion_mensual == 1) %>%
                transmute(
                    id_indicador,
                    nrep = 
                        case_when(
                            tipo_indicador == "porcentaje" ~ 2,
                            tipo_indicador == "conteo" ~ 0)*num_mediciones + # num + dem
                        num_mediciones # valor + calificacion
                    ) %>%
                apply(1, function(x)rep(x[1], each = x[2])) %>% unlist %>%
                rep(nrow(valores))
            ) %>%
        # Descartar nombres antiguos
        select(-name) %>%
        rename(ubigeo = UBIGEO) -> valores_limpio

    # Crear indicadores de tiempo de medicion para cada fila
    bind_rows(
        tibble(
            tipo_indicador = "porcentaje",
            tiempo_medicion = c(rep(1:num_mediciones, each = 2), 1:num_mediciones)) %>%
            mutate(tmp_orden = 1:n()),
        tibble(
            tipo_indicador = "conteo",
            tiempo_medicion = 1:num_mediciones) %>%
            mutate(tmp_orden = 1:n())) -> tiempos_indicador
    
    ### Union de tablas
    basales_limpio %>%
        left_join(
            # Agregar indicadores de tiempo a filas de valores
            valores_limpio %>%
                group_by(ubigeo, id_indicador) %>%
                mutate(tmp_orden = 1:n()) %>%
                left_join(
                    indicadores %>% select(id_indicador, tipo_indicador),
                    by = "id_indicador") %>%
                left_join(
                    tiempos_indicador,
                    by = c("tipo_indicador", "tmp_orden")) %>%
                select(-tmp_orden, -tipo_indicador) %>%
                pivot_wider(
                    id_cols = c("ubigeo", "id_indicador", "tiempo_medicion"),
                    names_from = c("new_names"),
                    values_from = c("value")),
            by = c("ubigeo", "id_indicador")) %>%
        left_join(indicadores, by = "id_indicador") %>%
    ### Limpiar variables y generar campos calculados
      calcular_campos %>%
      mutate(distrito_ubigeo = paste0(distrito," (", ubigeo,")")) %>%
        filter(!is.na(lb)&!is.na(meta)) -> datos_final
    
    ### Agregar filas con indicador "0"
    ### (uso para mapa, garantiza que todas las munis tienen su fila)
    datos_final %>%
        select(ubigeo, region, provincia, distrito) %>% unique %>%
        mutate(id_indicador = "0", tiempo_medicion = NA,
               medicion_mensual = TRUE) %>%
        left_join(
            basales_limpio %>% select(ubigeo, participa) %>% unique,
            by = "ubigeo") %>%
        bind_rows(datos_final) %>%
        # Completar tiempos vacios con 0
        mutate(tiempo_medicion =
                   case_when(
                       is.na(tiempo_medicion) ~ as.double(0),
                       TRUE ~ as.double(tiempo_medicion))
               ) -> datos_final
    
    ### Agregar filas con datos simulados para modo de prueba
    ### (tambien garantiza que Tableau almacene los esquemas de colores)
    bind_rows(
      datos_final %>%
        filter(ubigeo == "010101" & id_indicador != "0") %>%
        mutate(
          prueba = 1,
          participa = "1",
          valor_denominador =
            case_when(medicion_mensual &
                        tipo_indicador == "porcentaje" ~ 100),
          valor_numerador =
            case_when(
              tiempo_medicion == 1 &
                medicion_mensual & tipo_indicador == "porcentaje" ~
                round((meta - lb) * 0.5) * 100,
              tiempo_medicion == 2 &
                medicion_mensual & tipo_indicador == "porcentaje" ~
                round((meta - lb) * 0.8 * 100),
              tiempo_medicion == 3 &
                medicion_mensual & tipo_indicador == "porcentaje" ~
                round((meta - lb) * 0.95 * 100)
            ),
          valor_indicador =
            case_when(
              tiempo_medicion == 1 &
                medicion_mensual & tipo_indicador == "conteo" ~ 0,
              tiempo_medicion == 2 &
                medicion_mensual & tipo_indicador == "conteo" ~ 1,
              tiempo_medicion == 3 &
                medicion_mensual & tipo_indicador == "conteo" ~ 2,
              medicion_mensual &
                tipo_indicador == "porcentaje" ~ valor_numerador / valor_denominador
            )
        ) %>%
        calcular_campos,
      datos_final %>%
        filter(ubigeo == "010102" & id_indicador != "0") %>%
        mutate(
          prueba = 1,
          participa = "0"
        ) %>%
        calcular_campos,
      datos_final %>%
        filter(ubigeo %in% c("010101", "010102", "010201", "020101") &
                 id_indicador == "0") %>%
        mutate(prueba = 1,
               participa = c("1", "0", "0", "0"))
    ) %>%
      bind_rows(datos_final) %>%
      mutate(prueba = ifelse(!is.na(prueba), prueba, 0)
             ) -> datos_final
    
    return(datos_final)
}

# Construir aplicativo
ui <- fluidPage(

    # Titulo
    titlePanel("Generar insumos para Tablero SM"),

    # Carga de archivos
    fileInput("t01", "Cargar LB+Metas",
              accept = ".xlsx"),
    fileInput("t02", "Cargar Reporte de seguimiento",
              accept = ".xlsx"),
    fileInput("t03", "Cargar descripción de indicadores",
              accept = ".xlsx"),
    
    # Enlaces para descarga
    downloadLink("procesado1", label = "Descargar Procesado 1"),
    br(),
    downloadLink("procesado2", label = "Descargar Procesado 2")
)

# Define server logic required to draw a histogram
server <- function(input, output) {
    
    procesado <- reactive({
        procesar(input$t01$datapath, input$t02$datapath, input$t03$datapath)
    })
    
    output$procesado1 <- downloadHandler(
        filename = "procesado1.xlsx",
        content = function(file) {
            write.xlsx(procesado(), file)
        }
    )
    
    output$procesado2 <- downloadHandler(
        filename = "procesado2.xlsx",
        content = function(file) {
            write.xlsx(
              procesado() %>%
                select(distrito, tiempo_medicion, id_indicador, ubigeo, prueba,
                       semaforo_txt, valor_indicador_formato, valor_propmax) %>%
                mutate(provigeo = substr(ubigeo, 1, 4)),
              file)
        }
    )
    
}

# Run the application 
shinyApp(ui = ui, server = server)
