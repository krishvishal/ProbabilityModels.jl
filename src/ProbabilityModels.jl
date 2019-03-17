module ProbabilityModels

using   MacroTools, DiffRules,
        VectorizationBase, SIMDPirates, LoopVectorization, SLEEFPirates,
        PaddedMatrices, StructuredMatrices,
        DistributionParameters, ProbabilityDistributions,
        DynamicHMC, LogDensityProblems,
        Random, VectorizedRNG, RandomNumbers

import MacroTools: postwalk, prewalk, @capture, @q

export @model, NUTS_init_tune_mcmc_default, sample_cov, sample_mean

include("special_diff_rules.jl")
include("reverse_autodiff_passes.jl")
include("model_macro_passes.jl")
include("dynamic_hmc_interface.jl")

end # module
