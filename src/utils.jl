"""
Function returning the name of a where parameter
"""
function get_param_name(expr) :: Symbol
  @capture(expr, arg_<:arg_type_) && return arg
  @capture(expr, arg_) && return arg
end

"""
Function returning the arguments of a function definition
"""
function get_args(func_def::Dict)
  arg_dict = Dict{Symbol, Any}()
  arg_list = Vector{Symbol}()
  kwarg_list = Vector{Symbol}()
  for arg in (func_def[:args]...,)
    arg_def = splitarg(arg)
    push!(arg_list, arg_def[1])
    arg_dict[arg_def[1]] = arg_def[3] ? Any : arg_dict[arg_def[1]] = arg_def[2]
  end
  for arg in (func_def[:kwargs]...,)
    arg_def = splitarg(arg)
    push!(kwarg_list, arg_def[1])
    arg_dict[arg_def[1]] = arg_def[3] ? Any : arg_dict[arg_def[1]] = arg_def[2]
  end
  arg_list, kwarg_list, arg_dict
end

"""
Function returning the slots of a function definition
"""
function get_slots(func_def::Dict, args::Dict{Symbol, Any}, mod::Module) :: Dict{Symbol, Any}
  slots = Dict{Symbol, Any}()
  func_def[:name] = gensym()
  func_def[:args] = (func_def[:args]..., func_def[:kwargs]...)
  func_def[:kwargs] = []
  body = func_def[:body]
  func_def[:body] = postwalk(transform_yield, func_def[:body])
  func_expr = combinedef(func_def) |> flatten
  @eval(mod, @noinline $func_expr)
  code_data_infos = @eval(mod, begin using ResumableFunctions; ResumableFunctions.my_code_typed($(func_def[:name])) end )
  for (code_info, slottypes) in code_data_infos
    for (i, slotname) in enumerate(code_info.slotnames)
      slots[slotname] = slottypes[i]
    end
  end
  for (argname, argtype) in args
    slots[argname] = argtype
  end
  postwalk(x->remove_catch_exc(x, slots), func_def[:body])
  postwalk(x->make_arg_any(x, slots), body)
  for (key, val) in slots
    if val == Union{}
      slots[key] = Any
    end
  end
  delete!(slots, Symbol("#temp#"))
  delete!(slots, Symbol("#unused#"))
  delete!(slots, Symbol("#self#"))
  slots
end

function my_code_typed(@nospecialize(f), @nospecialize(types=Tuple); world = Base.get_world_counter(), params = Core.Compiler.Params(world))
  ccall(:jl_is_in_pure_context, Bool, ()) && error("code reflection cannot be used from generated functions")
  if isa(f, Core.Builtin)
      throw(ArgumentError("argument is not a generic function"))
  end
  types = Core.Compiler.to_tuple_type(types)
  asts = []
  for x in Core.Compiler._methods(f, types, -1, world)
      meth = Core.Compiler.func_for_method_checked(x[3], types, x[2])
      (code, slottypes) = my_typeinf_code(meth, x[1], x[2], false, params)
      code === nothing && error("inference not successful")
      Base.remove_linenums!(code)
      push!(asts, code => slottypes)
  end
  return asts
end

function my_typeinf_code(method::Method, @nospecialize(atypes), sparams::Core.Compiler.SimpleVector, run_optimizer::Bool, params::Core.Compiler.Params)
  mi = Core.Compiler.specialize_method(method, atypes, sparams)::Core.Compiler.MethodInstance
  ccall(:jl_typeinf_begin, Cvoid, ())
  result = Core.Compiler.InferenceResult(mi)
  frame = Core.Compiler.InferenceState(result, false, params)
  frame === nothing && return (nothing, Any)
  if Core.Compiler.typeinf(frame) && run_optimizer
      opt = Core.Compiler.OptimizationState(frame)
      optimize(opt, result.result)
      opt.src.inferred = true
  end
  ccall(:jl_typeinf_end, Cvoid, ())
  frame.inferred || return (nothing, Any)
  return (frame.src, frame.slottypes)
end

"""
Function removing the `exc` symbol of a `catch exc` statement of a list of slots.
"""
function remove_catch_exc(expr, slots::Dict{Symbol, Any})
  @capture(expr, (try body__ catch exc_; handling__ end) | (try body__ catch exc_; handling__ finally always__ end)) && delete!(slots, exc)
  expr
end

"""
Function changing the type of a slot `arg` of a `arg = @yield ret` or `arg = @yield` statement to `Any`.
"""
function make_arg_any(expr, slots::Dict{Symbol, Any})
  @capture(expr, arg_ = ex_) || return expr
  _is_yield(ex) || return expr
  slots[arg] = Any
  expr
end

"""
Function returning the args for the type construction.
"""
function make_args(func_def::Dict)
  args=[]
  for arg in (func_def[:args]..., func_def[:kwargs]...)
    arg_def = splitarg(arg)
    push!(args, combinearg(arg_def[1], arg_def[2], false, arg_def[4]))
  end
  (args...,)
end



"""
Function checking the use of a return statement with value
"""
function hasreturnvalue(expr)
  @capture(expr, return val_) || return expr
  (val == :nothing || val == nothing) && return expr
  @warn "@resumable function contains return statement with value!"
  expr
end
