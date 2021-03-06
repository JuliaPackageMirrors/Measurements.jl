### math.jl
#
# Copyright (C) 2016 Mosè Giordano.
#
# Maintainer: Mosè Giordano <mose AT gnu DOT org>
# Keywords: uncertainty, error propagation, physics
#
# This file is a part of Measurements.jl.
#
# License is MIT "Expat".
#
### Commentary:
#
# This file contains definition of mathematical functions that support
# Measurement objects.
#
# Note: some functions defined here (like all degree-related and reciprocal
# trigonometric functions, fld, cld, hypot, cbrt, abs, mod) are redundant in the
# sense that you would get the correct result also without their definitions,
# but having them defined here avoids some calculations and slightly improves
# performance.  Likewise, multiple methods are provided for functions taking two
# (or more) arguments because when only one argument is of Measurement type we
# can use the simple `result' function for one derivative that is faster than
# the generic method.
#
### Code:

export @uncertain

# This function is to be used by methods of mathematical operations to produce a
# `Measurement' object in output.  Arguments are:
#   * val: the nominal result of operation G(a)
#   * der: the derivative ∂G/∂a of G with respect to the variable a
#   * a: the only argument of G
# In this simple case of unary function, we don't have the problem of correlated
# variables (thus making this method much faster than the next one), so we can
# calculate the uncertainty of G(a) as
#   σ_G = |σ_a·∂G/∂a|
# The list of derivatives with respect to each measurement is updated with
#   ∂G/∂a · previous_derivatives
function result{T<:AbstractFloat}(val::Real, der::Real, a::Measurement{T})
    val, der = promote(val, der)
    newder = similar(a.der)
    @inbounds for tag in keys(a.der)
        if tag[2] != 0.0 # Skip values with 0 uncertainty
            newder = Derivatives(newder, tag=>der*a.der[tag])
        end
    end
    # If uncertainty of "a" is null, the uncertainty of result is null as well,
    # even if the derivative is NaN or infinite.  In any other case, use
    # σ_G = |σ_a·∂G/∂a|.
    σ = (a.err == 0.0) ? 0.0 : abs(der*a.err)
    # The tag is NaN because we don't care about tags of derived quantities, we
    # are only interested in independent ones.
    Measurement(val,  σ, NaN, newder)
end

# This function is similar to the previous one, but applies to mathematical
# operations with more than one argument, so the formula to propagate
# uncertainty is more complicated because we have to take into account
# correlation between arguments.  The arguments are the same as above, but `der'
# and `a' are tuples of the same length (`der' has the derivatives of G with
# respect to the corresponding variable in `a').
#
# Suppose we have a function G = G(a1, a2) of two arguments.  a1 and a2 are
# correlated, because they come from some mathematical operations on really
# independent variables x, y, z, say a1 = a1(x, y), a2 = a2(x, z).  The
# uncertainty on G(a1, a2) is calculated as follows:
#   σ_G = sqrt((σ_x·∂G/∂x)^2 + (σ_y·∂G/∂y)^2 + (σ_z·∂G/∂z)^2)
# where ∂G/∂x is the partial derivative of G with respect to x, and so on.  We
# can expand the previous formula to:
#   σ_G = sqrt((σ_x·(∂G/∂a1·∂a1/∂x + ∂G/∂a2·∂a2/∂x))^2 + (σ_y·∂G/∂a1·∂a1/∂y)^2 +
#               + (σ_z·∂G/∂a2·∂a2/∂z)^2)
function result(val::Real, der::Tuple{Vararg{Real}},
                a::Tuple{Vararg{Measurement}})
    @assert length(der) == length(a)
    a = promote(a...)
    T = typeof(a[1].val)
    newder = similar(a[1].der)
    err::T = zero(T)
    # Iterate over all independent variables.  We first iterate over all
    # variables listed in `a' in order to get all independent variables upon
    # which those variables depend, then we get the `tag' of each independent
    # variable, skipping variables that have been already taken into account.
    @inbounds for y in a
        for tag in keys(y.der)
            if tag ∉ keys(newder) # Skip independent variables already considered
                σ_x = tag[2]
                if σ_x != 0.0 # Skip values with 0 uncertainty
                    ∂G_∂x::T = 0.0
                    # Iteratate over all the arguments of the function
                    for (i, x) in enumerate(a)
                        # Calculate the derivative of G with respect to the
                        # current independent variable.  In the case of the x
                        # independent variable of the example above, we should
                        # get   ∂G/∂x = ∂G/∂a1·∂a1/∂x + ∂G/∂a2·∂a2/∂x
                        ∂a_∂x = derivative(x, tag) # ∂a_i/∂x
                        if ∂a_∂x != 0.0 # Skip values with 0 partial derivative
                            # der[i] = ∂G/∂a_i
                            ∂G_∂x = ∂G_∂x + der[i]*∂a_∂x
                        end
                    end
                    newder = Derivatives(newder, tag=>∂G_∂x)
                    # Add (σ_x·∂G/∂x)^2 to the total uncertainty (squared)
                    err = err + abs2(σ_x*∂G_∂x)
                end
            end
        end
    end
    return Measurement(T(val), sqrt(err), NaN, newder)
end

# "result" function for complex-valued functions (like "besselh").  This takes
# the same argument as the first implementation of "result", but with complex
# "val" and "der".
function result(val::Complex, der::Complex, a::Measurement)
    return complex(result(real(val), real(der), a), result(imag(val), imag(der), a))
end

### @uncertain macro.
"""
    @uncertain f(value ± stddev, ...)

A macro to calculate \$f(value) ± uncertainty\$, with \$uncertainty\$ derived
from \$stddev\$ according to rules of linear error propagation theory.

Function \$f\$ can accept any number of real arguments, the type of the
arguments provided must be `Measurement`.
"""
macro uncertain(expr::Expr)
    f = esc(expr.args[1]) # Function name
    n = length(expr.args) - 1
    if n == 1
        a = esc(expr.args[2]) # Argument, of Measurement type
        return :( result($f($a.val), Calculus.derivative($f, $a.val), $a) )
    else
        a = expr.args[2:end] # Arguments, as an array of expressions
        args = :([])  # Build up array of arguments
        [push!(args.args, :($(esc(a[i])))) for i=1:n] # Fill the array
        argsval =:([])  # Build up the array of values of arguments
        [push!(argsval.args, :($(args.args[i]).val)) for i=1:n] # Fill the array
        return :( result($f($argsval...),
                         (Calculus.gradient(x -> $f(x...), $argsval)...),
                         ($args...)) )
    end
end

### Elementary arithmetic operations:
import Base: +, -, *, /, div, inv, fld, cld

# Addition: +
+(a::Measurement) = a
+(a::Measurement, b::Measurement) = result(a.val + b.val, (1.0, 1.0), (a, b))
+(a::Real, b::Measurement) = result(a + b.val, 1.0, b)
+(a::Measurement, b::Bool) = result(a.val +b, 1.0, a)
+(a::Measurement, b::Real) = result(a.val + b, 1.0, a)

# Subtraction: -
-(a::Measurement) = result(-a.val, -1.0, a)
-(a::Measurement, b::Measurement) = result(a.val - b.val, (1.0, -1.0), (a, b))
-(a::Real, b::Measurement) = result(a - b.val, -1.0, b)
-(a::Measurement, b::Real) = result(a.val - b, 1.0, a)

# Multiplication: *
function *(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    return result(aval*bval, (bval, aval), (a, b))
end
*(a::Bool, b::Measurement) = result(a*b.val, a, b)
*(a::Real, b::Measurement) = result(a*b.val, a, b)
*(a::Measurement, b::Bool) = result(a.val*b, b, a)
*(a::Measurement, b::Real) = result(a.val*b, b, a)

# muladd and fma
import Base: muladd, fma

for f in (:fma, :muladd)
    @eval begin
        # All three arguments are Measurement
        function ($f)(a::Measurement, b::Measurement, c::Measurement)
            x = a.val
            y = b.val
            z = c.val
            return result(($f)(x, y, z), (y, x, one(z)), (a, b, c))
        end

        # First argument is always Measurement
        function ($f)(a::Measurement, b::Measurement, c::Real)
            x = a.val
            y = b.val
            return result(($f)(x, y, c), (y, x), (a, b))
        end

        function ($f)(a::Measurement, b::Real, c::Measurement)
            x = a.val
            z = c.val
            return result(($f)(x, b, z), (b, one(z)), (a, c))
        end

        ($f)(a::Measurement, b::Real, c::Real) =
            result(($f)(a.val, b, c), b, a)

        # Secon argument is always Measurement
        function ($f)(a::Real, b::Measurement, c::Measurement)
            y = b.val
            z = c.val
            return result(($f)(a, y, z), (a, one(z)), (b, c))
        end

        ($f)(a::Real, b::Measurement, c::Real) =
            result(($f)(a, b.val, c), a, b)

        # Third argument is Measurement
        function ($f)(a::Real, b::Real, c::Measurement)
            z = c.val
            return result(($f)(a, b, z), one(z), c)
        end
    end
end

# Division: /, div, fld, cld
function /(a::Measurement, b::Measurement)
    aval = a.val
    oneoverbval = inv(b.val)
    return result(aval*oneoverbval, (oneoverbval, -aval*abs2(oneoverbval)),
                  (a, b))
end
/(a::Real, b::Measurement) = result(a/b.val, -a/abs2(b.val), b)
/(a::Measurement, b::Real) = result(a.val/b, 1/b, a)

# 0.0 as partial derivative for both arguments of "div", "fld", "cld" should be
# correct for most cases.  This has been tested against "@uncertain" macro.
div(a::Measurement, b::Measurement) = result(div(a.val, b.val), (0.0, 0.0), (a, b))
div(a::Measurement, b::Real) = result(div(a.val, b), 0.0, a)
div(a::Real, b::Measurement) = result(div(a, b.val), 0.0, b)

fld(a::Measurement, b::Measurement) = result(fld(a.val, b.val), (0.0, 0.0), (a, b))
fld(a::Measurement, b::Real) = result(fld(a.val, b), 0.0, a)
fld(a::Real, b::Measurement) = result(fld(a, b.val), 0.0, b)

cld(a::Measurement, b::Measurement) = result(cld(a.val, b.val), (0.0, 0.0), (a, b))
cld(a::Measurement, b::Real) = result(cld(a.val, b), 0.0, a)
cld(a::Real, b::Measurement) = result(cld(a, b.val), 0.0, b)

# Inverse: inv
function inv(a::Measurement)
    inverse = inv(a.val)
    return result(inverse, -abs2(inverse), a)
end

# signbit
import Base: signbit

signbit(a::Measurement) = signbit(a.val)

# Power: ^
import Base: ^, exp2

function ^(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    pow = aval^bval
    return result(pow, (aval^(bval - 1.0)*bval, pow*log(aval)), (a, b))
end

function ^{T<:Integer}(a::Measurement, b::T)
    aval = a.val
    return result(aval^b, aval^(b-1)*b, a)
end

function ^{T<:Rational}(a::Measurement,  b::T)
    if isinteger(b)
        return a^trunc(Integer, b)
    else
        aval = a.val
        return result(aval^b, b*aval^(b - 1.0), a)
    end
end

function ^{T<:Real}(a::Measurement,  b::T)
    if isinteger(float(b))
        return a^trunc(Integer, b)
    else
        aval = a.val
        return result(aval^b, b*aval^(b - 1.0), a)
    end
end

^(::Irrational{:e}, b::Measurement) = exp(b)

function ^{T<:Real}(a::T,  b::Measurement)
    res = a^b.val
    return result(res, res*log(a), b)
end

function exp2{T<:AbstractFloat}(a::Measurement{T})
    pow = exp2(a.val)
    return result(pow, pow*log(T(2)), a)
end

### Trigonometric functions

# deg2rad, rad2deg
import Base: deg2rad, rad2deg

deg2rad(a::Measurement) = result(deg2rad(a.val), oftype(a.val, pi)/180, a)
rad2deg(a::Measurement) = result(rad2deg(a.val), 180/oftype(a.val, pi), a)

# Cosine: cos, cosd, cosh
import Base: cos, cosd, cosh

function cos(a::Measurement)
    aval = a.val
    result(cos(aval), -sin(aval), a)
end

function cosd(a::Measurement)
    aval = a.val
    return result(cosd(aval), -deg2rad(sind(aval)), a)
end

function cosh(a::Measurement)
    aval = a.val
    result(cosh(aval), sinh(aval), a)
end

# Sine: sin, sind, sinh
import Base: sin, sind, sinh

function sin(a::Measurement)
    aval = a.val
    result(sin(aval), cos(aval), a)
end

function sind(a::Measurement)
    aval = a.val
    return result(sind(aval), deg2rad(cosd(aval)), a)
end

function sinh(a::Measurement)
    aval = a.val
    result(sinh(aval), cosh(aval), a)
end

# Tangent: tan, tand, tanh
import Base: tan, tand, tanh

function tan(a::Measurement)
    aval = a.val
    return result(tan(aval), abs2(sec(aval)), a)
end

function tand(a::Measurement)
    aval = a.val
    return result(tand(aval), deg2rad(abs2(secd(aval))), a)
end

function tanh(a::Measurement)
    aval = a.val
    return result(tanh(aval), abs2(sech(aval)), a)
end

# Inverse trig functions: acos, acosd, acosh, asin, asind, asinh, atan, atand,
# atan2, atanh
import Base: acos, acosd, acosh, asin, asind, asinh, atan, atand, atan2, atanh

function acos(a::Measurement)
    aval = a.val
    return result(acos(aval), -inv(sqrt(1.0 - abs2(aval))), a)
end

function acosd(a::Measurement)
    aval = a.val
    return result(acosd(aval), -rad2deg(inv(sqrt(1.0 - abs2(aval)))), a)
end

function acosh(a::Measurement)
    aval = a.val
    return result(acosh(aval), inv(sqrt(abs2(aval) - 1.0)), a)
end

function asin(a::Measurement)
    aval = a.val
    return result(asin(aval), inv(sqrt(1.0 - abs2(aval))), a)
end

function asind(a::Measurement)
    aval = a.val
    return result(asind(aval), rad2deg(inv(sqrt(1.0 - abs2(aval)))), a)
end

function asinh(a::Measurement)
    aval = a.val
    return result(asinh(aval), inv(hypot(aval, 1.0)), a)
end

function atan(a::Measurement)
    aval = a.val
    return result(atan(aval), inv(abs2(aval) + 1.0), a)
end

function atand(a::Measurement)
    aval = a.val
    return result(atand(aval), rad2deg(inv(abs2(aval) + 1.0)), a)
end

function atanh(a::Measurement)
    aval = a.val
    return result(atanh(aval), inv(1.0 - abs2(aval)), a)
end

function atan2(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    invdenom = inv(abs2(aval) + abs2(bval))
    return result(atan2(aval, bval),
                  (bval*invdenom, -aval*invdenom),
                  (a, b))
end

function atan2(a::Measurement, b::Real)
    x = a.val
    return result(atan2(x, b), -b/(abs2(x) + abs2(b)), a)
end

function atan2(a::Real, b::Measurement)
    y = b.val
    return result(atan2(a, y), -a/(abs2(a) + abs2(y)), b)
end

# Reciprocal trig functions: csc, cscd, csch, sec, secd, sech, cot, cotd, coth
import Base: csc, cscd, csch, sec, secd, sech, cot, cotd, coth

function csc(a::Measurement)
    aval = a.val
    val = csc(aval)
    return result(val, -val*cot(aval), a)
end

function cscd(a::Measurement)
    aval = a.val
    val = cscd(aval)
    return result(val, -deg2rad(val*cotd(aval)), a)
end

function csch(a::Measurement)
    aval = a.val
    val = csch(aval)
    return result(val, -val*coth(aval), a)
end

function sec(a::Measurement)
    aval = a.val
    val = sec(aval)
    return result(val, val*tan(aval), a)
end

function secd(a::Measurement)
    aval = a.val
    val = secd(aval)
    return result(val, deg2rad(val*tand(aval)), a)
end

function sech(a::Measurement)
    aval = a.val
    val = sech(aval)
    return result(val, val*tanh(aval), a)
end

function cot(a::Measurement)
    aval = a.val
    return result(cot(aval), -abs2(csc(aval)), a)
end

function cotd(a::Measurement)
    aval = a.val
    return result(cotd(aval), -deg2rad(abs2(cscd(aval))), a)
end

function coth(a::Measurement)
    aval = a.val
    return result(coth(aval), -abs2(csch(aval)), a)
end

### Exponential-related

# Exponentials: exp, expm1, exp10, frexp, ldexp
import Base: exp, expm1, exp10, frexp, ldexp

function exp(a::Measurement)
    val = exp(a.val)
    return result(val, val, a)
end

function expm1(a::Measurement)
    aval = a.val
    return result(expm1(aval), exp(aval), a)
end

function exp10{T<:AbstractFloat}(a::Measurement{T})
    val = exp10(a.val)
    return result(val, log(T(10))*val, a)
end

function frexp(a::Measurement)
    x, y = frexp(a.val)
    return (result(x, inv(exp2(y)), a), y)
end

ldexp(a::Measurement, e::Integer) = result(ldexp(a.val, e), ldexp(1.0, e), a)

# Logarithms
import Base: log, log2, log10, log1p

function log(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    val = log(aval, bval)
    loga = log(aval)
    return result(val, (-val/(aval*loga), inv(loga*bval)), (a, b))
end

function log(a::Measurement) # Special case
    aval = a.val
    return result(log(aval), inv(aval), a)
end

function log2{T<:AbstractFloat}(a::Measurement{T}) # Special case
    x = a.val
    return result(log2(x), inv(log(T(2))*x), a)
end

function log10{T<:AbstractFloat}(a::Measurement{T}) # Special case
    aval = a.val
    return result(log10(aval), inv(log(T(10))*aval), a)
end

function log1p(a::Measurement) # Special case
    aval = a.val
    return result(log1p(aval), inv(aval + one(aval)), a)
end

log(::Irrational{:e}, a::Measurement) = log(a)

function log(a::Real, b::Measurement)
    bval = b.val
    return result(log(a, bval), inv(log(a)*bval), b)
end

function log(a::Measurement, b::Real)
    aval = a.val
    res = log(aval, b)
    return result(res, -res/(aval*log(aval)), a)
end

# Hypotenuse: hypot
import Base: hypot

function hypot(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    val = hypot(aval, bval)
    invval = inv(val)
    return result(val,
                  (aval*invval, bval*invval),
                  (a, b))
end

function hypot(a::Real, b::Measurement)
    bval = b.val
    res = hypot(a, bval)
    return result(res, bval*inv(res), b)
end

function hypot(a::Measurement, b::Real)
    aval = a.val
    res = hypot(aval, b)
    return result(res, aval*inv(res), a)
end

# Square root: sqrt
import Base: sqrt

function sqrt(a::Measurement)
    val = sqrt(a.val)
    return result(val, 0.5*inv(val), a)
end

# Cube root: cbrt
import Base: cbrt

function cbrt(a::Measurement)
    aval = a.val
    val = cbrt(aval)
    return result(val, val*inv(3.0*aval), a)
end

### Absolute value, sign and the likes

# Absolute value
import Base: abs, abs2

function abs(a::Measurement)
    aval = a.val
    return result(abs(aval), copysign(1, aval), a)
end

function abs2(a::Measurement)
    x = a.val
    return result(abs2(x), 2*x, a)
end

# Sign: sign, copysign, flipsign
import Base: sign, copysign, flipsign

sign(a::Measurement) = result(sign(a.val), 0.0, a)

function copysign(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    result(copysign(aval, bval),
           (copysign(1, aval)/copysign(1, bval), 0.0),
           (a, b))
end

copysign(a::Measurement, b::Real) = copysign(a, measurement(b))
copysign(a::Signed, b::Measurement) = copysign(measurement(a), b)
copysign(a::Rational, b::Measurement) = copysign(measurement(a), b)
copysign(a::Float32, b::Measurement) = copysign(measurement(a), b)
copysign(a::Float64, b::Measurement) = copysign(measurement(a), b)
copysign(a::Real, b::Measurement) = copysign(measurement(a), b)

function flipsign(a::Measurement, b::Measurement)
    flip = flipsign(a.val, b.val)
    return result(flip, (copysign(1.0, flip), 0.0), (a, b))
end

flipsign(a::Measurement, b::Real) = flipsign(a, measurement(b))
flipsign(a::Signed, b::Measurement) = flipsign(measurement(a), b)
flipsign(a::Float32, b::Measurement) = flipsign(measurement(a), b)
flipsign(a::Float64, b::Measurement) = flipsign(measurement(a), b)
flipsign(a::Real, b::Measurement) = flipsign(measurement(a), b)

### Special functions

# Error function: erf, erfinv, erfc, erfcinv, erfcx, erfi, dawson
import Base: erf, erfinv, erfc, erfcinv, erfcx, erfi, dawson

function erf{T<:AbstractFloat}(a::Measurement{T})
    aval = a.val
    return result(erf(aval), 2*exp(-abs2(aval))/sqrt(T(pi)), a)
end

function erfinv{T<:AbstractFloat}(a::Measurement{T})
    res = erfinv(a.val)
    # For the derivative, see http://mathworld.wolfram.com/InverseErf.html
    return result(res, 0.5*sqrt(T(pi))*exp(abs2(res)), a)
end

function erfc{T<:AbstractFloat}(a::Measurement{T})
    aval = a.val
    return result(erfc(aval), -2*exp(-abs2(aval))/sqrt(T(pi)), a)
end

function erfcinv{T<:AbstractFloat}(a::Measurement{T})
    res = erfcinv(a.val)
    # For the derivative, see http://mathworld.wolfram.com/InverseErfc.html
    return result(res, -0.5*sqrt(T(pi))*exp(abs2(res)), a)
end

function erfcx{T<:AbstractFloat}(a::Measurement{T})
    aval = a.val
    res = erfcx(aval)
    return result(res, 2*(aval*res - inv(sqrt(T(pi)))), a)
end

function erfi{T<:AbstractFloat}(a::Measurement{T})
    aval = a.val
    return result(erfi(aval), 2*exp(abs2(aval))/sqrt(T(pi)), a)
end

function dawson{T<:AbstractFloat}(a::Measurement{T})
    aval = a.val
    res = dawson(aval)
    return result(res, 1.0 - 2.0*aval*res, a)
end

# Factorial and gamma
import Base: factorial, gamma, lgamma, digamma, invdigamma, trigamma, polygamma

function factorial(a::Measurement)
    aval = a.val
    fact = factorial(aval)
    return result(fact, fact*digamma(aval + one(aval)), a)
end

function gamma(a::Measurement)
    aval = a.val
    Γ = gamma(aval)
    return result(Γ, Γ*digamma(aval), a)
end

function lgamma(a::Measurement)
    aval = a.val
    return result(lgamma(aval), digamma(aval), a)
end

function digamma(a::Measurement)
    aval = a.val
    return result(digamma(aval), trigamma(aval), a)
end

function invdigamma(a::Measurement)
    aval = a.val
    res = invdigamma(aval)
    return result(res, inv(trigamma(res)), a)
end

function trigamma(a::Measurement)
    aval = a.val
    return result(trigamma(aval), polygamma(2, aval), a)
end

function polygamma(n::Integer, a::Measurement)
    aval = a.val
    return result(polygamma(n, aval), polygamma(n + 1, aval), a)
end

# Beta function: beta, lbeta
import Base: beta, lbeta

function beta(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    res = beta(aval, bval)
    return result(res,
                  (res*(digamma(aval) - digamma(aval + bval)),
                   res*(digamma(bval) - digamma(aval + bval))),
                  (a, b))
end

function beta(a::Measurement, b::Real)
    aval = a.val
    res = beta(aval, b)
    return result(res, res*(digamma(aval) - digamma(aval + b)), a)
end

beta(a::Real, b::Measurement) = beta(b, a)

function lbeta(a::Measurement, b::Measurement)
    aval = a.val
    bval = b.val
    return result(lbeta(aval, bval),
                  (digamma(aval) - digamma(aval + bval),
                   digamma(bval) - digamma(aval + bval)),
                  (a, b))
end

function lbeta(a::Measurement, b::Real)
    aval = a.val
    return result(lbeta(aval, b), digamma(aval) - digamma(aval + b), a)
end

lbeta(a::Real, b::Measurement) = lbeta(b, a)

# Airy functions
import Base: airy

function airy(k::Integer, a::Measurement)
    aval = a.val
    if k == 0 || k == 2
        return result(airy(k, aval), airy(k + 1, aval), a)
    else
        # Use Airy equation: y'' - xy = 0 => y'' = xy
        return result(airy(k, aval), aval*airy(k - 1, aval), a)
    end
end

# Bessel functions
import Base: besselj0, besselj1, besselj, bessely0, bessely1, bessely, besselh,
besseli, besselix, besselk, besselkx

function besselj0(a::Measurement)
    x = a.val
    return result(besselj0(x), -besselj1(x), a)
end

function besselj1(a::Measurement)
    x = a.val
    return result(besselj1(x), 0.5*(besselj0(x) - besselj(2, x)), a)
end

# XXX: this is necessary to fix a method ambiguity in Julia 0.4.  Remove this
# definition when that version will not be supported anymore
function besselj(nu::Integer, a::Measurement)
    x = a.val
    return result(besselj(nu, x), 0.5*(besselj(nu - 1, x) - besselj(nu + 1, x)), a)
end

# XXX: this is necessary to fix a method ambiguity in Julia 0.4.  Remove this
# definition when that version will not be supported anymore
function besselj(nu::AbstractFloat, a::Measurement)
    x = a.val
    return result(besselj(nu, x), 0.5*(besselj(nu - 1, x) - besselj(nu + 1, x)), a)
end

# XXX: I don't know a closed form expression for the derivative with respect to
# first argument of J_n.  Arguably, there will be more cases where the
# measurement is the second argument, than the first one.  In any case, you can
# use "@uncertain" macro when both arguments are of Measurement type.
function besselj(nu::Real, a::Measurement)
    x = a.val
    return result(besselj(nu, x), 0.5*(besselj(nu - 1, x) - besselj(nu + 1, x)), a)
end

function bessely0(a::Measurement)
    x = a.val
    return result(bessely0(x), -bessely1(x), a)
end

function bessely1(a::Measurement)
    x = a.val
    return result(bessely1(x), 0.5*(bessely0(x) - bessely(2, x)), a)
end

# XXX: this is necessary to fix a method ambiguity in Julia 0.4.  Remove this
# definition when that version will not be supported anymore
function bessely(nu::Integer, a::Measurement)
    x = a.val
    return result(bessely(nu, x), 0.5*(bessely(nu - 1, x) - bessely(nu + 1, x)), a)
end

# XXX: I don't know a closed form expression for the derivative with respect to
# first argument of y_n, see comments about "besselj".
function bessely(nu::Real, a::Measurement)
    x = a.val
    return result(bessely(nu, x), 0.5*(bessely(nu - 1, x) - bessely(nu + 1, x)), a)
end

function besselh(nu::Real, k::Integer, a::Measurement)
    x = a.val
    return result(besselh(nu, k, x),
                  0.5*(besselh(nu - 1, k, x) - besselh(nu + 1, k, x)),
                  a)
end

function besseli(nu::Real, a::Measurement)
    x = a.val
    return result(besseli(nu, x), 0.5*(besseli(nu - 1, x) + besseli(nu + 1, x)), a)
end

function besselix(nu::Real, a::Measurement)
    x = a.val
    return result(besselix(nu, x),
                  0.5*(besseli(nu - 1, x) + besseli(nu + 1, x))*exp(-abs(x)) -
                  besseli(nu, x)*sign(x)*exp(-abs(x)),
                  a)
end

function besselk(nu::Real, a::Measurement)
    x = a.val
    return result(besselk(nu, x), -0.5*(besselk(nu - 1, x) + besselk(nu + 1, x)), a)
end

function besselkx(nu::Real, a::Measurement)
    x = a.val
    return result(besselkx(nu, x),
                  -0.5*(besselk(nu - 1, x) + besselk(nu + 1, x))*exp(x) +
                  besselk(nu, x)*exp(x),
                  a)
end

### Modulo

import Base: mod, rem, mod2pi

# Use definition of "mod" function:
# http://docs.julialang.org/en/stable/manual/mathematical-operations/#division-functions
mod(a::Measurement, b::Measurement) = a - fld(a, b)*b
mod(a::Measurement, b::Real) = mod(a, measurement(b))
mod(a::Real, b::Measurement) = mod(measurement(a), b)

# Use definition of "rem" function:
# http://docs.julialang.org/en/stable/manual/mathematical-operations/#division-functions
rem(a::Measurement, b::Measurement) = a - div(a, b)*b
rem(a::Measurement, b::Real) = rem(a, measurement(b))
rem(a::Real, b::Measurement) = rem(measurement(a), b)

mod2pi(a::Measurement) = result(mod2pi(a.val), 1, a)

### Machine precision

import Base: eps, nextfloat, maxintfloat, typemax

eps{T<:AbstractFloat}(::Type{Measurement{T}}) = eps(T)
eps{T<:AbstractFloat}(a::Measurement{T}) = eps(a.val)

nextfloat(a::Measurement) = nextfloat(a.val)

maxintfloat{T<:AbstractFloat}(::Type{Measurement{T}}) = maxintfloat(T)

typemax{T<:AbstractFloat}(::Type{Measurement{T}}) = typemax(T)

### Rounding
import Base: round, floor, ceil, trunc

round(a::Measurement) = round(a.val)
round{T<:Integer}(::Type{T}, a::Measurement) = round(T, a.val)
floor(a::Measurement) = floor(a.val)
floor{T<:Integer}(::Type{T}, a::Measurement) = floor(T, a.val)
ceil(a::Measurement) = ceil(a.val)
ceil{T<:Integer}(::Type{T}, a::Measurement) = ceil(Integer, a.val)
trunc(a::Measurement) = trunc(a.val)
trunc{T<:Integer}(::Type{T}, a::Measurement) = trunc(T, a.val)

# Widening
import Base: widen

widen{T<:AbstractFloat}(::Type{Measurement{T}}) = Measurement{widen(T)}

# To big float
import Base: big

big{T<:AbstractFloat}(x::Measurement{T}) = convert(Measurement{BigFloat}, x)

# Sum and prod
import Base: sum, prod

# This definition is not strictly needed, because `sum' works out-of-the-box
# with Measurement type, but this makes the function linear instead of quadratic
# in the number of arguments, but `result' is quadratic in the number of
# arguments, so in the end the function goes from cubic to quadratic.  Still not
# ideal, but this is an improvement.
sum{T<:Measurement}(a::AbstractArray{T}) =
    result(sum(value(a)), (ones(length(a))...), (a...))

# Same as above.  I'm not particularly proud of how the derivatives are
# computed, but something like this is needed in order to avoid errors with null
# nominal values: you may think to x ./ prod(x), but that would fail if one or
# more elements are zero.
function prod{T<:Measurement}(a::AbstractArray{T})
    x = value(a)
    return result(prod(x),
                  ntuple(i -> prod(deleteat!(copy(x), i)), length(x)),
                  (a...))
end
