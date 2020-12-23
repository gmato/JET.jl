# to reduce loading overhead for cases when we just use `profile_file`, `@report_call`
function init_revise!()
    @isdefined(Revise) || Core.eval(@__MODULE__, :(using Revise))
end

_profile_and_watch_file(args...; kwargs...) = _profile_and_watch_file(stdout::IO, args...; kwargs...)
function _profile_and_watch_file(io::IO,
                                 filename::AbstractString,
                                 args...;
                                 # revise options
                                 modules = nothing,
                                 all::Bool = true,
                                 # JET configurations
                                 profiling_logger::Union{Nothing,IO} = io, # enable logger by default for watch mode
                                 jetconfigs...)
    included_files, _ = profile_file(io, filename, args...;
                                     profiling_logger,
                                     jetconfigs...)

    interrupted = false
    while !interrupted
        try
            Revise.entr(collect(included_files), modules; all, postpone = true) do
                println(io)
                included_files′, _ = profile_file(io, filename, args...;
                                                  profiling_logger,
                                                  jetconfigs...)
                if any(∉(included_files), included_files′)
                    # refresh watch files
                    throw(InsufficientWatches(included_files′))
                end
                return nothing
            end
            interrupted = true # `InterruptException` was gracefully handled within `entr`, shutdown watch mode
        catch err
            # handle "expected" errors, keep running

            if isa(err, InsufficientWatches)
                included_files = err.included_files
                continue
            elseif isa(err, LoadError) ||
                   isa(err, KeyError) || # FIXME
                   (isa(err, ErrorException) && startswith(err.msg, "lowering returned an error")) ||
                   isa(err, Revise.ReviseEvalException)
                @warn err
                continue

            # async errors
            elseif isa(err, CompositeException)
                errs = err.exceptions
                i = findfirst(e->isa(e, TaskFailedException), errs)
                if i !== nothing
                    tfe = errs[i]::TaskFailedException
                    res = tfe.task.result
                    if isa(res, InsufficientWatches)
                        included_files = res.included_files
                        continue
                    elseif isa(res, LoadError) ||
                           isa(res, KeyError) || # FIXME
                           (isa(res, ErrorException) && startswith(res.msg, "lowering returned an error")) ||
                           isa(res, Revise.ReviseEvalException)
                        @warn res
                        continue
                    end
                end
            end

            @error "fatal uncaght error from Revise.jl" err
            @eval Main err = $(err)
            rethrow(err)
        end
    end
end

struct InsufficientWatches <: Exception
    included_files::Set{String}
end
