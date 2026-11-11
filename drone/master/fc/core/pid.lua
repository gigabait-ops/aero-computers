-- PID with derivative-on-measurement and conditional-integration anti-windup.
local P = {}

function P.new(gains, out_min, out_max)
    gains = gains or {}
    return {
        kp = gains.p or 0, ki = gains.i or 0, kd = gains.d or 0,
        out_min = out_min, out_max = out_max,
        i_max = gains.i_max,   -- optional: the integral alone stays within +-i_max
        integral = 0,
    }
end

local function clamp(v, lo, hi)
    if v > hi then return hi elseif v < lo then return lo end
    return v
end

-- setpoint/measurement in the same unit; `rate` is d(measurement)/dt.
function P.step(p, setpoint, measurement, rate, dt)
    local err = setpoint - measurement
    local prop = p.kp * err
    local deriv = -p.kd * (rate or 0)
    local unclamped = prop + p.integral + deriv
    local saturated_high = unclamped >= p.out_max and err > 0
    local saturated_low = unclamped <= p.out_min and err < 0
    if not (saturated_high or saturated_low) then
        local lo, hi = p.out_min, p.out_max
        if p.i_max then lo, hi = -p.i_max, p.i_max end
        p.integral = clamp(p.integral + p.ki * err * dt, lo, hi)
    end
    return clamp(prop + p.integral + deriv, p.out_min, p.out_max)
end

function P.reset(p)
    p.integral = 0
end

return P
