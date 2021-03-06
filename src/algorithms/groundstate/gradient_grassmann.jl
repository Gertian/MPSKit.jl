"""
GradientGrassmann is an optimisation methdod that keeps the MPS in left-canonical form, and
treats the tensors as points on Grassmann manifolds. It then applies one of the standard
gradient optimisation methods, e.g. conjugate gradient, to the MPS, making use of the
Riemannian manifold structure. A preconditioner is used, so that effectively the metric used
on the manifold is that given by the Hilbert space inner product.

The arguments to the constructor are
method = OptimKit.ConjugateGradient
    The gradient optimisation method to be used. Should either be an instance or a subtype
    of `OptimKit.OptimizationAlgorithm`. If it's an instance, this `method` is simply used
    to do the optimisation. If it's a subtype, then an instance is constructed as
    `method(; maxiter=maxiter, verbosity=verbosity, gradtol=tol)`

finalize! = OptimKit._finalize!
    A function that gets called once each iteration. See OptimKit for details.

tol = Defaults.tol
maxiter = Defaults.maxiter
verbosity = 2
    Arguments passed to the `method` constructor. If `method` is an instance of
    `OptimKit.OptimizationAlgorithm`, these argument are ignored.

In other words, by default conjugate gradient is used. One can easily set `tol`, `maxiter`
and `verbosity` for it, or switch to LBFGS or gradient descent by setting `method`. If more
control is wanted over things like specifics of the linesearch, CG flavor or the `m`
parameter of LBFGS, then the user should create the `OptimKit.OptimizationAlgorithm`
instance manually and pass it as `method`.
"""
struct GradientGrassmann <: Algorithm
    method::OptimKit.OptimizationAlgorithm
    finalize!::Function

    function GradientGrassmann(; method = ConjugateGradient,
                               finalize! = OptimKit._finalize!,
                               tol = Defaults.tol,
                               maxiter = Defaults.maxiter,
                               verbosity = 2)
        if isa(method, OptimKit.OptimizationAlgorithm)
            # We were given an optimisation method, just use it.
            m = method
        elseif method <: OptimKit.OptimizationAlgorithm
            # We were given an optimisation method type, construct an instance of it.
            m = method(; maxiter=maxiter, verbosity=verbosity, gradtol=tol)
        else
            msg = "method should be either an instance or a subtype of OptimKit.OptimizationAlgorithm."
            throw(ArgumentError(msg))
        end
        return new(m, finalize!)
    end
end

function find_groundstate(state::InfiniteMPS, H::Hamiltonian, alg::GradientGrassmann,
                          pars=params(state, H))
    method = alg.method
    method === nothing && (method = alg.methodtype(; maxiter=alg.maxiter,
                                                       verbosity=alg.verbosity,
                                                       gradtol=alg.tol))
    res = optimize(GrassmannInfiniteMPS.fg, (state, pars), method;
                   transport! = GrassmannInfiniteMPS.transport!,
                   retract = GrassmannInfiniteMPS.retract,
                   inner = GrassmannInfiniteMPS.inner,
                   scale! = GrassmannInfiniteMPS.scale!,
                   add! = GrassmannInfiniteMPS.add!,
                   finalize! = alg.finalize!,
                   precondition = GrassmannInfiniteMPS.precondition,
                   isometrictransport = true)
    (x, fx, gx, numfg, normgradhistory) = res
    (state, pars) = x
    return state, pars, normgradhistory[end]
end


# We separate some of the internals needed for implementing GradientGrassmann into a
# submodule, to keep the MPSKit module namespace cleaner.
"""
A module for functions related to treating an InfiniteMPS in left-canonical form as a bunch
of points on Grassmann manifolds, and performing things like retractions and transports
on these Grassmann manifolds.

The module exports nothing, and all references to it should be qualified, e.g.
`GrassmannInfiniteMPS.fg`.
"""
module GrassmannInfiniteMPS

using ..MPSKit
using TensorKit
import TensorKitManifolds.Grassmann

"""
Compute the expectation value, and its gradient with respect to the tensors in the unit
cell as tangent vectors on Grassmann manifolds.
"""
function fg(x)
    (state, pars) = x
    # The partial derivative with respect to AL, al_d, is the partial derivative with
    # respect to AC times CR'.
    ac_d = [ac_prime(state.AC[v], v, state, pars) for v in 1:length(state)]
    al_d = [d*c' for (d, c) in zip(ac_d, state.CR)]
    g = [Grassmann.project(d, a) for (d, a) in zip(al_d, state.AL)]
    f = real(sum(expectation_value(state, pars.opp, pars)))
    return f, g
end

"""
Retract a left-canonical infinite MPS along Grassmann tangent `g` by distance `alpha`.
"""
function retract(x, g, alpha)
    (state, pars) = x
    yal = similar(state.AL)  # The end-point
    h = similar(g)  # The tangent at the end-point
    for i in 1:length(g)
        (yal[i], h[i]) = Grassmann.retract(state.AL[i], g[i], alpha)
    end
    y = (InfiniteMPS(yal, leftgauged=true), pars)
    return y, h
end

"""
Transport a tangent vector `h` along the retraction from `x` in direction `g` by distance
`alpha`. `xp` is the end-point of the retraction.
"""
function transport!(h, x, g, alpha, xp)
    (state, pars) = x
    for i in 1:length(state)
        h[i] = Grassmann.transport!(h[i], state.AL[i], g[i], alpha, xp[1].AL[i])
    end
    return h
end

"""
Euclidean inner product between two Grassmann tangents of an infinite MPS.
"""
function inner(x, g1, g2)
    (state, pars) = x
    tot = sum(Grassmann.inner(a, d1, d2) for (a, d1, d2) in zip(state.AL, g1, g2))
    return 2*real(tot)
end

"""
Scale a tangent vector by scalar `alpha`.
"""
scale!(g, alpha) = g .* alpha

"""
Add two tangents vectors, scaling the latter by `alpha`.
"""
add!(g1, g2, alpha) = g1 + g2 .* alpha

"""
Take the L2 Tikhonov regularised inverse of a matrix `m`.

The regularisation parameter is the larger of `delta` (the optional argument that defaults
to zero) and square root of machine epsilon. The inverse is done using an SVD.
"""
function reginv(m, delta=zero(eltype(m)))
    delta = max(delta, sqrt(eps(real(float(one(eltype(m)))))))
    U, S, Vdg = tsvd(m)
    Sinv = inv(real(sqrt(S^2 + delta^2*one(S))))
    minv = Vdg' * Sinv * U'
    return minv
end

"""
Precondition a given Grassmann tangent `g` at state `x` by the Hilbert space inner product.

This requires inverting the right MPS transfer matrix. This is done using `reginv`, with a
regularisation parameter that is the norm of the tangent `g`.
"""
function precondition(x, g)
    (state, pars) = x
    delta = min(real(one(eltype(state))), sqrt(inner(x, g, g)))
    crinvs = [reginv(cr, delta) for cr in state.CR]
    g_prec = [Grassmann.project(d[]*(crinv'*crinv), a)
              for (d, crinv, a) in zip(g, crinvs, state.AL)]
    return g_prec
end

end  # module GrassmannInfiniteMPS
