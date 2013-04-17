_           = require 'underscore'
_s          = require 'underscore.string'
querystring = require 'querystring'
request     = require 'request'

class exports.RestCaller
  constructor: (@base_uri, queries, @user_agent, extra_headers) ->
    @query = querystring.stringify(queries)
    @query = "?" + @query unless _s.isBlank(@query)
    @headers = _.extend({"User-Agent": @user_agent}, extra_headers)

  post: (path, json_object, cb) =>
    uri = @base_uri + path + @query
    console.log "POST #{uri}"
    console.dir json_object
    request.post {uri: uri, json: json_object, headers: @headers}, (e, r, body) ->
      console.log body if process.env.DEBUG
      cb e, body

  get: (path, cb) =>
    uri = @base_uri + path + @query
    console.log "GET #{uri}"
    request.get {uri: uri, headers: @headers}, (e, r, body) ->
      console.log body if process.env.DEBUG
      cb e, body
