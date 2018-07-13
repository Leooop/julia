Base.__init__()

function generate_precompilable_package(path)
    pkgname = "Package"
    mkpath(joinpath(path, pkgname, "src"))
    write(joinpath(path, pkgname, "src", "Package.jl"),
          """
          __precompile__()
          module Package
          end
          """)
end

function generate_precompile_statements()
    println("Generating precompile statements...")

    tmpd = mktempdir()
    generate_precompilable_package(tmpd)
    # To not put .ji file in ~/.julia/compiled
    push!(DEPOT_PATH, tmpd)
    push!(LOAD_PATH, tmpd)
    @eval using Package
    pop!(LOAD_PATH)
    pop!(DEPOT_PATH)
    t = time()

    sysimg = joinpath(dirname(Sys.BINDIR), "lib", "julia", "sys")
    tmp = tempname()
    touch(tmp)
    have_repl =  haskey(Base.loaded_modules,
                        Base.PkgId(Base.UUID("3fa0cd96-eef1-5676-8a61-b3b8758bbffb"), "REPL"))
    if have_repl
        # Have a REPL, run the repl replayer and an interactive session that we immidiately kill
        setup = """
        include("$(joinpath(@__DIR__, "precompile_replay.jl"))")
        @async while true
            sleep(0.01)
            if isdefined(Base, :active_repl)
                exit(0)
            end
        end
        """
        # Do not redirect stdin unless it is to a tty, because that changes code paths
        run(pipeline(`$(Base.julia_cmd()) --sysimage $sysimg.ji --trace-compile=yes -O0
                     --startup-file=no --q -e $setup -i`; stderr=tmp))
    else
        # No REPL, just record the startup
        run(pipeline(`$(Base.julia_cmd()) --sysimage $sysimg.ji --trace-compile=yes -O0
                     --startup-file=no --q -e0`; stderr=tmp))
    end

    # Replace the FakeTerminal with a TTYYerminal and filter out everything we compiled in Main
    precompiles = readlines(tmp)
    new_precompiles = Set{String}()
    for statement in precompiles
        startswith(statement, "precompile(Tuple{") || continue
        statement = replace(statement, "FakeTerminals.FakeTerminal" => "REPL.Terminals.TTYTerminal")
        (occursin(r"Main.", statement) || occursin(r"FakeTerminals.", statement)) && continue
        push!(new_precompiles, statement)
    end

    write(tmp, join(sort(collect(new_precompiles)), '\n'))
    # Load the precompile statements
    PrecompileStagingArea = Module()
    for (_pkgid, _mod) in Base.loaded_modules
        if !(_pkgid.name in ("Main", "Core", "Base"))
            @eval PrecompileStagingArea $(Symbol(_mod)) = $_mod
        end
    end

    Base.include(PrecompileStagingArea, tmp)
    if have_repl
        @eval PrecompileStagingArea begin
            # Could startup with REPL banner instead but it is a bit visually noisy,
            # so just precompile it here.
            precompile(Tuple{typeof(Base.banner), REPL.Terminals.TTYTerminal})
        end
    end

    rm(tmp)
    rm(tmpd; recursive=true)

    print("$(length(new_precompiles)) precompile statements generated in"), Base.time_print((time() - t) * 10^9)
    println()
    return
end

generate_precompile_statements()

