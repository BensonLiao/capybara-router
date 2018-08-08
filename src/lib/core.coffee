queryString = require 'query-string'


core =
  historyListener: null
  history: null
  routes: []
  views: []
  currentRoute: null
  promise: null  # fetch resolve data promise [history.action, previousRoute, previousParams, nextRoute, nextParams, props]
  lastParams: null
  lastResolveData: null
  eventHandlers:
    changeStart: []
    changeSuccess: []
    changeError: []

  generateRoute: (args = {}, routes) ->
    ###
    @param args {object}
      isAbstract {bool}
      name {string}
      uri {string}
      onEnter {function}
      resolve {object}
        "resourceName": {Promise<response.data>}
      component {React.Component}
    @returns {Route}
      uriParamKeys {list<string>}  ex: ['projectId', '?index']  (with parents)
      matchPattern {string}  ex: '/projects/([\w-]{20})'  (with parents)
      matchReg {RegExp} The regexp for .match()  ex: /^\/projects\/([\w-]{20})$/  (with parents)
      hrefTemplate {string} The template for generating href.  ex: '/projects/{projectId}'  (with parents)
      parents {list<route>}
    ###
    args.resolve ?= {}
    if args.name.indexOf('.') > 0
      # there are parents of this route
      parentRoute = core.findRouteByName args.name.substr(0, args.name.lastIndexOf('.')), routes
      args.uriParamKeys = parentRoute.uriParamKeys.slice()
      args.matchPattern = parentRoute.matchPattern
      args.hrefTemplate = parentRoute.hrefTemplate
      args.parents = parentRoute.parents.slice()
      args.parents.push parentRoute
    else
      args.uriParamKeys = []
      args.matchPattern = ''
      args.hrefTemplate = ''
      args.parents = []

    uriPattern = args.uri
    hrefTemplate = args.uri
    uriParamPatterns = args.uri.match /\{[\w]+:(?:(?!\/).)+/g
    # args.uri: '/projects/{projectId:[\w-]{20}}'
    # uriParamPatterns: ['{projectId:[\w-]{20}}']
    for uriParamPattern in uriParamPatterns ? []
      # uriParamPattern: '{projectId:[\w-]{20}}'
      match = uriParamPattern.match /^\{([\w]+):((?:(?!\/).)*)\}$/
      # match: ['{projectId:[w-]{20}}', 'projectId', '[w-]{20}', ...]
      args.uriParamKeys.push match[1]
      uriPattern = uriPattern.replace uriParamPattern, "(#{match[2]})"
      # uriPattern: '/projects/([w-]{20})'
      hrefTemplate = hrefTemplate.replace uriParamPattern, "{#{match[1]}}"
      # hrefTemplate: '/projects/{projectId}'
    for uriQueryString in args.uri.match(/\?[\w-]+/g) ? []
      uriPattern = uriPattern.replace uriQueryString, ''
      hrefTemplate = hrefTemplate.replace uriQueryString, ''
      args.uriParamKeys.push uriQueryString
    args.matchPattern += uriPattern
    args.matchReg = new RegExp("^#{args.matchPattern}$")
    args.hrefTemplate += hrefTemplate
    args

  setup: (args = {}) ->
    routes = []
    for route in args.routes
      routes.push core.generateRoute(route, routes)
    core.history = args.history
    core.routes = routes
    core.views = []

    core.historyListener?()
    core.historyListener = core.history.listen core.onHistoryChange

    # fetch resolve data
    core.currentRoute = currentRoute = core.getCurrentRoute()
    params = core.parseRouteParams core.history.location, currentRoute
    core.promise = core.fetchResolveData(currentRoute, '', core.lastResolveData).then (resolveData) ->
      core.lastResolveData = resolveData
      props = core.flattenResolveData resolveData
      props.params = params
      routeChaining = currentRoute.parents.slice()
      routeChaining.push currentRoute
      core.views[0].routerView.dispatch
        route: routeChaining[0]
        props: props
      if routeChaining.length is 1
        core.broadcastSuccessEvent
          nextRoute: currentRoute
          nextParams: params
      Promise.all [
        null
        null
        null
        currentRoute
        params
        props
      ]

  onHistoryChange: (location, action) ->
    ###
    @param location {history.location}
    @param action {string|null} PUSH, REPLACE, POP, RELOAD, INITIAL
    ###
    previousRoute = core.currentRoute
    previousParams = core.lastParams
    nextRoute = core.findRoute location
    params = core.parseRouteParams location, nextRoute
    nextRouteChaining = nextRoute.parents.slice()
    nextRouteChaining.push nextRoute
    changeViewIndex = 0
    for route, index in nextRouteChaining when route.name isnt core.views[index].name
      changeViewIndex = index
      break
    core.promise = core.fetchResolveData(nextRoute, core.views[changeViewIndex].name, core.lastResolveData).then (resolveData) ->
      core.currentRoute = nextRoute
      core.lastResolveData = resolveData
      props = core.flattenResolveData resolveData
      props.params = params
      core.views.splice changeViewIndex + 1
      core.views[changeViewIndex].name = nextRouteChaining[changeViewIndex].name
      core.views[changeViewIndex].routerView.dispatch
        route: nextRouteChaining[changeViewIndex]
        props: props
      if nextRouteChaining.length is changeViewIndex + 1
        core.broadcastSuccessEvent
          action: action
          previousRoute: previousRoute
          previousParams: previousParams
          nextRoute: nextRoute
          nextParams: params
      Promise.all [
        action
        previousRoute
        previousParams
        nextRoute
        params
        props
      ]

  registerRouterView: (routerView) ->
    ###
    RouterView will call this method in `componentWillMount`.
    @param routerView {RouterView}
    ###
    routeChaining = core.currentRoute.parents.slice()
    routeChaining.push core.currentRoute
    viewsIndex = core.views.length
    core.views.push
      name: routeChaining[viewsIndex].name
      routerView: routerView

    core.promise.then ([action, previousRoute, previousParams, targetRoute, nextParams, props]) ->
      routeChaining = targetRoute.parents.slice()
      routeChaining.push targetRoute
      routerView.dispatch
        route: routeChaining[viewsIndex]
        props: props
      if routeChaining.length is viewsIndex + 1
        core.broadcastSuccessEvent
          action: action
          previousRoute: previousRoute
          previousParams: previousParams
          nextRoute: targetRoute
          nextParams: nextParams
      Promise.all [
        action
        previousRoute
        previousParams
        targetRoute
        nextParams
        props
      ]

  reload: ->
    ###
    Reload root router view.
    ###
    route = core.currentRoute
    params = core.parseRouteParams core.history.location, route
    core.promise = core.fetchResolveData(route, '', null).then (resolveData) ->
      core.lastResolveData = resolveData
      props = core.flattenResolveData resolveData
      props.params = params
      routeChaining = route.parents.slice()
      routeChaining.push route
      core.views.splice 1
      for view, index in core.views
        view.routerView.dispatch
          route: routeChaining[index]
          props: props
      Promise.all [
        'RELOAD'
        route
        params
        route
        params
        props
      ]

  go: (args = {}) ->
    if args.href
      if "#{core.history.location.pathname}#{core.history.location.search}" is args.href
        core.reload()
      else
        core.history.push args.href

  broadcastSuccessEvent: (args = {}) ->
    ###
    @params args {object}
      action {string}  PUSH, REPLACE, POP, RELOAD, INITIAL
      previousRoute {Route}
      previousParams {object|null}
      nextRoute {Route}
      nextParams {object|null}
    ###
    if args.action?
      fromState =
        name: args.previousRoute.name
        params: args.previousParams ? {}
    else
      args.action = 'INITIAL'
      fromState = null
    toState =
      name: args.nextRoute.name
      params: args.nextParams ? {}
    for handler in core.eventHandlers.changeSuccess
      handler.func args.action, toState, fromState

  listen: (event, func) ->
    table =
      ChangeStart: core.eventHandlers.changeStart
      ChangeSuccess: core.eventHandlers.changeSuccess
      ChangeError: core.eventHandlers.changeError
    handlers = table[event]
    if not handlers?
      throw new Error('event type error')
    id = Math.random().toString(36).substr(2)
    handlers.push
      id: id
      func: func
    ->
      for handler, index in handlers when handler.id is id
        handlers.splice index, 1
        break

  getCurrentRoute: ->
    ###
    Get the current route via core.history and core.routes.
    @returns {Route}
    ###
    core.findRoute core.history.location

  fetchResolveData: (route, reloadFrom = '', lastResolveData = {}) ->
    ###
    @param route {Route}
    @param reloadFrom {string} Reload data from this route name.
    @param lastResolveData {object}
      "route-name":
        "resolve-key": response
    @returns {promise<object>}
      "route-name":
        "resolve-key": response
    ###
    routeChaining = route.parents.slice()
    routeChaining.push route
    taskKeys = []
    tasks = []
    for route in routeChaining
      if not reloadFrom or route.name.indexOf(reloadFrom) is 0
        # fetch from the server
        for key, value of route.resolve
          taskKeys.push JSON.stringify(routeName: route.name, key: key)
          tasks.push value()
      else
        # use cache data
        for key, value of route.resolve
          taskKeys.push JSON.stringify(routeName: route.name, key: key)
          if route.name of lastResolveData and key of lastResolveData[route.name]
            tasks.push lastResolveData[route.name][key]
          else
            tasks.push value()
    Promise.all(tasks).then (responses) ->
      result = {}
      for taskKey, index in taskKeys
        taskInfo = JSON.parse taskKey
        result[taskInfo.routeName] ?= {}
        result[taskInfo.routeName][taskInfo.key] = responses[index]
      result

  flattenResolveData: (resolveData) ->
    result =
      key: Math.random().toString(36).substr(2)
    for routeName of resolveData
      for key, value of resolveData[routeName]
        result[key] = value
    result

  findRouteByName: (name, routes) ->
    ###
    @param name {string}
    @param routes {list<Route>}
    @returns {Route|null}
    ###
    for route in routes when name is route.name
      return route
    null

  findRoute: (location) ->
    ###
    Find the route with location in core.routes.
    @param location {location}
    @returns {Route|null}
    ###
    for route in core.routes when route.matchReg.test(location.pathname)
      return route
    null

  parseRouteParams: (location, route) ->
    ###
    @param location {history.location}
    @param route {Route}
    ###
    result = {}
    match = location.pathname.match new RegExp("^#{route.matchPattern}")
    parsedSearch = queryString.parse location.search
    uriParamsIndex = 0
    for paramKey in route.uriParamKeys
      if paramKey.indexOf('?') is 0
        paramKey = paramKey.substr 1
        result[paramKey] = parsedSearch[paramKey]
      else
        result[paramKey] = match[++uriParamsIndex]
    result

  mergeResolve: (route) ->
    ###
    @param route {Route}
    @returns {object}
    ###
    result = {}
    for key, value of route.resolve
      result[key] = value
    route.parents.map (parent) ->
      for key, value of parent.resolve
        result[key] = value
    result

module.exports = core
