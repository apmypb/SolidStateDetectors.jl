"""
    mutable struct Event{T <: SSDFloat}

Collection struct for individual events. 
This (mutable) struct is meant to be used to look at individual events,
not to process a huge amount of events.

## Fields
* `locations::Union{Vector{<:AbstractCoordinatePoint{T}}, Missing}`: Vector of the positions of all hits of the event.
* `energies::Union{Vector{T}, Missing}`: Vector of energies corresponding to the hits of the event.
* `drift_paths::Union{Vector{EHDriftPath{T}}, Missing}`: Calculated drift paths of each hit position. 
* `waveforms::Union{Vector{<:Any}, Missing}`: Generated signals (waveforms) of the event.
"""
mutable struct Event{T <: SSDFloat}
    locations::Union{Vector{<:AbstractCoordinatePoint{T}}, Missing}
    energies::Union{Vector{T}, Missing}
    drift_paths::Union{Vector{EHDriftPath{T}}, Missing}
    waveforms::Union{Vector{<:Any}, Missing}
    Event{T}() where {T <: SSDFloat} = new{T}(missing, missing, missing, missing)
end

function Event(locations::Vector{<:AbstractCoordinatePoint{T}}, energies::Vector{<:RealQuantity{T}} = ones(T, length(locations)))::Event{T} where {T <: SSDFloat}
    evt = Event{T}()
    evt.locations = locations
    evt.energies = to_internal_units(energies)
    evt.waveforms = missing
    return evt
end


function Event(nbcc::NBodyChargeCloud{T})::Event{T} where {T <: SSDFloat}
    evt = Event{T}()
    evt.locations = nbcc.points
    evt.energies = nbcc.energies
    evt.waveforms = missing
    return evt
end

function Event(evt::NamedTuple{(:evtno, :detno, :thit, :edep, :pos),
         <:Tuple{
            Union{Integer, AbstractVector{<:Integer}},
            Union{Integer, AbstractVector{<:Integer}},
            AbstractVector{<:RealQuantity},
            AbstractVector{<:RealQuantity},
            AbstractVector{<:AbstractVector{<:RealQuantity}}
        }}, T = missing)
    if ismissing(T) T = eltype(to_internal_units(evt[:edep][:])) end

    evt = Event(
        CartesianPoint{T}.(to_internal_units.(evt[:pos][:])),
        T.(to_internal_units.(evt[:edep][:]))
    )

    return evt
end

in(evt::Event, det::SolidStateDetector) = all( pt -> pt in det, evt.locations)
in(evt::Event, sim::Simulation) = all( pt -> pt in sim.detector, evt.locations)

"""
    drift_charges!(evt::Event{T}, sim::Simulation{T}; kwargs...)::Nothing where {T <: SSDFloat}

Calculates the electron and hole drift paths for the given [`Event`](@ref) and [`Simulation`](@ref)
    and stores them in `evt.drift_paths`.
    
## Arguments 
* `evt::Event{T}`: [`Event`](@ref) for which the charges should be drifted.
* `sim::Simulation{T}`: [`Simulation`](@ref) which defines the setup in which the charges in `evt` should drift.

## Keywords
* `max_nsteps::Int = 1000`: Maximum number of steps in the drift of each hit. 
* `Δt::RealQuantity = 5u"ns"`: Time step used for the drift.
* `diffusion::Bool = false`: Activate or deactive diffusion of charge carriers via random walk.
* `self_repulsion::Bool = false`: Activate or deactive self-repulsion of charge carriers of the same type.
* `verbose = true`: Activate or deactivate additional info output.

## Example 
```julia 
drift_charges!(evt, sim, Δt = 1u"ns", verbose = false)
```

!!! note
    Using values with units for `Δt` requires the package [Unitful.jl](https://github.com/PainterQubits/Unitful.jl).
"""
function drift_charges!(evt::Event{T}, sim::Simulation{T}; max_nsteps::Int = 1000, Δt::RealQuantity = 5u"ns", diffusion::Bool = false, self_repulsion::Bool = false, verbose::Bool = true)::Nothing where {T <: SSDFloat}
    evt.drift_paths = drift_charges(sim, CartesianPoint.(evt.locations), evt.energies, Δt = Δt, max_nsteps = max_nsteps, diffusion = diffusion, self_repulsion = self_repulsion, verbose = verbose)
    nothing
end
function get_signal!(evt::Event{T}, sim::Simulation{T}, contact_id::Int; Δt::RealQuantity = 5u"ns")::Nothing where {T <: SSDFloat}
    @assert !ismissing(evt.drift_paths) "No drift path for this event. Use `drift_charges(evt::Event, sim::Simulation)` first."
    @assert !ismissing(sim.weighting_potentials[contact_id]) "No weighting potential for contact $(contact_id). Use `calculate_weighting_potential!(sim::Simulation, contact_id::Int)` first."
    if ismissing(evt.waveforms)
        evt.waveforms = Union{Missing, RadiationDetectorSignals.RDWaveform}[missing for i in eachindex(sim.detector.contacts)]
    end
    evt.waveforms[contact_id] = get_signal(sim, evt.drift_paths, evt.energies, contact_id, Δt = Δt)
    nothing
end


"""
    get_signals!(evt::Event{T}, sim::Simulation{T}; Δt::RealQuantity = 5u"ns")::Nothing where {T <: SSDFloat}
    
Generates the signals/waveforms from the drift paths of an [`Event`](@ref) for each [`Contact`](@ref),
for which a [`WeightingPotential`](@ref) is specified in `sim.weighting_potentials`.
    
The output is stored in `evt.waveforms`.

## Arguments 
* `evt::Event{T}`: [`Event`](@ref) for which the waveforms should be generated.
* `sim::Simulation{T}`: [`Simulation`](@ref) which defines the setup in which the waveforms are generated.

## Keywords
* `Δt::RealQuantity = 5u"ns"`: Time steps with which the drift paths were calculated.

## Example 
```julia
get_signals!(evt, sim, Δt = 1u"ns") # if evt.drift_paths were calculated in time steps of 1ns
```

!!! note 
    This method only works if `evt.drift_paths` has already been calculated and is not `missing`.
"""
function get_signals!(evt::Event{T}, sim::Simulation{T}; Δt::RealQuantity = 5u"ns")::Nothing where {T <: SSDFloat}
    @assert !ismissing(evt.drift_paths) "No drift path for this event. Use `drift_charges!(evt::Event, sim::Simulation)` first."
    if ismissing(evt.waveforms)
        evt.waveforms = Union{Missing, RadiationDetectorSignals.RDWaveform}[missing for i in eachindex(sim.detector.contacts)]
    end
    for contact in sim.detector.contacts
        if any(ismissing, sim.weighting_potentials) "No weighting potential(s) for some contact(s).." end
        if !ismissing(sim.weighting_potentials[contact.id])
            evt.waveforms[contact.id] = get_signal(sim, evt.drift_paths, evt.energies, contact.id, Δt = Δt)
        end
    end
    nothing
end

"""
    simulate!(evt::Event{T}, sim::Simulation{T}; kwargs...)::Nothing where {T <: SSDFloat}

Simulates the waveforms for the [`Event`](@ref) for a given [`Simulation`](@ref) by

1. calculating the drift paths of all energy hits, at `evt.locations` and 
2. generating the waveforms for each [`Contact`](@ref), for which a [`WeightingPotential`](@ref) is specified in `sim.weighting_potentials`.

The output is stored in `evt.drift_paths` and `evt.waveforms`.

## Arguments 
* `evt::Event{T}`: [`Event`](@ref) for which the charges should be drifted.
* `sim::Simulation{T}`: [`Simulation`](@ref) which defines the setup in which the charges in `evt` should drift.

## Keywords
* `max_nsteps::Int = 1000`: Maximum number of steps in the drift of each hit. 
* `Δt::RealQuantity = 5u"ns"`: Time step used for the drift.
* `diffusion::Bool = false`: Activate or deactive diffusion of charge carriers via random walk.
* `self_repulsion::Bool = false`: Activate or deactive self-repulsion of charge carriers of the same type.
* `verbose = true`: Activate or deactivate additional info output.

## Example 
```julia
simulate!(evt, sim, Δt = 1u"ns", verbose = false)
```

See also [`drift_charges!`](@ref) and [`get_signals!`](@ref).
"""
function simulate!(evt::Event{T}, sim::Simulation{T}; max_nsteps::Int = 1000, Δt::RealQuantity = 5u"ns", diffusion::Bool = false, self_repulsion::Bool = false, verbose::Bool = true)::Nothing where {T <: SSDFloat}
    drift_charges!(evt, sim, max_nsteps = max_nsteps, Δt = Δt, diffusion = diffusion, self_repulsion = self_repulsion, verbose = verbose)
    get_signals!(evt, sim, Δt = Δt)
    nothing
end


"""
    add_baseline_and_extend_tail(wv::RadiationDetectorSignals.RDWaveform{T,U,TV,UV}, n_baseline_samples::Int, total_waveform_length::Int) where {T,U,TV,UV}

Adds a zero-valued baseline in front of the waveform `wv` and extends (or cuts off) the waveform at the end with the last value of `wv`.
A waveform of length `total_waveform_length` is returned.

## Arguments
* `wv::RadiationDetectorSignals.RDWaveform{T,U,TV,UV}`: A waveform (signal over time).
* `n_baseline_samples::Int`: Number of samples added in front of the waveform with values 0. 
* `total_waveform_length::Int`: Number of samples of the extended waveform which is returned.

## Examples
    add_baseline_and_extend_tail(wv, 1000, 5000)   

!!! note 
    This functions assumes that the time steps between the samples of the input waveform `wv` are the same. Thus, that the input waveform is
    sampled with a fixed frequency. 
"""
function add_baseline_and_extend_tail(wv::RadiationDetectorSignals.RDWaveform{T,U,TV,UV}, n_baseline_samples::Int, total_waveform_length::Int) where {T,U,TV,UV}
    new_signal::Vector{eltype(UV)} = Vector{eltype(UV)}(undef, total_waveform_length)
    new_signal[1:n_baseline_samples] .= zero(eltype(UV))
    if length(wv.value) <= total_waveform_length - n_baseline_samples
        new_signal[n_baseline_samples+1:n_baseline_samples+length(wv.value)] = wv.value
        new_signal[n_baseline_samples+length(wv.value)+1:end] .= wv.value[end]
    else
        new_signal[n_baseline_samples+1:end] = wv.value[1:total_waveform_length - n_baseline_samples]
    end
    new_times = if TV <: AbstractRange
        range( zero(first(wv.time)), step = step(wv.time), length = total_waveform_length )
    else
        error("Not yet definted for timestamps of type `$(TV)`")
    end
    return RDWaveform( new_times, new_signal )
end


"""
    get_electron_and_hole_contribution(evt::Event{T}, sim::Simulation{T}, contact_id::Int)
    
Returns the electron and hole contribution to the waveform of a [`Contact`](@ref) with a given
`contact_id` of an [`Event`](@ref) as a `NamedTuple` with two entries: 
`electron_contribution` and `hole_contribution`.

## Arguments
* `evt::Event{T}`: [`Event`](@ref) in which the charges have already been drifted.
* `sim::Simulation{T}`: [`Simulation`](@ref) which defines the setup in which the charges in `evt` were drifted.
* `contact_id::Int`: The `id` of the [`Contact`](@ref) for which the waveform should be split into electron and hole contribution.

## Example
```julia 
using Plots
using SolidStateDetector
T = Float32

simulation = Simulation{T}(SSD_examples[:InvertedCoax])
simulate!(simulation)
event = Event([CartesianPoint{T}(0.02,0.01,0.05)])
simulate!(event, simulation)

contact_id = 1
wf = get_electron_and_hole_contribution(evt, sim, contact_id)
plot(add_baseline_and_extend_tail(wf.electron_contribution, 0, 500), label = "Electron contribution", color = :red, lw = 2)
plot!(add_baseline_and_extend_tail(wf.hole_contribution, 0, 500), label = "Hole contribution", color = :green, lw = 2)
plot!(add_baseline_and_extend_tail(event.waveforms[contact_id], 0, 500), label = "Sum", color = contact_id, lw = 2, alpha = 0.5)
```

!!! note 
    The drift paths in `evt` need to be calculated using [`drift_charges!`](@ref) before calling this function.
"""
function get_electron_and_hole_contribution(evt::Event{T}, sim::Simulation{T, S}, contact_id::Int
            )::NamedTuple{(:electron_contribution, :hole_contribution), <:Tuple{RDWaveform, RDWaveform}} where {T <: SSDFloat, S}
    
    @assert !ismissing(evt.drift_paths) "The charge drift is not yet simulated. Please use `drift_charges!(evt, sim)`!"
    
    dt::T = T(ustrip(uconvert(u"ns", diff(evt.drift_paths[1].timestamps_e)[1]*u"s")))
    wp::Interpolations.Extrapolation{T, 3} = interpolated_scalarfield(sim.weighting_potentials[contact_id])
    signal_e::Vector{T} = zeros(T, length(maximum(map(p -> p.timestamps_e, evt.drift_paths))))
    signal_h::Vector{T} = zeros(T, length(maximum(map(p -> p.timestamps_h, evt.drift_paths))))

    for i in eachindex(evt.drift_paths)
        energy = evt.energies[i]
        
        dp_e::Vector{CartesianPoint{T}} = evt.drift_paths[i].e_path
        dp_e_t::Vector{T} = evt.drift_paths[i].timestamps_e
        add_signal!(signal_e, dp_e_t, dp_e, dp_e_t, T(-1)*energy, wp, S)
        
        dp_h::Vector{CartesianPoint{T}} = evt.drift_paths[i].h_path
        dp_h_t::Vector{T} = evt.drift_paths[i].timestamps_h
        add_signal!(signal_h, dp_h_t, dp_h, dp_h_t, energy, wp, S)
    end
    
    return (electron_contribution = RDWaveform(range(zero(T) * u"ns", step = dt * u"ns", length = length(signal_e)), signal_e),
            hole_contribution = RDWaveform(range(zero(T) * u"ns", step = dt * u"ns", length = length(signal_h)), signal_h))
end

export get_electron_and_hole_contribution
