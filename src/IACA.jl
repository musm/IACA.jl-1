module IACA
export iaca_start, iaca_end, analyze

using LLVM
using LLVM.Interop

const optlevel = Ref{Int}()

function __init__()
    @assert LLVM.InitializeNativeTarget() == false
    optlevel[] = Base.JLOptions().opt_level
end

"""
    analyze(func, tt, march = :SKL)

Analyze a given function `func` with the type signature `tt`.
The specific method needs to be annotated with the `IACA` markers.
Supported `march` are :HSW, :BDW, :SKL, and :SKX.

# Example

```julia
function mysum(A)
    acc = zero(eltype(A))
    for a in A
        iaca_start()
        acc += a
    end
    iaca_end()
    return acc
end

analyze(mysum, Tuple{Vector{Float64}})
```

# Advanced usage
## Switching opt-level
```julia
IACA.optlevel[] = 3
analyze(mysum, Tuple{Vector{Float64}}, :SKL)
````

## Changing the optimization pipeline

```julia
myoptimize!(tm, mod) = ...
analyze(mysum. Tuple{Vector{Float64}}, :SKL, myoptimize!)
````
"""
function analyze(@nospecialize(func), @nospecialize(tt), march=:SKL, optimize!::Core.Function = jloptimize!)
    iaca_path = "iaca"
    if haskey(ENV, "IACA_PATH")
        iaca_path = ENV["IACA_PATH"]
    end
    @assert !isempty(iaca_path)

    cpus = Dict(
        :HSW => "haswell",
        :BDW => "broadwell",
        :SKL => "skylake",
        :SKX => "skx",
    )
    @assert haskey(cpus, march) "Arch: $march not supported"

    mktempdir() do dir
        objfile = joinpath(dir, "a.out")
        mod, _ = irgen(func, tt)
        target_machine(cpus[march]) do tm
            optimize!(tm, mod)
            LLVM.emit(tm, mod, LLVM.API.LLVMObjectFile, objfile)
        end
        Base.run(`$iaca_path -arch $march $objfile`)
    end
end

nameof(f::Core.Function) = String(typeof(f).name.mt.name)

function target_machine(lambda, cpu, features = "")
    triple = LLVM.triple()
    target = LLVM.Target(triple)
    LLVM.TargetMachine(lambda, target, triple, cpu, features)
end

globalUnique = 0

function irgen(@nospecialize(func), @nospecialize(tt))
    isa(func, Core.Builtin) && error("function is not a generic function")
    world = typemax(UInt)
    meth = which(func, tt)
    sig = Base.signature_type(func, tt)::Type

    (ti, env) = ccall(:jl_type_intersection_with_env, Any,
                      (Any, Any), sig, meth.sig)::Core.SimpleVector
    meth = Base.func_for_method_checked(meth, ti)
    linfo = ccall(:jl_specializations_get_linfo, Ref{Core.MethodInstance},
                  (Any, Any, Any, UInt), meth, ti, env, world)

    dependencies = Vector{LLVM.Module}()
    function hook_module_activation(ref::Ptr{Cvoid})
        ref = convert(LLVM.API.LLVMModuleRef, ref)
        push!(dependencies, LLVM.Module(ref))
    end

    params = Base.CodegenParams(cached=false,
                                module_activation  = hook_module_activation,
                                )

    # get the code
    mod = let
        ref = ccall(:jl_get_llvmf_defn, LLVM.API.LLVMValueRef,
                    (Any, UInt, Bool, Bool, Base.CodegenParams),
                    linfo, world, #=wrapper=#false, #=optimize=#false, params)
        if ref == C_NULL
            throw(CompilerError(ctx, "the Julia compiler could not generate LLVM IR"))
        end

        llvmf = LLVM.Function(ref)
        LLVM.parent(llvmf)
    end

    # the main module should contain a single jfptr_ function definition,
    # e.g. jfptr_kernel_vadd_62977
    definitions = LLVM.Function[]
    for llvmf in functions(mod)
        if !isdeclaration(llvmf)
            push!(definitions, llvmf)
        end
    end

    wrapper = nothing
    for llvmf in definitions
        if startswith(LLVM.name(llvmf), "jfptr_")
            @assert wrapper == nothing
            wrapper = llvmf
        end
    end
    @assert wrapper != nothing


    # the jfptr wrapper function should point us to the actual entry-point,
    # e.g. julia_kernel_vadd_62984
    # FIXME: Julia's globalUnique starting with `-` is probably a bug.
    entry_tag = let
        m = match(r"^jfptr_(.+)_[-\d]+$", LLVM.name(wrapper))
        if m == nothing 
            error(LLVM.name(wrapper))
        end
        m.captures[1]
    end
    unsafe_delete!(mod, wrapper)
    entry = let
        re = Regex("^julia_$(entry_tag)_[-\\d]+\$")
        entrypoints = LLVM.Function[]
        for llvmf in definitions
            if llvmf != wrapper
                llvmfn = LLVM.name(llvmf)
                if occursin(re, llvmfn)
                    push!(entrypoints, llvmf)
                end
            end
        end
        if length(entrypoints) != 1 
            @warn ":cry:" functions=Tuple(LLVM.name.(definitions)) tag=entry_tag entrypoints=Tuple(LLVM.name.(entrypoints))
        end
        entrypoints[1]
    end

    # link in dependent modules
    for dep in dependencies
        link!(mod, dep)
    end

    # rename the entry point
    llvmfn = replace(LLVM.name(entry), r"_\d+$"=>"")

    ## append a global unique counter
    global globalUnique
    globalUnique += 1
    llvmfn *= "_$globalUnique"
    LLVM.name!(entry, llvmfn)

    return mod, entry
end

"""
    jloptimize!(tm, mod)

Runs the Julia optimizer pipeline.
"""
function jloptimize!(tm::LLVM.TargetMachine, mod::LLVM.Module)
    ModulePassManager() do pm
        add_library_info!(pm, triple(mod))
        add_transform_info!(pm, tm)
        ccall(:jl_add_optimization_passes, Nothing,
              (LLVM.API.LLVMPassManagerRef, Cint),
               LLVM.ref(pm), optlevel[])
        run!(pm, mod)
    end
end

"""
    iaca_start()

Insertes IACA start marker at this position.
"""
function iaca_start()
    @asmcall("""
    movl \$\$111, %ebx
    .byte 0x64, 0x67, 0x90
    """, "~{memory},~{ebx}", true)
end

"""
    iaca_end()

Insertes IACA end marker at this position.
"""
function iaca_end()
    @asmcall("""
    movl \$\$222, %ebx
    .byte 0x64, 0x67, 0x90
    """, "~{memory},~{ebx}", true)
end

include("reflection.jl")
end # module
