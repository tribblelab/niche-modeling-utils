using CSV, DataFrames
using RCall

R"""
library(ggplot2)
library(sf)
library(ggspatial)
library(dplyr) #needs to be loaded in last, so it defaults to correct `filter` fxn
"""

"""
    filter_coords(input_path::String, output_path::String; kwargs...)

Remove rows outside the specified lat/lon bounding box.
All bounds are optional — specify only the axes you want to constrain.
Points with missing coordinates are dropped when a bound is supplied for that axis.
Always plots a preview map (green = kept, red × = removed).
Set `save=true` to write the filtered result back to the file.

# Arguments
- `input_path`: Path to the input CSV file.
- `output_path`: Path to save the filtered CSV file.
- `taxon_label`: Label for the plot title (default: "Taxon").
- `lat_min`, `lat_max`, `lon_min`, `lon_max`: Coordinate bounds.
- `save`: Boolean to indicate whether to save the output (default: false).
"""
function filter_coords(input_path::String, output_path::String;
    taxon_label="Taxon",
    lat_min=nothing, lat_max=nothing,
    lon_min=nothing, lon_max=nothing,
    save::Bool=false)

    if all(isnothing, (lat_min, lat_max, lon_min, lon_max))
        error("At least one of lat_min, lat_max, lon_min, lon_max must be specified")
    end

    function keep(row)
        lat = row.latitude
        lon = row.longitude
        if !isnothing(lat_min) || !isnothing(lat_max)
            (ismissing(lat) || !isa(lat, Number)) && return false
            !isnothing(lat_min) && lat < lat_min && return false
            !isnothing(lat_max) && lat > lat_max && return false
        end
        if !isnothing(lon_min) || !isnothing(lon_max)
            (ismissing(lon) || !isa(lon, Number)) && return false
            !isnothing(lon_min) && lon < lon_min && return false
            !isnothing(lon_max) && lon > lon_max && return false
        end
        return true
    end

    # Preview plot is built from the input version
    df = DataFrame(CSV.File(input_path))
    keep_mask = [keep(row) for row in eachrow(df)]
    kept_df = df[keep_mask, :]
    removed_df = df[.!keep_mask, :]
    n_kept = nrow(kept_df)
    n_removed = nrow(removed_df)

    println("  Preview: $n_removed point(s) will be removed, $n_kept will be kept")

    # Plot preview: green = kept, red × = removed
    kept_lat = Vector{Union{Missing,Float64}}(kept_df.latitude)
    kept_lon = Vector{Union{Missing,Float64}}(kept_df.longitude)
    removed_lat = Vector{Union{Missing,Float64}}(removed_df.latitude)
    removed_lon = Vector{Union{Missing,Float64}}(removed_df.longitude)
    @rput taxon_label kept_lat kept_lon removed_lat removed_lon
    R"""
    kept_pts    <- data.frame(latitude  = as.numeric(kept_lat),
                              longitude = as.numeric(kept_lon))
    removed_pts <- data.frame(latitude  = as.numeric(removed_lat),
                              longitude = as.numeric(removed_lon))
    all_lat <- c(kept_pts$latitude,  removed_pts$latitude)
    all_lon <- c(kept_pts$longitude, removed_pts$longitude)
    world    <- annotation_borders(database="world", colour="gray80", fill="gray80")
    borders  <- annotation_borders(database="world", colour="gray40", fill=NA, size=0.5)
    p <- ggplot() + world + borders +
        geom_point(data=kept_pts,
                   aes(x=longitude, y=latitude),
                   color="darkgreen", size=2, alpha=0.7) +
        { if (nrow(removed_pts) > 0)
              geom_point(data=removed_pts,
                         aes(x=longitude, y=latitude),
                         color="red", shape=4, size=3.5, stroke=1.2, alpha=0.9)
          else NULL } +
        coord_sf(xlim=c(min(all_lon, na.rm=TRUE)-2, max(all_lon, na.rm=TRUE)+2),
                 ylim=c(min(all_lat, na.rm=TRUE)-2, max(all_lat, na.rm=TRUE)+2)) +
        labs(title=paste0(taxon_label, "  —  green: kept (", nrow(kept_pts),
                          ")   red ×: removed (", nrow(removed_pts), ")"),
             x="Longitude", y="Latitude") +
        theme_minimal() +
        theme(plot.title=element_text(size=10))
    print(p)
    """

    if !save
        println(" Preview only — re-run with save=true to apply.")
        return nothing
    end

    CSV.write(output_path, kept_df)
    println(" Written: $output_path")
end

"""
    filter_countries(input_path::String, output_path::String, countries::Vector{String}; country_col::Symbol=:country, save::Bool=true)

Remove rows from a dataset that match specific countries (or any other regional category).

# Arguments
- `input_path`: Path to the input CSV file.
- `output_path`: Path to save the filtered CSV file.
- `countries`: A vector of country names to filter out.
- `country_col`: The symbol of the column containing country data (default: `:country`).
- `save`: Boolean to indicate whether to save the output (default: true).
"""
function filter_countries(input_path::String, output_path::String, countries::Vector{String}; country_col::Symbol=:country, save::Bool=true)
    df = DataFrame(CSV.File(input_path))

    if string(country_col) ∉ names(df)
        error("Column `$country_col` not found in dataframe")
    end

    dfcountries = df[!, country_col]
    if length(intersect(countries, dfcountries)) == 0
        @warn "No input country provided in `countries` list matches countries existing in dataframe"
    end

    for country in countries
        filter!(country_col => x -> !ismissing(x) && x != country, df)
    end

    if save
        CSV.write(output_path, df)
        println(" Written: $output_path")
    end
    
    return df
end

"""
    prepare_geolocate_files(input_dir::String, output_dir::String)
 
Read every CSV in `input_dir`, reformat columns to GEOLocate batch input
format, and write the result to `output_dir` (same filename).
 
Expected input columns: locality, country, stateProvince, county, latitude,
longitude, ID, scientificName, basisOfRecord.
 
Output columns (GEOLocate format): "locality string", country, state, county,
latitude, longitude, "correction status", precision, "error polygon",
"multiple results", ID, name, basis.
"""
function prepare_geolocate_files(
    input_dir::String,
    output_dir::String
)
    isdir(output_dir) || mkpath(output_dir)

    files = DataFrames.filter(f -> endswith(f, ".csv"), readdir(input_dir))

    if isempty(files)
        println("No CSV files found in $input_dir")
        return 0
    end

    converted_count = 0

    for (idx, file) in enumerate(files)
        println("Processing $idx/$(length(files)): $file")

        input_file = joinpath(input_dir, file)
        output_file = joinpath(output_dir, file)

        @rput input_file output_file

        R"""
        rawdf_GeoRef <- read.csv(input_file)

        if (nrow(rawdf_GeoRef) == 0) {
            cat("  Skipping - empty file\n")
            next
        }

        rawdf_GeoRef <- rawdf_GeoRef %>%
            dplyr::select("locality string" = locality,
                          country,
                          state = stateProvince,
                          county,
                          latitude,
                          longitude,
                          ID,
                          name = scientificName,
                          basis = basisOfRecord)

        rawdf_GeoRef$'correction status' <- ""
        rawdf_GeoRef$precision           <- ""
        rawdf_GeoRef$'error polygon'     <- ""
        rawdf_GeoRef$'multiple results'  <- ""

        rawdf_GeoRef2 <- rawdf_GeoRef[, c("locality string", "country",
                                           "state", "county", "latitude",
                                           "longitude", "correction status",
                                           "precision", "error polygon",
                                           "multiple results", "ID",
                                           "name", "basis")]

        write.csv(rawdf_GeoRef2, output_file, row.names = FALSE)
        """

        converted_count += 1
    end

    println("\nDone. Converted $converted_count files → $output_dir")
    return converted_count
end