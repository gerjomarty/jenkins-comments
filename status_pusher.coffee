_s = require 'underscore.string'

class exports.StatusPusher
    constructor: (user, repo, @sha, @pending_desc, @caller) ->

    getStatus: (cb) =>
        @caller.get "/statuses/#{@sha}", cb

    pushSuccess: =>
        @caller.post "/statuses/#{@sha}", (state: "success"), (e, body) ->
            console.log e if e?

    pushPending: =>
        @caller.post "/statuses/#{@sha}", (state: "pending", description: @pending_desc), (e, body) ->
            console.log e if e?

    pushError: (targetUrl, descriptions) =>
        description = descriptions.join ", "
        @caller.post "/statuses/#{@sha}", (state: "error", target_url: targetUrl, description: description), (e, body) ->
            console.log e if e?

    pushFailure: (targetUrl, descriptions) =>
        description = descriptions.join ", "
        @caller.post "/statuses/#{@sha}", (state: "failure", target_url: targetUrl, description: description), (e, body) ->
            console.log e if e?