
# Store for a linear series of actions.
class StackStore
  constructor: ->
    @reset()

  record: (action) ->
    @stack.splice(@idx, Infinity)
    @stack.push action
    @idx = @stack.length

  getRedoActions: ->
    if @idx == @stack.length
      actions = []
    else
      actions = [@stack[@idx]]

    actions

  redo: (action) ->
    ++@idx

  undo: (action) ->
    --@idx

  reset: ->
    @stack = []
    @idx = 0

  getUndoAction: ->
    if @idx == 0
      action = null
    else
      action = @stack[@idx - 1]

    action

  stats: ->
    {
      length: @stack.length,
      position: @idx
    }


class Commandant
  constructor: (@scope, opts = {}) ->
    @commands = {
      __compound:
        run: (scope, data) =>
          for action in data
            @_run(action, 'run')
          return
        undo: (scope, data) =>
          data_rev = data.slice()
          data_rev.reverse()

          for action in data_rev
            @_run(action, 'undo')
          return
    }

    # Can generalise this when more options added.
    @opts = { pedantic: if opts.pedantic? then opts.pedantic else true }

    @store = new StackStore

    @_silence = false
    @_compound = null

  # Allow creation of new Commandants with predefined commands.
  @define: (commands={}) ->
    fn = (scope, opts) ->
      commander = new Commandant(scope, opts)
      for name, cmd of commands
        commander.register(name, cmd)
      commander

    fn.register = (name, command) ->
      commands[name] = command

    fn

  _hook: (name, arg) ->
    @trigger?(name.toLowerCase(), arg)
    @["on#{name}"]?(arg)

    @trigger?('change', name, arg)
    @onChange?(name, arg)

  # Expose some information on the action store.
  storeStats: ->
    @store.stats()

  # Push an action
  _push: (action) ->
    if @_compound
      @_compound.push(action)
    else
      @store.record(action)
      @_hook('Execute', action)

    return

  # Get the actions that redo could call.
  # If proceed is set, only return first one and advance the store.
  getRedoActions: (proceed = false) ->
    actions = @store.getRedoActions()
    if proceed
      action = actions[0]
      if !action
        return null
      @store.redo(action)
      return action
    else
      return actions

  # Get the action that undo could call, and rollback the store if proceed is true.
  getUndoAction: (proceed = false) ->
    action = @store.getUndoAction()
    @store.undo(action) if proceed and action
    action

  # Reset the Commandant.
  # By default it will unwind the actions.
  reset: (rollback=true) ->
    if rollback
      @undo() while @getUndoAction()
    @store.reset()

    @_hook('Reset', rollback)

    return

  # Register a new named command to be available for execution.
  register: (name, command) ->
    @commands[name] = command

    return

  # Execute a function without recording any command executions.
  __silence: (fn) ->
    if @_silence
      result = fn()
    else
      @_silence = true
      result = fn()
      @_silence = false

    return result

  silent: Commandant::_silence

  # Create a proxy with partially bound arguments.
  # Doesn't support binding for compound command.
  bind: (scoped_args...) ->
    {
      execute: (name, args...) =>
        @execute.apply(@, [name, scoped_args..., args...])
      transient: (name, args...) =>
        @transient.apply(@, [name, scoped_args..., args...])
    }

  # Try and aggregate an action given the current state.
  _agg: (action) ->
    prev_action = if @_compound
      @_compound[@_compound.length - 1]
    else
      @getUndoAction()

    if prev_action
      if agg = @commands[prev_action.name].aggregate?(prev_action, action)
        prev_action.name = agg.name
        prev_action.data = agg.data
        return prev_action
    return

  # Execute a new command, with name and data.
  # Commands executed will be recorded and can execute other commands, but they
  # will not themselves be recorded.
  #
  # TODO: would auto-collection of executed subcommands into a compound action
  # be useful, or opaque/brittle? Could replace the __compound command.
  execute: (name, args...) ->
    @_assert(!@_transient, 'Cannot execute while transient action active.')

    command = @commands[name]
    data = command.init.apply(command, [@scope, args...])

    action = { name, data }

    result = @_run(action, 'run')

    if @_silence or !@_agg(action)
      @_push(action)

    return result

  # Run the Commandant redos one step. Does nothing if at end of chain.
  redo: ->
    @_assert(!@_transient, 'Cannot redo while transient action active.')
    @_assert(!@_compound, 'Cannot redo while compound action active.')

    action = @getRedoActions(true)
    return unless action
    @_run(action, 'run')

    @_hook('Redo', action)

    return

  # Run the Commandant undos one step. Does nothing if at start of chain.
  undo: ->
    @_assert(!@_transient, 'Cannot undo while transient action active.')
    @_assert(!@_compound, 'Cannot undo while compound action active.')

    action = @getUndoAction(true)
    return unless action
    @_run(action, 'undo')

    @_hook('Undo', action)

    return

  # Transient commands may update their data after being run for the first
  # time. The command named must support the `update` method.
  #
  # Useful for e.g. drag operations, where you want to record a single drag,
  # but update the final position many times before completion.
  #
  # No other commands, nor redo/undo, may be run while a transient is
  # active. This is for safety to ensure that there are no concurrency issues.
  transient: (name, args...) ->
    command = @commands[name]

    @_assert(command.update?,
      "Command #{name} does not support transient calling.")

    data = command.init.apply(command, [@scope, args...])
    ret_val = @_run({ name, data }, 'run')

    @_transient = { name, data, ret_val }

    @_hook('Update', @_transient)

    return

  update: (args...) ->
    @_assert(@_transient, 'Cannot update without a transient action active.')

    @_transient.data = @_run.apply(@, [@_transient, 'update', args...])

    @_hook('Update', @_transient)

    return

  finishTransient: ->
    @_assert(@_transient, 'Cannot finishTransient without a transient action active.')

    action = { name: @_transient.name, data: @_transient.data }
    ret_val = @_transient.ret_val

    @_transient = null

    if !@_agg(action)
      @_push(action)

    ret_val

  cancelTransient: ->
    @_assert(@_transient, 'Cannot cancelTransient without a transient action active.')

    undo = @_run(@_transient, 'undo')

    @_transient = null

    return undo

  # Compound command capture
  captureCompound: ->
    @_assert(!@_transient, 'Cannot captureCompound while transient action active.')
    @_compound = []

  finishCompound: ->
    @_assert(!@_transient, 'Cannot finishCompound while transient action active.')
    @_assert(@_compound, 'Cannot finishCompound without compound capture active.')
    cmds = @_compound
    @_compound = null

    if cmds && cmds.length > 0
      @_push({ name: '__compound', data: cmds })
    return

  cancelCompound: ->
    @_assert(@_compound, 'Cannot cancelCompound without compound capture active.')
    result = @commands['__compound'].undo(@scope, @_compound)
    @_compound = null
    return result

  # Private helpers
  _assert: (val, message) ->
    if @opts.pedantic and !val
      throw message
    return

  # Helper method for running a scoped method on an action.
  _run: (action, method, args...) ->
    command = @commands[action.name]
    scope = if command.scope then command.scope(@scope, action.data) else @scope
    @__silence(=> command[method].apply(command, [scope, action.data, args...]))

`// @exclude
`

if typeof require != 'undefined'
  try
    Q = require('q')
  catch exc

# Asynchronous version, using the Q promise library.
class Commandant.Async extends Commandant

  constructor: ->
    super

    @commands = {
      __compound:
        run: (scope, data) =>
          result = Q.when(undefined)

          for action in data
            do (action) =>
              result = result.then => @_run(action, 'run')

          result
        undo: (scope, data) =>
          result = Q.when(undefined)

          data_rev = data.slice()
          data_rev.reverse()

          for action in data
            do (action) =>
              result = result.then => @_run(action, 'undo')

          result
    }

    if typeof Q == 'undefined'
      throw 'Cannot run in asynchronous mode without Q available.'

    @_running = null
    @_deferQueue = []

  __silence: (fn) ->
    if @_silence
      promise = Q.when(fn())
    else
      @_silence = true
      promise = Q.when(fn()).fin =>
        @_silence = false

    promise

  silent: (fn) ->
    @_defer(@__silence, fn)

  # Defer a fn to be run with the Commandant as scope.
  _defer: (fn, args...) ->
    deferred = Q.defer()

    defer_fn = =>
      Q.when(fn.apply(@, args)).then (result) ->
        deferred.resolve(result)
      , (err) ->
        console.log('Encountered error in deferred fn', err)
        deferred.reject(err)

    @_deferQueue.push defer_fn

    if !@_running
      @_runDefer()

    deferred.promise

  # Consume the deferred function queue.
  _runDefer: ->
    return if @_running or @_deferQueue.length == 0

    next_fn = @_deferQueue.shift()

    @_running = next_fn()

    @_running.fin =>
      @_running = null
      @_runDefer()

    return

  execute: (name, args...) ->
    @_defer(@_executeAsync, name, args)

  _executeAsync: (name, args) ->
    @_assert(!@_transient, 'Cannot execute while transient action active.')

    command = @commands[name]
    action = null

    Q.resolve(command.init.apply(command, [@scope, args...])).then (data) =>
      action = { name, data }
      Q.resolve(@_run(action, 'run'))
    .then (result) =>
      if @_silence or !@_agg(action)
        @_push(action)
      result

  redo: ->
    @_defer(@_redoAsync)

  _redoAsync: ->
    @_assert(!@_transient, 'Cannot redo while transient action active.')
    @_assert(!@_compound, 'Cannot redo while compound action active.')

    action = @getRedoActions(true)
    return Q.resolve(undefined) unless action

    Q.when(@_run(action, 'run')).then =>
      @_hook('Redo', action)

  undo: ->
    @_defer(@_undoAsync)

  _undoAsync: ->
    @_assert(!@_transient, 'Cannot undo while transient action active.')
    @_assert(!@_compound, 'Cannot undo while compound action active.')

    action = @getUndoAction(true)
    return Q.resolve(undefined) unless action

    Q.when(@_run(action, 'undo')).then =>
      @_hook('Undo', action)

  captureCompound: ->
    @_defer(Commandant::captureCompound)

  finishCompound: ->
    @_defer(Commandant::finishCompound)

  cancelCompound: ->
    @_defer(Commandant::cancelCompound)

  transient: (name, args...) ->
    @_defer(@_transientAsync, name, args)

  _transientAsync: (name, args) ->
    command = @commands[name]

    @_assert(command.update?,
      "Command #{name} does not support transient calling.")

    @_transient = { name }

    Q.when(command.init.apply(command, [@scope, args...])).then (data) =>
      @_transient.data = data
      Q.when(@_run(@_transient, 'run'))
    .then (ret_val) =>
      @_transient.ret_val = ret_val

      @_hook('Update', @_transient)

      return

  update: (args...) ->
    @_defer(@_updateAsync, args)

  _updateAsync: (args) ->
    @_assert(@_transient, 'Cannot update without a transient action active.')

    Q.when(@_run.apply(@, [@_transient, 'update', args...])).then (data) =>
      @_transient.data = data

      @_hook('Update', @_transient)
      return

  finishTransient: ->
    @_defer(Commandant::finishTransient)

  cancelTransient: ->
    @_defer(Commandant::cancelTransient)

`// @endexclude
`

if typeof module != 'undefined'
  module.exports = Commandant
else if typeof define == 'function' and define.amd
  define(-> Commandant)
else
  window.Commandant = Commandant
