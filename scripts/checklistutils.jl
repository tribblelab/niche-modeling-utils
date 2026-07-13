"""
checklistutils.jl

Builds a plant-name checklist for a given family + genus (or genera), using
the same underlying data source (WCVP, via the POWO search API) that powers
Kew's "Build a checklist" tool at:
https://checklistbuilder.science.kew.org/reportbuilder.do

NOTE ON WHY THIS TALKS TO powo.science.kew.org INSTEAD OF checklistbuilder:
`reportbuilder.do` is a legacy, session-bound multi-page Java web app
(jsessionid, hidden form state, a genus dropdown that's AJAX-populated only
after a family is picked). It has no documented/stable set of POST
parameters, so it can't be reliably driven from an external script -- any
attempt would be guesswork that could silently return wrong results.

The POWO search API (used internally by Kew's own `pykew` and the
community `kewr` R package) exposes the same WCVP-backed data and is
queryable directly. This function reproduces the checklist builder's
*default* settings:
  - Taxonomy filter: family + genus (or genera)
  - Distribution: none selected (i.e. worldwide / no location filter)
  - Type of taxa: "Native and Introduced taxa" (i.e. no native/introduced/
    endemic restriction)
  - Format: "Summary Checklist (Names listed by taxonomic status)" --
    accepted names first, then their synonyms grouped underneath.
"""

#module WCVPChecklist

using HTTP
using JSON3
using DataFrames
using CSV

export build_checklist, ChecklistEntry, to_table

const POWO_SEARCH_URL = "https://powo.science.kew.org/api/1/search"
const POWO_TAXON_URL  = "https://powo.science.kew.org/api/2/taxon"

"""
    _fetch_native_range(fqid; sleep_after) -> String

Internal: look up a single taxon's native distribution from POWO's taxon
detail endpoint (the search endpoint doesn't carry distribution data, so
this is a separate request per accepted name). Returns a "; "-joined list
of native TDWG area names, or "" if unavailable/unparseable.
"""
function _fetch_native_range(fqid::AbstractString; sleep_after::Float64)
    isempty(fqid) && return ""

    url = "$(POWO_TAXON_URL)/$(HTTP.escapeuri(fqid))"
    native_range = ""
    try
        resp = HTTP.get(url; query = Dict("fields" => "distribution"),
                         retry = true, request_timeout = 30)
        body = JSON3.read(String(resp.body))

        if haskey(body, :distribution) && !isnothing(body.distribution) &&
           haskey(body.distribution, :natives) && !isnothing(body.distribution.natives)
            names = [string(get(area, :name, "")) for area in body.distribution.natives]
            filter!(!isempty, names)
            native_range = join(names, "; ")
        end
    catch e
        @warn "Could not fetch native range for taxon $fqid" exception = e
    end

    sleep(sleep_after)
    return native_range
end

"One name record in the checklist."
struct ChecklistEntry
    name::String            # scientific name (genus + epithet(s))
    author::String          # author abbreviation, "" if none
    rank::String             # e.g. "Species", "Genus", "Form", "Variety"
    family::String
    genus_queried::String     # which genus this record was fetched under (helps when querying multiple genera)
    accepted::Bool           # true = accepted name, false = synonym
    accepted_name::String    # if this is a synonym, the accepted name it points to ("" otherwise)
    ipni_id::String          # IPNI/POWO taxon id, useful for lookups
    native_range::String     # "; "-joined list of native botanical (TDWG) country/area
                              # names, e.g. "China South-Central; China Southeast; Taiwan".
                              # Only populated for accepted names (see `include_distribution`);
                              # "" if not fetched or not available.
end

"""
    _fetch_one(family, genus; page_size, max_results, include_synonyms, sleep_between) -> Vector{ChecklistEntry}

Internal: fetch (and page through) results for a single family/genus combination.
`genus` may be "" to fetch the whole family.
"""
function _fetch_one(family::AbstractString, genus::AbstractString;
                     page_size::Int, max_results::Int,
                     include_synonyms::Bool, sleep_between::Float64)

    query_parts = String["family:$(strip(family))"]
    if !isempty(strip(genus))
        push!(query_parts, "genus:$(strip(genus))")
    end
    query_str = join(query_parts, ",")

    entries = ChecklistEntry[]
    cursor = "*"
    fetched = 0

    while true
        params = Dict(
            "q"       => query_str,
            "perPage" => string(page_size),
            "cursor"  => cursor,
        )

        resp = HTTP.get(POWO_SEARCH_URL; query = params, retry = true, request_timeout = 30)
        body = JSON3.read(String(resp.body))

        results = haskey(body, :results) ? body.results : Any[]
        isempty(results) && break

        for r in results
            accepted = get(r, :accepted, false)
            if !accepted && !include_synonyms
                continue
            end

            name    = string(get(r, :name, ""))
            author  = string(get(r, :author, ""))
            rank    = string(get(r, :rank, ""))
            fam     = string(get(r, :family, ""))
            fqid    = string(get(r, :fqId, ""))

            accepted_name = ""
            if haskey(r, :synonymOf) && !isnothing(r.synonymOf)
                accepted_name = string(get(r.synonymOf, :name, ""))
            end

            push!(entries, ChecklistEntry(name, author, rank, fam, genus, accepted, accepted_name, fqid, ""))
        end

        fetched += length(results)
        total = get(body, :totalResults, fetched)

        next_cursor = string(get(body, :cursor, ""))
        if fetched >= total || fetched >= max_results || next_cursor == cursor || isempty(next_cursor)
            break
        end
        cursor = next_cursor

        sleep(sleep_between)
    end

    return entries
end

"""
    build_checklist(family, genus=""; kwargs...) -> DataFrame

Build a checklist for `family` (required) and optionally `genus`.

`genus` can be:
- omitted or `""`                -> whole family
- a single genus name, e.g. `"Quercus"`
- a vector of genus names, e.g. `["Quercus", "Castanea", "Fagus"]`
  (each genus is queried separately against the same family and the
  results are combined and de-duplicated)

Keyword arguments:
- `page_size::Int = 100`      : results requested per page (API max is 500)
- `max_results::Int = 100_000`: safety cap on total records fetched *per genus*
- `include_synonyms::Bool = true` : include synonym names as well as accepted ones
                                     (matches "Detailed Checklist" style completeness;
                                     set to false to mimic filtering to accepted names only)
- `sleep_between::Float64 = 0.15` : seconds to wait between paged requests (politeness)
- `include_distribution::Bool = true` : fetch each accepted name's native botanical
    (TDWG) country/area range from POWO's taxon detail endpoint. This costs one
    extra HTTP request per *unique accepted name*, so it's the slowest part of
    a large checklist -- set to `false` to skip it and get results faster.
    Synonyms are left with `native_range = ""` (their accepted name carries the
    range instead).
- `distribution_sleep::Float64 = 0.1` : seconds to wait between per-taxon
    distribution requests (politeness)
- `output_file::Union{Nothing,AbstractString} = nothing` :
    if given, also write the checklist out to this path.
    - a path ending in `.csv` is written with CSV.jl
    - any other extension (e.g. `.txt`) is written as an aligned plain-text table

Returns a `DataFrame` sorted by (genus_queried, name).
"""
function build_checklist(family::AbstractString,
                          genus::Union{AbstractString,AbstractVector{<:AbstractString}}="";
                          page_size::Int = 100,
                          max_results::Int = 100_000,
                          include_synonyms::Bool = true,
                          sleep_between::Float64 = 0.15,
                          include_distribution::Bool = true,
                          distribution_sleep::Float64 = 0.1,
                          output_file::Union{Nothing,AbstractString} = nothing)

    isempty(strip(family)) && throw(ArgumentError("`family` is required, e.g. build_checklist(\"Fagaceae\", \"Quercus\")"))

    genera = genus isa AbstractString ? [genus] : collect(genus)
    # Normalize: drop blanks/duplicates while preserving order, unless the
    # only entry is "" (whole-family request), which we keep as-is.
    if !(length(genera) == 1 && isempty(strip(genera[1])))
        seen = Set{String}()
        cleaned = String[]
        for g in genera
            gs = strip(g)
            isempty(gs) && continue
            if !(gs in seen)
                push!(seen, gs)
                push!(cleaned, gs)
            end
        end
        isempty(cleaned) && throw(ArgumentError("`genus` was provided but contained no usable genus names"))
        genera = cleaned
    end

    all_entries = ChecklistEntry[]
    seen_keys = Set{Tuple{String,String}}()  # (ipni_id, name) de-dup across genera

    for g in genera
        entries = _fetch_one(family, g;
                              page_size = page_size, max_results = max_results,
                              include_synonyms = include_synonyms, sleep_between = sleep_between)
        for e in entries
            key = (e.ipni_id, e.name)
            if !(key in seen_keys)
                push!(seen_keys, key)
                push!(all_entries, e)
            end
        end
    end

    if include_distribution
        range_cache = Dict{String,String}()  # ipni_id -> native_range, avoids re-fetching
        for (i, e) in enumerate(all_entries)
            e.accepted || continue  # synonyms don't carry their own range
            isempty(e.ipni_id) && continue

            native_range = get!(range_cache, e.ipni_id) do
                _fetch_native_range(e.ipni_id; sleep_after = distribution_sleep)
            end

            if !isempty(native_range)
                all_entries[i] = ChecklistEntry(e.name, e.author, e.rank, e.family, e.genus_queried,
                                                 e.accepted, e.accepted_name, e.ipni_id, native_range)
            end
        end
    end

    sort!(all_entries, by = e -> (e.genus_queried, e.name))

    df = DataFrame(to_table(all_entries))

    if output_file !== nothing
        _write_checklist(df, output_file)
    end

    return df
end

"""
    to_table(entries::Vector{ChecklistEntry})

Convenience: convert checklist entries into a Vector of NamedTuples,
handy for passing straight into DataFrame(...).
"""
function to_table(entries::Vector{ChecklistEntry})
    return [(name = e.name, author = e.author, rank = e.rank, family = e.family,
             genus_queried = e.genus_queried, accepted = e.accepted,
             accepted_name = e.accepted_name, ipni_id = e.ipni_id,
             native_range = e.native_range)
            for e in entries]
end

"""
    _write_checklist(df::DataFrame, path::AbstractString)

Internal: write a checklist DataFrame to `path`. `.csv` -> CSV.jl;
anything else -> an aligned plain-text table (one line per name, synonyms
marked with "= <accepted name>").
"""
function _write_checklist(df::DataFrame, path::AbstractString)
    if lowercase(splitext(path)[2]) == ".csv"
        CSV.write(path, df)
    else
        open(path, "w") do io
            namewidth = isempty(df.name) ? 10 : maximum(length("$(r.name) $(r.author)") for r in eachrow(df))
            statuswidth = isempty(df.name) ? 10 :
                maximum(r.accepted ? length("ACCEPTED") : length("= $(r.accepted_name)") for r in eachrow(df))
            for r in eachrow(df)
                status = r.accepted ? "ACCEPTED" : "= $(r.accepted_name)"
                label = "$(r.name) $(r.author)"
                range_str = isempty(r.native_range) ? "" : "  [$(r.native_range)]"
                println(io, rpad(label, namewidth + 2), rpad(status, statuswidth + 2), range_str)
            end
        end
    end
    return path
end

#end # module

# --- Example usage ---
# include("scripts/checklistutils.jl")
#
# # single genus, get a DataFrame:
# df = build_checklist("Fagaceae", "Quercus")
#
# # whole family, no genus filter:
# df = build_checklist("Nepenthaceae")
#
# # accepted names only (skip synonyms):
# df = build_checklist("Fagaceae", "Quercus"; include_synonyms=false)
#
# # multiple genera from the same family, combined into one checklist:
# df = build_checklist("Fagaceae", ["Quercus", "Castanea", "Fagus"])
#
# # write results out while you're at it:
# df = build_checklist("Fagaceae", ["Quercus", "Castanea"]; output_file="fagaceae_checklist.csv")
# df = build_checklist("Fagaceae", ["Quercus", "Castanea"]; output_file="fagaceae_checklist.txt")
#
# # df.native_range now holds each accepted name's native TDWG country/area range,
# # e.g. "China South-Central; China Southeast; Taiwan"
#
# # skip the (slower) per-taxon distribution lookups if you don't need ranges:
# df = build_checklist("Fagaceae", "Quercus"; include_distribution=false)
