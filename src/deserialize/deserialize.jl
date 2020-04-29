

"""
   extract(modelfile)

Return a [`ONNX.Types.Model`](@ref) and a Dict mapping input variables to size tuples (in Flux order).

Beware that missing/variable size data for a dimension results in a random size for that dimension. Therefore sizes should mostly be used to determine the number of dimensions.
"""
extract(modelfile::AbstractString) = open(io -> extract(io), modelfile)
function extract(io::IO)
   f = readproto(io, ONNX.Proto.ModelProto())
   return convert(f), sizes(f)
end

sizes(mp::ONNX.Proto.ModelProto) = sizes(mp.graph)
sizes(gp::ONNX.Proto.GraphProto) = Dict((name.(gp.input) .=> size.(gp.input))..., (name.(gp.output) .=> size.(gp.output))...)

NaiveNASlib.name(vip::ONNX.Proto.ValueInfoProto) = vip.name

Base.size(vip::ONNX.Proto.ValueInfoProto) = size(vip._type)
Base.size(tp::ONNX.Proto.TypeProto) = size(tp.tensor_type)
Base.size(tp_t::ONNX.Proto.TypeProto_Tensor) = size(tp_t.shape)
Base.size(tsp::ONNX.Proto.TensorShapeProto) = size.(Tuple(reverse(tsp.dim)))
Base.size(tsp_d::ONNX.Proto.TensorShapeProto_Dimension) = isdefined(tsp_d, :dim_value) ? tsp_d.dim_value : missing

"""
   CompGraph(filename::String)

Return a [`CompGraph`](@ref) loaded from the given file.
"""
NaiveNASlib.CompGraph(filename::String, vfun = create_vertex_default) = open(io -> CompGraph(io), filename)
NaiveNASlib.CompGraph(io::IO, vfun = create_vertex_default) = CompGraph(extract(io)..., vfun)
NaiveNASlib.CompGraph(m::ONNX.Types.Model, sizes, vfun = create_vertex_default) = CompGraph(m.graph, sizes, vfun)

function NaiveNASlib.CompGraph(g::ONNX.Types.Graph, sizes, vfun = create_vertex_default)
   gb = CompGraphBuilder(g, sizes)
   outputs::Vector{AbstractVertex} = vertex.(gb, node.(name.(g.output), gb), vfun)
   graph = CompGraph(gb.inputs, outputs)
   fix_zerosizes!.(outputs, gb)
   return graph
end

NaiveNASlib.name(vi::ONNX.Types.ValueInfo) = vi.name
NaiveNASlib.inputs(n::ONNX.Types.Node) = n.input
NaiveNASlib.outputs(n::ONNX.Types.Node) = n.output
optype(n::ONNX.Types.Node) = Symbol(n.op_type)

fix_zerosizes!(v::AbstractVertex, gb) = fix_zerosizes!(base(v), gb)
function fix_zerosizes!(v::InputVertex, gb) end
function fix_zerosizes!(v::CompVertex, gb) end
function fix_zerosizes!(v::SourceVertex, gb) end
function fix_zerosizes!(v::MutationVertex, gb)

    if nout(v) == 0
        outs = outputs(v)
        if !isempty(outs)
            vo = first(outs)
            ind = findfirst(==(v), inputs(vo))
            startnout = nin(vo)[ind]
            Δnout(op(v), startnout)
            NaiveNASlib.reset_out!(op(v))
        elseif name(v) in keys(gb.sizes)
            # Beware! Uninitialized sizes result in random sizes when loaded?!?!
            # Lets avoid too big sizes
            startnout = gb.sizes[name(v)][first(actdim(v))]
            if startnout < 1e8
                Δnout(op(v), startnout)
                NaiveNASlib.reset_out!(op(v))
            end
        end
    end

    for (ind, curr_insize) in enumerate(nin(v))
        found_insize = findinsize(layertype(v), v, ind, gb)
        if curr_insize == 0 && found_insize != 0
            toset = zeros(Int, length(nin(v)))
            toset[ind] = found_insize
            Δnin(op(v), toset...)
            NaiveNASlib.reset_in!(op(v))
        elseif curr_insize != found_insize
            @warn "Mismatched input sizes found for vertex with name $(name(v)) and layertype $(layertype(v)): $curr_insize vs $(found_insize)! Graph mutation near this vertex might not work"
        end
        fix_zerosizes!(inputs(v)[ind], gb)
    end
end

function findinsize(lt, v, in_index, gb)
    insize = nout(inputs(v)[in_index])
    insize != 0 && return insize


    fix_zerosizes!(inputs(v)[in_index], gb)
    return nout(inputs(v)[in_index])
end
findinsize(::FluxParLayer, v, in_index, gb) = nin(layer(v))



"""
   vertex(gb::CompGraphBuilder, n::ONNX.Types.Node, vfun = create_vertex_default)

Return an `AbstractVertex` created from `n`.

Inputs to the returned vertex are created recursively based on state in `gb`.
"""
function vertex(gb::CompGraphBuilder, n::ONNX.Types.Node, vfun = create_vertex_default)
      return get!(gb.created, n) do
         n_create, ins = check_combine(gb, n)
         invertices = map(ni -> vertex(gb, ni, vfun), ins)
         v = vfun(gb, n_create, invertices)
         if is_input(v)
            push!(gb.inputs, v)
         end
         return v
      end
end

is_input(v::AbstractVertex) = is_input(base(v))
is_input(v::InputVertex) = true
is_input(v::CompVertex) = false
is_input(v::SourceVertex) = false


create_vertex_default(gb::CompGraphBuilder, n::ONNX.Types.Node, inputs::Array; kwargs...) = verts[optype(n)](n.name, inputs, n.attribute, params(n, gb)...; kwargs...)
