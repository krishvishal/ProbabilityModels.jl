module ProbabilityModels

using   MacroTools, DiffRules, Parameters,
        VectorizationBase, SIMDPirates, LoopVectorization, SLEEFPirates,
        PaddedMatrices, StructuredMatrices,
        DistributionParameters, ProbabilityDistributions,
        Random, VectorizedRNG,
        LinearAlgebra, Statistics, Distributed, StackPointers
        # DynamicHMC, LogDensityProblems,MCMCChains

using VectorizedRNG: AbstractPCG, PtrPCG
using LoopVectorization: @vvectorize
using FunctionWrappers: FunctionWrapper
using MacroTools: postwalk, prewalk, @capture, @q
import PaddedMatrices: RESERVED_INCREMENT_SEED_RESERVED, RESERVED_DECREMENT_SEED_RESERVED,
    RESERVED_MULTIPLY_SEED_RESERVED, RESERVED_NMULTIPLY_SEED_RESERVED,
    AbstractFixedSizeVector, AbstractMutableFixedSizeVector,
    AbstractMutableFixedSizeArray
import QuasiNewtonMethods: AbstractProbabilityModel, logdensity, logdensity_and_gradient!, dimension
import DistributionParameters: parameter_names
import MCMCChainSummaries: MCMCChainSummary

export @model, logdensity, logdensity_and_gradient, logdensity_and_gradient!, MCMCChainSummaries#, NUTS_init_tune_mcmc_default, NUTS_init_tune_distributed, sample_cov, sample_mean

# function logdensity_and_gradient! end

const UNALIGNED_POINTER = Ref{Ptr{Cvoid}}()
const STACK_POINTER_REF = Ref{StackPointer}()
const LOCAL_STACK_SIZE = Ref{Int}()
const GLOBAL_PCGs = Vector{PtrPCG{4}}(undef,0)
const NTHREADS = Ref{Int}()


# LogDensityProblems.capabilities(::Type{<:AbstractProbabilityModel}) = LogDensityProblems.LogDensityOrder{1}()
# `@inline` so that we can avoid the allocation for tuple creation
# additionally, the logdensity(_and_gradient!) method itself will not in general
# be inlined. There is only a single method (on PtrVectors) defined,
# so that the functions will only have to be compiled once per AbstractProbabilityModel.
@inline function logdensity(
    ℓ::AbstractProbabilityModel{D},
    θ::AbstractVector{T},
    sptr::StackPointer = STACK_POINTER_REF[]
) where {D,T}
    @boundscheck length(θ) == D || PaddedMatrices.ThrowBoundsError()
    GC.@preserve θ begin
        θptr = PtrVector{D,T,D}(pointer(θ))
        lp = logdensity(ℓ, θptr, sptr)
    end
    lp
end
@inline function logdensity(
    ℓ::AbstractProbabilityModel{D},
    θ::AbstractMutableFixedSizeVector{D,T},
    sptr::StackPointer = STACK_POINTER_REF[]
) where {D,T}
    GC.@preserve θ begin
        θptr = PtrVector{D,T,D}(pointer(θ))
        lp = logdensity(ℓ, θptr, sptr)
    end
    lp
end
@inline function logdensity_and_gradient!(
    ∇::AbstractVector{T},
    ℓ::AbstractProbabilityModel{D},
    θ::AbstractVector{T},
    sptr::StackPointer = STACK_POINTER_REF[]
) where {D,T}
    @boundscheck max(length(∇),length(θ)) > D && PaddedMatrices.ThrowBoundsError()
    GC.@preserve ∇ θ begin
        ∇ptr = PtrVector{D,T,D}(pointer(∇));
        θptr = PtrVector{D,T,D}(pointer(θ));
        lp = logdensity_and_gradient!(∇ptr, ℓ, θptr, sptr)
    end
    lp
end
@inline function logdensity_and_gradient!(
    ∇::AbstractMutableFixedSizeVector{D,T},
    ℓ::AbstractProbabilityModel{D},
    θ::AbstractMutableFixedSizeVector{D,T},
    sptr::StackPointer = STACK_POINTER_REF[]
) where {D,T}
    GC.@preserve ∇ θ begin
        ∇ptr = PtrVector{D,T,D}(pointer(∇));
        θptr = PtrVector{D,T,D}(pointer(θ));
        lp = logdensity_and_gradient!(∇ptr, ℓ, θptr, sptr)
    end
    lp
end
@inline function logdensity_and_gradient(
    sp::StackPointer,
    ℓ::AbstractProbabilityModel{D},
    θ::AbstractMutableFixedSizeVector{D,T}
) where {D,T}
    ∇ = PtrVector{D,T,D}(pointer(sp,T))
    sp += VectorizationBase.align(D*sizeof(T))
    sp, (logdensity_and_gradient!(∇, ℓ, θ, sp), ∇)
end
@inline function logdensity_and_gradient(
    sp::StackPointer,
    ℓ::AbstractProbabilityModel{D},
    θ::AbstractVector{T}
) where {D,T}
    @boundscheck length(θ) > D && PaddedMatrices.ThrowBoundsError()
    ∇ = PtrVector{D,T,D}(pointer(sp,T))
    sp += VectorizationBase.align(D*sizeof(T))
    sp, (logdensity_and_gradient!(∇, ℓ, θ, sp), ∇)
end
@inline function logdensity_and_gradient(
    l::AbstractProbabilityModel{D}, θ, sptr::StackPointer = STACK_POINTER_REF[]
) where {D}
    ∇ = PaddedMatrices.mutable_similar(θ)
    logdensity_and_gradient!(∇, l, θ, sptr), ∇
end


verbose_models() = false


include("adjoints.jl")
include("misc_functions.jl")
include("special_diff_rules.jl")
include("reverse_autodiff_passes.jl")
include("model_macro_passes.jl")
include("mcmc_chains.jl")
include("rng.jl")

@def_stackpointer_fallback emax_dose_response ITPExpectedValue ∂ITPExpectedValue HierarchicalCentering ∂HierarchicalCentering
function __init__()
    NTHREADS[] = Threads.nthreads()
    # Note that 1 GiB == 2^30 == 1 << 30 bytesy
    # Allocates 0.5 GiB per thread for the stack by default.
    # Can be controlled via the environmental variable PROBABILITY_MODELS_STACK_SIZE
    LOCAL_STACK_SIZE[] = if "PROBABILITY_MODELS_STACK_SIZE" ∈ keys(ENV)
        parse(Int, ENV["PROBABILITY_MODELS_STACK_SIZE"])
    else
        1 << 29
    end + VectorizationBase.REGISTER_SIZE - 1 # so we have at least the indicated stack size after REGISTER_SIZE-alignment
    UNALIGNED_POINTER[] = Libc.malloc( NTHREADS[] * LOCAL_STACK_SIZE[] )
    STACK_POINTER_REF[] = PaddedMatrices.StackPointer( VectorizationBase.align(UNALIGNED_POINTER[]) )
    STACK_POINTER_REF[] = threadrandinit!(STACK_POINTER_REF[], GLOBAL_PCGs)
    # @eval const STACK_POINTER = STACK_POINTER_REF[]
    # @eval const GLOBAL_WORK_BUFFER = Vector{Vector{UInt8}}(Base.Threads.nthreads())
    # Threads.@threads for i ∈ eachindex(GLOBAL_WORK_BUFFER)
    #     GLOBAL_WORK_BUFFER[i] = Vector{UInt8}(0)
    # end
#    for m ∈ (:ITPExpectedValue, :∂ITPExpectedValue)
#        push!(PaddedMatrices.STACK_POINTER_SUPPORTED_METHODS, m)
    #    end
    @add_stackpointer_method emax_dose_response ITPExpectedValue ∂ITPExpectedValue HierarchicalCentering ∂HierarchicalCentering
end
function realloc_stack(new_local_stack_size::Integer)
    @warn """You must redefine all probability models. The stack pointers get dereferenced at compile time, and the stack has just been reallocated.
Re-evaluating densities without first recompiling them will likely crash Julia!"""
    LOCAL_STACK_SIZE[] = new_local_stack_size
    UNALIGNED_POINTER[] = Libc.realloc(UNALIGNED_POINTER[], new_local_stack_size + VectorizationBase.REGISTER_SIZE - 1)
    STACK_POINTER_REF[] = PaddedMatrices.StackPointer( VectorizationBase.align(UNALIGNED_POINTER[]) )
    STACK_POINTER_REF[] = threadrandinit!(STACK_POINTER_REF[], GLOBAL_PCGs)
end

rel_error(x, y) = (x - y) / y
function check_gradient(data, a = randn(length(data)))
    acopy = copy(a)
    lp, g = logdensity_and_gradient(data, a)
    all(i -> a[i] == acopy[i], eachindex(a)) || throw("Logdensity mutated inputs!?!?!?")
    for i ∈ eachindex(a)
        aᵢ = a[i]
        step = cbrt(eps(aᵢ))
        a[i] = aᵢ + step
        lp_hi = logdensity(data, a)
        a[i] = aᵢ - step
        lp_lo = logdensity(data, a)
        a[i] = aᵢ
        fd = (lp_hi - lp_lo) / (2step)
        ad = g[i]
        relative_error = rel_error(ad, fd)
        @show (i, ad, fd, relative_error)
        if abs(relative_error) > 1e-5
            fd_f = (lp_hi - lp) / step
            fd_b = (lp - lp_lo) / step
            @show rel_error.(ad, (fd_f, fd_b))
        end
    end
end

end # module
