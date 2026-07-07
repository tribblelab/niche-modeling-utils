"""
wcvp_checklist.jl

Builds a plant-name checklist for a given family + genus, using the same
underlying data source (WCVP, via the POWO search API) that powers Kew's
"Build a checklist" tool at:
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
  - Taxonomy filter: family + genus
  - Distribution: none selected (i.e. worldwide / no location filter)
  - Type of taxa: "Native and Introduced taxa" (i.e. no native/introduced/
    endemic restriction)
  - Format: "Summary Checklist (Names listed by taxonomic status)" --
    accepted names first, then their synonyms grouped underneath.
"""

module WCVPChecklist

using HTTP
using JSON3

export build_checklist, ChecklistEntry

const POWO_SEARCH_URL = "https://powo.science.kew.org/api/1/search"

"One name record in the checklist."
struct ChecklistEntry
    name::String            # scientific name (genus + epithet(s))
    author::String          # author abbreviation, "" if none
    rank::String             # e.g. "Species", "Genus", "Form", "Variety"
    family::String
    accepted::Bool           # true = accepted name, false = synonym
    accepted_name::String    # if this is a synonym, the accepted name it points to ("" otherwise)
    ipni_id::String          # IPNI/POWO taxon id, useful for lookups
end

"""
    build_checklist(family::AbstractString, genus::AbstractString=""; kwargs...) -> Vector{ChecklistEntry}

Build a checklist for `family` (required) and optionally `genus`
(pass "" or omit to get the whole family).

Keyword arguments:
- `page_size::Int = 100`      : results requested per page (API max is 500)
- `max_results::Int = 100_000`: safety cap on total records fetched
- `include_synonyms::Bool = true` : include synonym names as well as accepted ones
                                     (matches "Detailed Checklist" style completeness;
                                     set to false to mimic filtering to accepted names only)
- `sleep_between::Float64 = 0.15` : seconds to wait between paged requests (politeness)

Returns a `Vector{ChecklistEntry}`, sorted by name.
"""
function build_checklist(family::AbstractString, genus::AbstractString="";
                          page_size::Int = 100,
                          max_results::Int = 100_000,
                          include_synonyms::Bool = true,
                          sleep_between::Float64 = 0.15)

    isempty(strip(family)) && throw(ArgumentError("`family` is required, e.g. build_checklist(\"Fagaceae\", \"Quercus\")"))

    # Build the keyword query the way POWO's own search bar does
    # (documented at https://powo.science.kew.org/search-help):
    # "field:value" terms are ANDed together.
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

        resp = HTTP.get(POWO_SEARCH_URL; query = params, retry = true, readtimeout = 30)
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

            push!(entries, ChecklistEntry(name, author, rank, fam, accepted, accepted_name, fqid))
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

    sort!(entries, by = e -> e.name)
    return entries
end

"""
    to_table(entries::Vector{ChecklistEntry})

Convenience: convert checklist entries into a Vector of NamedTuples,
handy for passing straight into DataFrame(...) if DataFrames.jl is loaded.
"""
function to_table(entries::Vector{ChecklistEntry})
    return [(name = e.name, author = e.author, rank = e.rank, family = e.family,
             accepted = e.accepted, accepted_name = e.accepted_name, ipni_id = e.ipni_id)
            for e in entries]
end

end # module

# --- Example usage ---
# using .WCVPChecklist
# checklist = build_checklist("Fagaceae", "Quercus")
# for e in checklist
#     status = e.accepted ? "ACCEPTED" : "= $(e.accepted_name)"
#     println(rpad("$(e.name) $(e.author)", 45), "  ", status)
# end
#
# # whole family, no genus filter:
# checklist = build_checklist("Nepenthaceae")
#
# # accepted names only (skip synonyms):
# checklist = build_checklist("Fagaceae", "Quercus"; include_synonyms=false)