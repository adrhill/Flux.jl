function nodename(s::mx.SymbolicNode)
  name = Ref{mx.char_p}(0)
  success = Ref(0)
  mx.@mxcall(:MXSymbolGetName, (mx.MX_handle, Ref{mx.char_p}, Ref{Int}), s.handle.value, name, success)
  @assert success[] != -1
  return Symbol(unsafe_wrap(String, name[]))
end

using Base: @get!
using DataFlow: Constant, constant
using DataFlow.Interpreter
using DataFlow.Interpreter: Exception, totrace
using Flux: imap

# TODO: implement Julia's type promotion rules

node(x::Tuple) = map(node, x)
node(x::mx.SymbolicNode) = x

graph(::typeof(tuple), args...) = (args...,)
graph(::typeof(+), args...) = mx.broadcast_plus(args...)
graph(::typeof(σ), x) = mx.Activation(data = x, act_type = :sigmoid)
graph(::typeof(relu), x) = mx.Activation(data = x, act_type = :relu)
graph(::typeof(tanh), x) = mx.Activation(data = x, act_type = :tanh)
graph(::typeof(flatten), x) = mx.Flatten(data = x)

graph(::typeof(softmax), xs) =
  mx.broadcast_div(exp(xs), mx.Reshape(mx.sum(exp(xs)), shape = (1,1)))

graph(::typeof(cat), dim::Integer, a...) = mx.Concat(a..., dim = dim)
graph(::typeof(vcat), a...) = graph(cat, 1, a...)

graph(::Input, x) = x

# TODO: use actual params

graph(ctx::Context, d::Affine, x) =
  mx.FullyConnected(data = x,
                    num_hidden = size(d.W.x, 2))

graph(ctx::Context, c::Conv2D, x) =
  mx.Convolution(data = x,
                 kernel = size(c.filter, 1, 2),
                 num_filter = size(c.filter, 4),
                 stride = c.stride)

graph(ctx::Context, p::MaxPool, x) =
  mx.Pooling(data = x,
             pool_type = :max,
             kernel = p.size,
             stride = p.stride)

function register(ctx::Context, node::mx.SymbolicNode)
  ctx[:stacks][nodename(node)] = stack(ctx)
  return node
end

register(ctx::Context, node) = node

function var(ctx::Context, p::Flux.Param)
  id = gensym()
  ctx[:params][id] = p.x
  return mx.Variable(id)
end

graph{T<:AArray}(ctx::Context, p::Constant{Flux.Param{T}}) = var(ctx, p.value)

graph(ctx::Context, p::Constant) = node(p.value)

function graph(ctx::Context, model, args...)
  g = Flux.graph(model)
  g == nothing && return register(ctx, @ithrow ctx graph(model, args...))
  DataFlow.iscyclic(g) && error("This model has a cycle; try unrolling it first.")
  interpret(ctx, g, args...)
end

graph′(ctx::Context, args...) = @ithrow ctx graph(ctx, args...)

function tograph(model, args...)
  ctx = Context(mux(iline, ilambda, imap, iargs, ituple, graph′),
                params = Dict(), stacks = Dict())
  out = @icatch graph(ctx, model, args...)
  return ctx[:params], ctx[:stacks], out
end

# Error Handling

using Juno
Juno.errmsg(e::mx.MXError) = e.msg

function errnode(e::mx.MXError)
  m = match(r"Error in (\w+):", e.msg)
  m == nothing && return
  Symbol(m.captures[1])
end

macro mxerr(stk, ex)
  :(try
      $(esc(ex))
    catch e
      (isa(e, mx.MXError) && (node = errnode(e)) != nothing) || rethrow()
      stk = $(esc(stk))
      throw(Exception(e, totrace(stk[node])))
    end)
end
