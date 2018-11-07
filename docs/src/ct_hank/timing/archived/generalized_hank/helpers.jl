## The file containing all helper functions for constructing
# The primitives for the value function iteration

# Discretize the asset process into a grid of I gridpoints
# Where agridparam is the "bending" coefficient of the grid
# i.e. agridparam = 1 implies a uniform grid
# And amin/amax are the start and endpoints of the grid
function construct_asset_grid(I::Int64, agridparam::Int64, amin::Float64,
                              amax::Float64)
    a  = collect(linspace(0, 1, I))
    a  = a.^(1/agridparam)
    a  = amin + (amax - amin) * a
    return a
end

# P is the Markov transition matrix
# n_income_states is the number of income states (the number of discrete states in the distribution)
# iter_num is the number of iterations willing to be accepted for convergence
function compute_stationary_income_distribution(P::Matrix{Float64}, n_income_states::Int64;
                                                iter_num::Int64 = 50)
    Pt = P'
    g_z = fill(1/n_income_states, n_income_states)
    for n = 1:iter_num
        g_z_new = (speye(n_income_states) - Pt * 1000)\g_z
        diff = maximum(abs.(g_z_new - g_z))
        if diff < 1e-5
            break
        end
        g_z = g_z_new
    end
    return g_z
end

# initial_ygrid is the unscaled income values for each income state
# income_distr is the stationary income distribution
# meanlabeff is the mean labor efficiency value that scales z such that
# The expected value of income with respect to income_distr is meanlabeff
# n_gridpoints should be the same as the number of grid points in the asset process
function construct_labor_income_grid(initial_ygrid::Vector{Float64},
                                     income_distr::Vector{Float64},
                                     meanlabeff::Float64, n_gridpoints::Int64)
    z = exp.(initial_ygrid)
    z_bar = sum(z .* income_distr)
    z  	    = meanlabeff .* z./z_bar
    z       = z'
    zz      = ones(n_gridpoints, 1) * z
    return zz
end

function construct_household_problem_functions{T<:Real,S<:Number}(V::Matrix{S}, w::T,
                                                                  params::Dict{Symbol, Float64})
    coefrra = params[:coefrra]
    frisch  = params[:frisch]
    labtax  = params[:labtax]
    labdisutil = params[:labdisutil]

    @inline function util{U<:Number}(c::U, h::U)
        f(x::U) = coefrra == 1.0 ? log(x) : x^(1-coefrra) / (1-coefrra)
        return f(c) - labdisutil * (h ^ (1 + 1/frisch)/(1 + 1/frisch))
    end
    @inline income{T<:Number,U<:Number,V<:Number}(h::U, z::Float64, profshare::V, lumptransfer::V, r::T,
                   a::Float64) = h * z * w * (1 - labtax) + lumptransfer + profshare + r * a
    @inline labor{U<:Number,V<:Number}(z::U, val::V) = (z * w * (1 - labtax) * val / labdisutil) ^ frisch

    return util, income, labor
end

# Provide the income and asset grids
function initialize_diff_grids(zz::Matrix{Float64}, a::Vector{Float64})
    I = length(a)
    J = size(zz, 2)

    aa = similar(zz) # like zz, a matrix w/ the state space a repeated in each column
    dazf = similar(zz) # like zz, a matrix w/ the forward differences repeated in each colum
    dazb = similar(zz) # like above
    azdelta = similar(zz)

    daf = similar(a) # forward difference for a
    dab = similar(a) # backward difference for a
    adelta = similar(a) # size of differences

    aa = repeat(a, 1, J)

    daf[1:end-1]    = a[2:end] - a[1:end-1]
    daf[end]        = a[end] - a[end-1]
    dab[1]          = a[2] - a[1]
    dab[2:end]      = a[2:end] - a[1:end-1]

    dazf = repeat(daf, 1, J)
    dazb = repeat(dab, 1, J)

    # Create a grid of lengths of overlapping intervals in a dimension.
    # The purpose is generally to compute Riemann integrals
    # by taking midpoint Riemann sums and dividing by two to adjust for
    # or average out the added Lebesgue measure given by using overlapping intervals.
    # Example: adelta[2] = (a_3 - a_1)/2; if we integrate f, then
    # f[2]*adelta[2] = f_2(a_3 - a_1)/2
    adelta[1] = 0.5 * daf[1]
    adelta[2:end-1] = 0.5 * (daf[1:end-2] + daf[2:end-1])
    adelta[end] = 0.5 * daf[end-1]

    # azdelta is like aa/zz/dazf: repeats adelta across J columns
    azdelta = repeat(adelta, 1, J)

    # Convert into a sparse matrix
    azdelta_mat = spdiagm(vec(azdelta), 0)

    return dazf, dazb, azdelta, aa, adelta, azdelta, azdelta_mat
end

function construct_initial_diff_matrices{S<:Number,T<:Number,U<:Number}(V::Matrix{T},
                                         Vaf::Matrix{T},
                                         Vab::Matrix{T},
                                         income::Function,
                                         labor::Function,
                                         h::Matrix{U},
                                         h0::Matrix{U},
                                         zz::Matrix{Float64},
                                         profshare::Matrix{T},
                                         lumptransfer::T,
                                         amax::Float64, amin::Float64,
                                         coefrra::Float64, r::S,
                                         dazf::Matrix{Float64},
                                         dazb::Matrix{Float64},
                                         maxhours::Float64)

    # forward & backward differences
    Vaf[1:end-1, :] = (V[2:end,:] - V[1:end-1,:]) ./ dazf[1:end-1, :]
    Vab[2:end, :] = (V[2:end, :]-V[1:end-1, :]) ./ dazb[2:end, :]

    for i in 1:length(h[end, :])
        Vaf[end, i] = income(h[end, i], zz[end, i], profshare[end, i], lumptransfer, r, amax) ^ (-coefrra)
        Vab[1, i]   = income(h0[1, i], zz[1, i], profshare[1, i], lumptransfer, r, amin) ^ (-coefrra)
    end

    # consumption and savings with forward & backward difference
    cf = Vaf .^ (-1/coefrra)
    cb = Vab .^ (-1/coefrra)

    hf = similar(Vaf)
    hb = similar(Vab)
    for i in eachindex(zz)
        hf[i] = labor(zz[i], Vaf[i])
        hf[i] = min(hf[i], maxhours)

        hb[i] = labor(zz[i], Vab[i])
        hb[i] = min(hb[i], maxhours)
    end

    return Vaf, Vab, cf, hf, cb, hb
end

# For initialization
function calculate_SS_equil_vars(zz::Matrix{Float64}, m_SS::Float64, meanlabeff::Float64,
                                 lumptransferpc::Float64, govbondtarget::Float64)

    N_SS = complex(1/3) # steady state hours: so that quarterly GDP = 1 in s.s
    Y_SS = complex(1.)
    B_SS = govbondtarget * Y_SS
    profit_SS = complex((1 - m_SS) * Y_SS)
    profshare = zz/meanlabeff * profit_SS
    lumptransfer = complex(lumptransferpc * Y_SS)

    return N_SS, Y_SS, B_SS, profit_SS, profshare, lumptransfer
end

function calculate_SS_equil_vars(zz::Matrix{Float64},
                                 h::Matrix{Complex128},
                                 g::Matrix{Complex128}, azdelta::Matrix{Float64},
                                 aa::Matrix{Float64}, m_SS::Float64,
                                 meanlabeff::Float64, lumptransferpc::Float64,
                                 govbondtarget::Float64)

    # equilibrium objects
    N_SS = sum(vec(zz) .* vec(h) .* vec(g) .* vec(azdelta))
    Y_SS = N_SS
    B_SS = sum(vec(g) .* vec(aa) .* vec(azdelta))
    profit_SS = (1 - m_SS) * Y_SS
    profshare = zz/meanlabeff * profit_SS
    lumptransfer = lumptransferpc * Y_SS
    bond_err = B_SS/Y_SS - govbondtarget

    return N_SS, Y_SS, B_SS, profit_SS, profshare, lumptransfer, bond_err
end

function calculate_eqcond_equil_objects{T<:Real,S<:Real}(vars_SS::OrderedDict{Symbol, Any},
                                                         params::Dict{Symbol, T},
                                                         zz::Matrix{T}, w::S,
                                                         TFP::T, MP::S)
    output = vars_SS[:Y_SS]
    assets = vars_SS[:B_SS]
    hours  = vars_SS[:N_SS]
    inflation = vars_SS[:inflation_SS]
    r_SS = vars_SS[:r_SS]
    Y_SS = vars_SS[:Y_SS]
    G_SS = vars_SS[:G_SS]

    meanlabeff = params[:meanlabeff]
    taylor_inflation = params[:taylor_inflation]
    taylor_outputgap = params[:taylor_outputgap]
    labtax = params[:labtax]
    govbcrule_fixnomB = params[:govbcrule_fixnomB]

     m = w/TFP
     profit = (1 - m) .* output
    profshare = zz./meanlabeff .* profit
     r_Nominal = r_SS + taylor_inflation * inflation + taylor_outputgap * (log(output) - log(Y_SS)) + MP
    r = r_Nominal - inflation
    lumptransfer = labtax * w * hours - G_SS - (r_Nominal - (1-govbcrule_fixnomB) * inflation) * assets

    return profshare, r, lumptransfer
end

function hours_iteration{S<:Number,T<:Number,U<:Number}(income::Function, labor::Function,
                         zz::Matrix{Float64},
                         profshare::Matrix{T},
                         lumptransfer::T,
                         aa::Matrix{Float64},
                         coefrra::Float64, r::S,
                         cf::Matrix{T},
                         hf::Matrix{T},
                         cb::Matrix{T},
                         hb::Matrix{T},
                         c0::Matrix{T},
                         h0::Matrix{U},
                         maxhours::Float64,
                         niter_hours::Int64)

    for ih = 1:niter_hours
        for i in 1:length(cf[end, :])
            cf[end, i] = income(hf[end, i], zz[end, i], profshare[end, i], lumptransfer, r, aa[end, i])
            hf[end, i] = labor(zz[end, i], cf[end, i]^(-coefrra))
            hf[end, i] = min(hf[end, i], maxhours)

            cb[1, i] = income(hb[1, i], zz[1, i], profshare[1, i], lumptransfer, r, aa[1, i])
            hb[1, i] = labor(zz[1, i], cb[1, i]^(-coefrra))
            hb[1, i] = min(hb[1, i], maxhours)
        end

        c0 = income.(h0, zz, profshare, lumptransfer, r, aa)
        h0 = labor.(zz, c0.^(-coefrra))
        h0 = min.(h0, maxhours)

    end

    return cf, hf, cb, hb, c0, h0
end

# for compute_steady_state
# choose upwinding direction
function upwind{T<:Number}(rrho::Float64, V::Matrix{T}, args...; Delta_HJB::Float64 = 1e6)

    V, A, u, h, c, s = upwind(V, args...)

    I, J = size(u)

    B = (1/Delta_HJB + rrho) * speye(T, I*J) - A

    u_stacked = vec(u)
    V_stacked = vec(V)

    b = u_stacked + V_stacked/Delta_HJB

    V_stacked = B\b

    V = reshape(V_stacked, I, J)

    return V, A, u, h, c, s
end

# for equilibrium_conditions
# choose upwinding direction
function upwind{T<:Number, S<:Number}(V::Matrix{T}, util::Function,
                Aswitch::SparseMatrixCSC{S, Int64},
                cf::Matrix{T}, cb::Matrix{T},
                c0::Matrix{T}, hf::Matrix{T},
                hb::Matrix{T}, h0::Matrix{T},
                sf::Matrix{T}, sb::Matrix{T},
                Vaf::Matrix{T}, Vab::Matrix{T},
                Va0::Matrix{T}, dazf::Matrix{Float64},
                dazb::Matrix{Float64})

    I, J = size(dazf)

    Vf = similar(cf)
    Vb = similar(cb)
    V0 = similar(c0)

    for i in eachindex(cf)
        Vf[i] = util(cf[i], hf[i])
        Vb[i] = util(cb[i], hb[i])
        V0[i] = util(c0[i], h0[i])
    end

    Vf = (cf .> 0) .* (Vf + sf .* Vaf) + (cf .<= 0) * (-1e12)
    Vb = (cb .> 0) .* (Vb + sb .* Vab) + (cb .<= 0) * (-1e12)
    V0 = (c0 .> 0) .* V0 + (c0 .<= 0) * (-1e12)

    Ineither = (1 - (sf .> 0)) .* (1 - (sb .< 0))
    Iunique = (sb .< 0) .* (1 - (sf .> 0)) + (1 - (sb .< 0)) .* (sf .> 0)
    Iboth = (sb .< 0) .* (sf .> 0)

    Ib = Iunique .* (sb .< 0) .* (Vb .> V0) + Iboth .* (Vb .== max.(max.(Vb, Vf), V0))
    If = Iunique .* (sf .> 0) .* (Vf .> V0) + Iboth .* (Vf .== max.(max.(Vb, Vf), V0))
    I0 = Ineither + (1 - Ineither) .* (V0 .== max.(max.(Vb, Vf), V0))

    I0 = 1 - Ib - If

    Va = Vaf .* If + Vab .* Ib + Va0 .* I0
    h = hf .* If + hb .* Ib + h0 .* I0
    c = cf .* If + cb .* Ib + c0 .* I0
    s = sf .* If + sb .* Ib

    u = similar(c)
    for i in eachindex(c)
        u[i] = util(c[i], h[i])
    end

    # CONSTRUCT MATRIX A
    X = -Ib .* sb./dazb
    Y = -If .* sf./dazf + Ib .* sb./dazb
    Z = If .* sf./dazf

    updiag   = Vector{T}(2*I-1)
    lowdiag  = Vector{T}(2*I-1)

    updiag[1:I-1] = Z[1:I-1, 1]
    updiag[I] = T == Complex128 ? complex(0.) : 0.
    updiag[I+1:end] = Z[1:I-1, 2]
    centdiag = vec(Y)
    lowdiag[1:I-1] = X[2:I, 1]
    lowdiag[I] = T == Complex128 ? complex(0.) : 0.
    lowdiag[I+1:end] = X[2:I, 2]

    AA = spdiagm((lowdiag, centdiag, updiag), (-1, 0, 1))

    A = AA + Aswitch

    return V, A, u, h, c, s
end

# solve KFE: functions for well-conditioned A matrix and ill-conditioned A matrix

# Exact method for well-conditioned A
function solve_KFE(A::SparseMatrixCSC{Complex128, Int64}, da::Float64, dz::Float64,
                   I::Int64, J::Int64)
    AT = A'

    # Fixing one value to ensure matrix is not singular
    i_fix = 1
    b = zeros(I*J, 1)
    b[i_fix] = .1
    for j = 1:I*J
        AT[i_fix,j] = 0
    end
    AT[i_fix, i_fix] = 1

    # Solve linear system for distribution
    gg = AT \ b
    g_sum = gg'*ones(I*J, 1) * da * dz
    gg = gg ./ g_sum
    return reshape(gg, I, J)
end

# Exact method for well-conditioned A
function solve_KFE(A::SparseMatrixCSC{Complex128, Int64}, grids::Dict{Symbol, Any})

    AT = A'

    # Fixing one value to ensure matrix is not singular
    i_fix = 1
    b = zeros(grids[:I]*grids[:J], 1)
    b[i_fix] = .1
    for j = 1:grids[:I]*grids[:J]
        AT[i_fix,j] = 0
    end
    AT[i_fix, i_fix] = 1

    # Solve linear system for distribution
    gg = AT \ b
    g_sum = gg'*ones(grids[:I]*grids[:J], 1)*grids[:da]*grids[:dz]
    gg = gg ./ g_sum
    return reshape(gg, grids[:I], grids[:J])
end

# Iterative method for ill-conditioned A
function solve_KFE(A::SparseMatrixCSC{Complex128, Int64},
                   a::Vector{Float64}, g_z::Vector{Float64},
                   azdelta::Matrix{Float64}, azdelta_mat::SparseMatrixCSC{Float64, Int64};
                   maxit_KFE::Int64 = 1000, tol_KFE::Float64 = 1e-12,
                   Delta_KFE::Float64 = 1e6)
    I = length(a)
    J = length(g_z)
    @assert false
    # initialize KFE iterations at a = 0
    g0 = zeros(Complex128, I, J)
    g0[iszero.(a), :] = g_z # assign stationary income distribution weight at a = 0, zero elsewhere

    # g_z is a marginal distribution (wealth has been integrated out) so need to reweight distribution
    g0 = g0./azdelta
    gg = vec(g0) # stack distribution matrix into vector

    # Solve linear system
    for ikfe = 1:maxit_KFE
        gg_tilde = azdelta_mat * gg # integrate distribution over wealth -> marginal distribution over z

        # 0 = A'g -> g = A'g + g -> (I - A')g = g, but possible singularity so, given scalar Delta_KFE,
        # 0 = A' Delta_KFE g -> (I - Delta_KFE A') g = g
        gg1_tilde = (speye(Complex128, I*J) - Delta_KFE * A') \ gg_tilde
        gg1_tilde = gg1_tilde ./ sum(gg1_tilde) # normalize
        gg1 = azdelta_mat\gg1_tilde # undo integration over wealth

        # Check iteration for convergence
        err_KFE = maximum(abs.(gg1 - gg))
        if err_KFE < tol_KFE
            break
        end

        gg = gg1
    end

    g = reshape(gg, I, J)
    return g
end

# Exact method for well-conditioned A
function solve_KFE(A::SparseMatrixCSC{Float64, Int64}, da::Float64, dz::Float64,
                   I::Int64, J::Int64)
    AT = A'

    # Fixing one value to ensure matrix is not singular
    i_fix = 1
    b = zeros(I*J, 1)
    b[i_fix] = .1
    for j = 1:I*J
        AT[i_fix,j] = 0
    end
    AT[i_fix, i_fix] = 1

    # Solve linear system for distribution
    gg = AT \ b
    g_sum = gg'*ones(I*J, 1)*da*dz
    gg = gg ./ g_sum
    return reshape(gg, I, J)
end

# Exact method for well-conditioned A
function solve_KFE(A::SparseMatrixCSC{Float64, Int64}, grids::Dict{Symbol, Any})

    AT = A'

    # Fixing one value to ensure matrix is not singular
    i_fix = 1
    b = zeros(grids[:I]*grids[:J], 1)
    b[i_fix] = .1
    for j = 1:grids[:I]*grids[:J]
        AT[i_fix,j] = 0
    end
    AT[i_fix, i_fix] = 1

    # Solve linear system for distribution
    gg = AT \ b
    g_sum = gg'*ones(grids[:I]*grids[:J], 1)*grids[:da]*grids[:dz]
    gg = gg ./ g_sum
    return reshape(gg, grids[:I], grids[:J])
end

# Iterative method for ill-conditioned A
function solve_KFE(A::SparseMatrixCSC{Float64, Int64},
                   a::Vector{Float64}, g_z::Vector{Float64},
                   azdelta::Matrix{Float64}, azdelta_mat::SparseMatrixCSC{Float64, Int64};
                   maxit_KFE::Int64 = 1000, tol_KFE::Float64 = 1e-12,
                   Delta_KFE::Float64 = 1e6)
    @assert false
    I = length(a)
    J = length(g_z)

    # initialize KFE iterations at a = 0
    g0 = zeros(Complex128, I, J)
    g0[iszero.(a), :] = g_z
    g0 = g0./azdelta

    gg = vec(g0)

    # Solve linear system
    for ikfe = 1:maxit_KFE
        gg_tilde = azdelta_mat * gg
        gg1_tilde = (speye(Complex128, I*J) - Delta_KFE * A') \ gg_tilde
        gg1_tilde = gg1_tilde ./ sum(gg1_tilde) # normalize
        gg1 = azdelta_mat\gg1_tilde

        err_KFE = maximum(abs.(gg1 - gg))
        if err_KFE < tol_KFE
            break
        end
        gg = gg1
    end

    g = reshape(gg, I, J)
    return g
end

# Using the market clearing condition on bonds to determine whether or not
# an equilibrium has been reached
function check_bond_market_clearing(bond_err::Complex128, crit_S::Float64,
                                    r::Float64, rmin::Float64, rmax::Float64,
                                    rrho::Float64, rhomin::Float64, rhomax::Float64,
                                    IterateR::Bool, IterateRho::Bool)
    clearing_condition = false
    # Using the market clearing condition on bonds to determine whether or not
    # an equilibrium has been reached

    if abs(bond_err) > crit_S
        if bond_err > 0
            if IterateR
                rmax = r
                r = 0.5*(r + rmin)
            elseif IterateRho
                rhomin = rrho
                rrho = 0.5*(rrho + rhomax)
            end
        else
            if IterateR
                rmin = r
                r = 0.5*(r + rmax)
            elseif IterateRho
                rhomax = rrho
                rrho = 0.5*(rrho + rhomin)
            end
        end
    else
        clearing_condition = true
    end
    return r, rmin, rmax, rrho, rhomin, rhomax, clearing_condition
end

function check_bond_market_clearing(bond_err::Complex128, crit_S::Float64,
                                    r::Float64, rmin::Float64, rmax::Float64,
                                    rrho::Float64, rhomin::Float64, rhomax::Float64,
                                    IterateR::Bool, IterateRho::Bool)

    clearing_condition = false
    # Using the market clearing condition on bonds to determine whether or not
    # an equilibrium has been reached
    if abs(bond_err) > crit_S
        if bond_err > 0
            if IterateR
                rmax = r
                r = 0.5*(r + rmin)
            elseif IterateRho
                rhomin = rrho
                rrho = 0.5*(rrho + rhomax)
            end
        else
            if IterateR
                rmin = r
                r = 0.5*(r + rmax)
            elseif IterateRho
                rhomax = rrho
                rrho = 0.5*(rrho + rhomin)
            end
        end
    else
        clearing_condition = true
    end
    return r, rmin, rmax, rrho, rhomin, rhomax, clearing_condition
end

function calculate_residuals{S<:Number,T<:Number}(vars_SS::OrderedDict{Symbol, Any},
                                                  params::Dict{Symbol, Float64},
                                                  u::Matrix{T}, A::SparseMatrixCSC{T, Int64},
                                                  V::Matrix{T}, VDot::Vector{T},
                                                  VEErrors::Vector{T}, w::T, TFP::Float64,
                                                  inflationDot::T, inflationEError::T,
                                                  azdelta_mat::SparseMatrixCSC{S, Int64},
                                                  g::Vector{T}, MP::T, MPDot::T,
                                                  MPShock::T, aa::Matrix{S}, zz::Matrix{S},
                                                  azdelta::Matrix{Float64}, r::T, gDot::Vector{T},
                                                  s::Matrix{T}, h::Matrix{T}, c::Matrix{T})
    rrho = vars_SS[:rrho]
    consumption = vars_SS[:C_SS]
    hours = vars_SS[:N_SS]
    output = vars_SS[:Y_SS]
    inflation = vars_SS[:inflation_SS]
    assets = vars_SS[:B_SS]

    ceselast = params[:ceselast]
    priceadjust = params[:priceadjust]
    ttheta_MP = params[:ttheta_MP]
    ssigma_MP = params[:ssigma_MP]
    govbcrule_fixnomB = params[:govbcrule_fixnomB]

    # HJB equation
    hjbResidual = vec(u) + A * vec(V) + VDot + VEErrors - rrho * vec(V)

    # Inflation
    pcResidual = -((r - 0) * inflation - (ceselast/priceadjust * (w/TFP - (ceselast-1)/ceselast) + inflationDot - inflationEError))

    # KFE
    gIntermediate = spdiagm(1./diag(azdelta_mat), 0) * A' * (azdelta_mat * g)
    gResidual = gDot - gIntermediate[1:end-1]

    # Monetary Policy
    MPResidual = MPDot - (-ttheta_MP * MP + ssigma_MP * MPShock)

    # Market Clearing
    realsav = sum(vec(aa) .* vec(g) .* vec(azdelta))
    realsavDot = sum(vec(s) .* vec(g) .* vec(azdelta))
    bondmarketResidual = realsavDot/realsav + govbcrule_fixnomB * inflation
    labmarketResidual = sum(vec(zz) .* vec(h) .* vec(g) .* vec(azdelta)) - hours
    consumptionResidual = sum(vec(c) .* vec(g) .* vec(azdelta)) - consumption
    outputResidual = TFP * hours - output
    assetsResidual = assets - realsav

    v_residual = OrderedDict{Symbol, Any}()
    v_residual[:hjbResidual] = hjbResidual
    v_residual[:pcResidual] = pcResidual
    v_residual[:gResidual] = gResidual
    v_residual[:MPResidual] = MPResidual
    v_residual[:bondmarketResidual] = bondmarketResidual
    v_residual[:labmarketResidual] = labmarketResidual
    v_residual[:consumptionResidual] = consumptionResidual
    v_residual[:outputResidual] = outputResidual
    v_residual[:assetsResidual] = assetsResidual

    return v_residual
end

# For grabbing matrices of duals
function getDuals(object)
    out = zeros(size(object))
    for i = 1:prod(size(object))
        out[i] = object[i].value
    end
    return out
end

# Cleans Γ0 matrix to be identity if it is not the identity after
# performing automatic differentiation
function clean_Γ0(Γ0::Matrix{Float64}, Γ1::Matrix{Float64}, C::Matrix{Float64},
                  Π::Matrix{Float64}, Ψ::Matrix{Float64})
    redundant = maximum(abs.([Γ0, Ψ]), 2) .== 0
    inv_state_red = null(Γ1(redundant,:))
    state_red = inv_state_red'

    g0 = state_red * Γ0 * inv_state_red
    g1 = state_red * Γ1 * inv_state_red
    g1 = g0 \ g1
    Psi = g0 \ (state_red * Ψ)
    Pi = g0 \ (state_red * Π)
    c = g0 \ (state_red * C)

    return g0, g1, c, Pi, Psi, state_red, inv_state_red
end
function clean_Γ0(Γ0::SparseMatrixCSC{Float64, Int64}, Γ1::SparseMatrixCSC{Float64, Int64},
                  C::SparseMatrixCSC{Float64, Int64},
                  Π::SparseMatrixCSC{Float64, Int64}, Ψ::SparseMatrixCSC{Float64, Int64})
    redundant = maximum(abs.([Γ0, Ψ]), 2) .== 0
    inv_state_red = sparse(null(Γ1(redundant,:)))

    g0 = inv_state_red' * Γ0 * inv_state_red
    g1 = inv_state_red' * Γ1 * inv_state_red
    g1 = g0 \ g1
    Psi = g0 \ (inv_state_red' * Ψ)
    Pi = g0 \ (inv_state_red' * Π)
    c = g0 \ (inv_state_red' * C)

    return g0, g1, c, Pi, Psi, state_red, inv_state_red
end
