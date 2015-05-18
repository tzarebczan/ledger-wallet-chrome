
OperationTypes =
  SET: 0
  REMOVE: 1

# A store able to synchronize with a remote crypted store. This store has an extra method in order to order a push or pull
# operations
# @event pulled Emitted once the store is pulled from the remote API
class ledger.storage.SyncedStore extends ledger.storage.SecureStore

  PULL_INTERVAL_DELAY: ledger.config.syncRestClient.pullIntervalDelay || 10000
  PULL_THROTTLE_DELAY: ledger.config.syncRestClient.pullThrottleDelay || 1000
  PUSH_DEBOUNCE_DELAY: ledger.config.syncRestClient.pushDebounceDelay || 1000

  # @param [String] name The store name
  # @param [String] key The secure key used to encrypt/decrypt the store
  # @param [Function] syncPushHandler A function used to perform push synchronization operations
  # @param [Function] syncPullHandler A function used to perform pull synchronization operations
  # @param [ledger.storage.Store] auxiliaryStore A store used to save ledger.storage.SyncedStored meta data
  constructor: (name, addr, key, auxiliaryStore = ledger.storage.wallet) ->
    super(name, key)
    @mergeStrategy = @_overwriteStrategy
    @client = ledger.api.SyncRestClient.instance(addr)
    @throttled_pull = _.throttle _.bind(@._pull,@), @PULL_THROTTLE_DELAY
    @debounced_push = _.debounce _.bind(@._push,@), @PUSH_DEBOUNCE_DELAY
    @_auxiliaryStore = auxiliaryStore
    @_changes = []
    @_unlockMethods = _.lock(this, ['set', 'get', 'remove', 'clear', '_pull'])
    _.defer =>
      @_auxiliaryStore.get ['__last_sync_md5', '__sync_changes'], (item) =>
        @lastMd5 = item.__last_sync_md5
        @_changes = item['__sync_changes'].concat(@_changes) if item['__sync_changes']?
        @_unlockMethods()
        @throttled_pull()

  # Stores one or many item
  #
  # @param [Object] items Items to store
  # @param [Function] cb A callback invoked once the insertion is done
  set: (items, cb) ->
    return cb?() unless items?
    @_changes.push {type: OperationTypes.SET, key: key, value: value} for key, value of items
    this.debounced_push()
    _.defer => cb?()

  get: (keys, cb) ->
    values = {}
    handledKeys = []
    for key in keys when (changes = _.where(@_changes, key: key)).length > 0
      values[key] = _(changes).last().value if _(changes).last().type is OperationTypes.SET
      handledKeys.push key
    keys = _(keys).without(handledKeys...)
    super keys, (storeValues) ->
      cb?(_.extend(storeValues, values))

  # Removes one or more items from storage.
  #
  # @param [Array|String] key A single key to get, list of keys to get.
  # @param [Function] cb A callback invoked once the removal is done.
  remove: (keys, cb) ->
    return cb?() unless keys?
    @_changes.push {type: OperationTypes.REMOVE, key: key} for key in keys
    this.debounced_push()
    _.defer => cb?()

  clear: (cb) ->
    super(cb)
    @_changes = {}
    @client.delete_settings()

  # @return A promise
  _pull: ->
    # Get distant store md5
    # If local md5 and distant md5 are different
      # -> pull the data
      # -> merge data

    @client.get_settings_md5().then( (md5) =>
      return undefined if md5 == @lastMd5
      @client.get_settings().then (items) =>
        @mergeStrategy(items).then =>
          @_setLastMd5(md5)
          @emit('pulled')
          items
    ).catch (jqXHR) =>
      # Data not synced already
      return this._init() if jqXHR.status == 404
      jqXHR

  _merge: (data) ->
    # Consistency chain check
      # if common last consistency sha1 index > consistency chain max size * 3/4
        # Invalidate changes and overwrite local storage
      # else
        # Overwrite local storage and keep changes

  # @return A jQuery promise
  _push: ->
    # return if no changes
    # Pull data
    # If no changes
      # Abort
    # Else
      # Update consistency chain
      # Push

  _applyChanges: ->


    ###
    d = Q.defer()
    this._raw_get null, (raw_items) =>
      settings = {}
      for raw_key, raw_value of raw_items
        settings[raw_key] = raw_value if raw_key.match(@_nameRegex)
      @__retryer (ecbr) =>
        @client.put_settings(settings).catch(ecbr).then (md5) =>
          @_setLastMd5(md5)
          d.resolve(md5)
      , _.bind(d.reject,d)
    , _.bind(d.reject,d)
    d.promise
    ###

  # @return A jQuery promise
  _overwriteStrategy: (items) ->
    d = Q.defer()
    this._raw_set items, _.bind(d.resolve,d)
    d.promise

  # Call fct with ecbr as arg and retry it on fail.
  # Wait 1 second before retry first time, double until 64 s then.
  #
  # @param [Function] fct A function invoked with ecbr, a retry on error callback.
  # @param [Function] ecb A callback invoked when retry all fail.
  __retryer: (fct, ecb, wait=1000) ->
    fct (err) =>
      if wait <= 64*1000
        setTimeout (=> @__retryer(fct, ecb, wait*2)), wait
      else
        console.error(err)
        ecb?(err)

  _initConnection: ->
    @__retryer (ecbr) =>
      @_pull().then( =>
        setTimeout =>
          @pullTimer = setInterval(@throttled_pull, @PULL_INTERVAL_DELAY)
        , @PULL_INTERVAL_DELAY
      ).catch (jqXHR) =>
        # Data not synced already
        if jqXHR.status == 404
          this._init().catch(ecbr).then =>
            setInterval(@throttled_pull, @PULL_INTERVAL_DELAY)
        else if jqXHR.status == 400
          console.error("BadRequest during SyncedStore initialization:", jqXHR)
        else
          ecbr(jqXHR)
    ledger.app.dongle.once 'state:changed', =>
      clearInterval(@pullTimer) if !ledger.app.dongle? || ledger.app.dongle.state != ledger.dongle.States.UNLOCKED

  # @param [Function] cb A callback invoked once init is done. cb()
  # @param [Function] ecb A callback invoked when init fail. Take $.ajax.fail args.
  # @return A jQuery promise
  _init: ->
    d = Q.defer()
    this._raw_get null, (raw_items) =>
      settings = {}
      for raw_key, raw_value of raw_items
        settings[raw_key] = raw_value if raw_key.match(@_nameRegex)
      @__retryer (ecbr) =>
        @client.post_settings(settings).catch(ecbr).then (md5) =>
          @_setLastMd5(md5)
          d.resolve(md5)
      , _.bind(d.reject,d)
    , _.bind(d.reject,d)
    d.promise

  # Save lastMd5 in settings
  _setLastMd5: (md5) ->
    @lastMd5 = md5
    @_auxiliaryStore.set(__last_sync_md5: md5)

  _saveChanges: (callback = undefined) -> @_auxiliaryStore.set __sync_changes: @_changes, callback
